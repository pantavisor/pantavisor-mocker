const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("tui.zig");
const messages = @import("../core/messages.zig");
const Renderer = @import("renderer.zig").Renderer;
const ipc = @import("../core/ipc.zig");

pub const TuiRenderer = struct {
    allocator: std.mem.Allocator,
    vx: vaxis.Vaxis,
    tty: vaxis.Tty,
    loop: vaxis.Loop(tui.Event),
    state: tui.AppState,
    arena: std.heap.ArenaAllocator,
    ipc_client: ?ipc.IpcClient = null,
    ipc_thread: ?std.Thread = null,
    quit_flag: *std.atomic.Value(bool),
    render_mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, quit_flag: *std.atomic.Value(bool)) !*TuiRenderer {
        const self = try allocator.create(TuiRenderer);

        var posix_buffer: [16]u8 = undefined;
        const tty = try vaxis.Tty.init(&posix_buffer);
        const vx = try vaxis.init(allocator, .{});

        self.* = .{
            .allocator = allocator,
            .vx = vx,
            .tty = tty,
            .loop = .{
                .tty = &self.tty,
                .vaxis = &self.vx,
            },
            .state = tui.AppState.init(allocator, true),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .ipc_client = null,
            .quit_flag = quit_flag,
            .render_mutex = .{},
        };

        try self.loop.init();
        try self.loop.start();

        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);

        return self;
    }

    pub fn connect(self: *TuiRenderer, socket_path: []const u8) !void {
        self.ipc_client = try ipc.IpcClient.init(self.allocator, socket_path, .renderer);
        self.ipc_thread = try std.Thread.spawn(.{}, listenToIpc, .{self});
    }

    pub fn renderer(self: *TuiRenderer) Renderer {
        return .{
            .ptr = self,
            .vtable = &.{
                .render_log = render_log,
                .render_update = render_update,
                .render_invite = render_invite,
                .render_state_change = render_state_change,
                .get_user_input = get_user_input,
                .deinit = deinitVTable,
            },
        };
    }

    fn render_log(ctx: *anyopaque, msg: messages.LogData) anyerror!void {
        const self: *TuiRenderer = @ptrCast(@alignCast(ctx));
        try self.render_log_internal(msg);
    }

    fn render_update(ctx: *anyopaque, data: std.json.Value) anyerror!void {
        _ = ctx;
        _ = data;
    }

    fn render_invite(ctx: *anyopaque, data: messages.InvitationData) anyerror!void {
        const self: *TuiRenderer = @ptrCast(@alignCast(ctx));
        try self.render_invite_internal(data);
    }

    fn render_state_change(ctx: *anyopaque, state: []const u8) anyerror!void {
        _ = ctx;
        _ = state;
    }

    fn get_user_input(ctx: *anyopaque, prompt: []const u8, timeout_ms: ?u32) anyerror![]u8 {
        _ = ctx;
        _ = prompt;
        _ = timeout_ms;
        return error.NotImplemented;
    }

    pub fn deinit(self: *TuiRenderer) void {
        self.quit_flag.store(true, .release);

        if (self.ipc_client) |*c| {
            std.posix.shutdown(c.stream.handle, .both) catch {};
        }

        if (self.ipc_thread) |t| t.join();
        self.vx.exitAltScreen(self.tty.writer()) catch {};
        self.loop.stop();

        // Drain pending events
        while (self.loop.tryEvent()) |event| {
            event.deinit(self.allocator);
        }

        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.state.deinit();
        self.arena.deinit();
        if (self.ipc_client) |*c| c.deinit();
        self.allocator.destroy(self);
    }

    fn deinitVTable(ctx: *anyopaque) void {
        const self: *TuiRenderer = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn listenToIpc(self: *TuiRenderer) void {
        while (!self.quit_flag.load(.acquire)) {
            var parsed = self.ipc_client.?.receiveMessage() catch |err| {
                if (err == error.ConnectionClosed) break;
                continue;
            };
            defer parsed.deinit();

            const msg = parsed.value;
            switch (msg.type) {
                .response_ok => {
                    if (msg.from == .core) {
                        self.ipc_client.?.sendMessage(.core, .subsystem_ready, null) catch {};
                    }
                },
                .render_log => {
                    if (msg.data) |data| {
                        const log_data = std.json.parseFromValue(messages.LogData, self.allocator, data, .{}) catch continue;
                        defer log_data.deinit();
                        self.render_log_internal(log_data.value) catch {};
                    }
                },
                .render_invite => {
                    if (msg.data) |data| {
                        const invite_data = std.json.parseFromValue(messages.InvitationData, self.allocator, data, .{}) catch continue;
                        defer invite_data.deinit();
                        self.render_invite_internal(invite_data.value) catch {};
                    }
                },
                .sync_progress => {
                    if (msg.data) |data| {
                        if (data == .object) {
                            const p = data.object.get("percentage");
                            const d = data.object.get("details");
                            if (p != null and d != null and p.? == .integer and d.? == .string) {
                                self.render_mutex.lock();
                                defer self.render_mutex.unlock();
                                const prog = tui.Progress{
                                    .status = self.allocator.dupe(u8, "SYNCING") catch continue,
                                    .progress = @intCast(p.?.integer),
                                    .@"status-msg" = self.allocator.dupe(u8, d.?.string) catch continue,
                                    .revision = self.allocator.dupe(u8, "N/A") catch continue, // Placeholder
                                };
                                self.loop.postEvent(.{ .progress = prog });
                            }
                        }
                    }
                },
                .update_required => {
                    self.render_mutex.lock();
                    defer self.render_mutex.unlock();
                    self.loop.postEvent(.update_prompt);
                },
                .subsystem_stop => {
                    self.render_mutex.lock();
                    defer self.render_mutex.unlock();
                    self.loop.postEvent(.quit);
                },
                else => {},
            }
        }
    }

    fn render_log_internal(self: *TuiRenderer, msg: messages.LogData) !void {
        self.render_mutex.lock();
        defer self.render_mutex.unlock();
        const owned_msg = try self.allocator.dupe(u8, msg.message);
        self.loop.postEvent(.{ .log_message = .{ .message = owned_msg, .timestamp = msg.timestamp } });
    }

    fn render_invite_internal(self: *TuiRenderer, data: messages.InvitationData) !void {
        self.render_mutex.lock();
        defer self.render_mutex.unlock();
        self.loop.postEvent(.{ .invitation = .{
            .id = try self.allocator.dupe(u8, data.id),
            .description = try self.allocator.dupe(u8, data.description),
            .from = try self.allocator.dupe(u8, data.from),
            .deployment = try self.allocator.dupe(u8, data.deployment),
            .release = try self.allocator.dupe(u8, data.release),
            .vendorRelease = if (data.vendorRelease) |v| try self.allocator.dupe(u8, v) else null,
            .earliestUpdate = if (data.earliestUpdate) |v| try self.allocator.dupe(u8, v) else null,
            .latestUpdate = if (data.latestUpdate) |v| try self.allocator.dupe(u8, v) else null,
            .mandatory = data.mandatory,
        } });
    }

    pub fn run(self: *TuiRenderer) !void {
        while (!self.state.should_quit and !self.quit_flag.load(.acquire)) {
            _ = self.arena.reset(.retain_capacity);
            var event = self.loop.tryEvent();
            if (event == null) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            defer event.?.deinit(self.allocator);
            switch (event.?) {
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true })) {
                        self.state.should_quit = true;
                        self.quit_flag.store(true, .release);
                    } else if (self.state.awaiting_invitation) {
                        var resp: ?[]const u8 = null;
                        if (key.matches('a', .{}) or key.matches('A', .{})) {
                            resp = "accept";
                        } else if (key.matches('s', .{}) or key.matches('S', .{})) {
                            resp = "skip";
                        } else if (key.matches('l', .{}) or key.matches('L', .{})) {
                            resp = "later";
                        }

                        if (resp) |r| {
                            if (self.ipc_client) |*client| {
                                client.sendMessage(.background_job, .user_response, .{ .string = r }) catch {};
                            }
                            self.state.awaiting_invitation = false;
                        }
                    } else if (self.state.awaiting_update) {
                        var resp: ?[]const u8 = null;
                        if (key.matches('u', .{}) or key.matches('u', .{})) {
                            resp = "updated";
                        } else if (key.matches('d', .{}) or key.matches('d', .{})) {
                            resp = "done";
                        } else if (key.matches('e', .{}) or key.matches('e', .{})) {
                            resp = "error_status";
                        } else if (key.matches('w', .{}) or key.matches('w', .{})) {
                            resp = "wontgo";
                        }

                        if (resp) |r| {
                            if (self.ipc_client) |*client| {
                                client.sendMessage(.background_job, .user_response, .{ .string = r }) catch {};
                            }
                            self.state.awaiting_update = false;
                        }
                    }
                },
                .winsize => |ws| try self.vx.resize(self.allocator, self.tty.writer(), ws),
                .log_message => |log_msg| {
                    try self.state.add_log(log_msg.message);
                },
                .invitation => |*inv| {
                    try self.state.set_invitation(inv.*);
                    inv.id = "";
                    inv.description = "";
                    inv.from = "";
                    inv.deployment = "";
                    inv.release = "";
                    inv.vendorRelease = null;
                    inv.earliestUpdate = null;
                    inv.latestUpdate = null;
                },
                .progress => |*p| {
                    try self.state.update_progress(p.*);
                    p.status = "";
                    p.@"status-msg" = "";
                    p.revision = "";
                },
                .update_prompt => {
                    self.state.awaiting_update = true;
                },
                .quit => self.state.should_quit = true,
                else => {},
            }
            self.render_mutex.lock();
            defer self.render_mutex.unlock();
            try tui.render(&self.vx, &self.state, self.arena.allocator());
            try self.vx.render(self.tty.writer());
        }
    }
};
