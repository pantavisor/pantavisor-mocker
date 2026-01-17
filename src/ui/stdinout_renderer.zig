const std = @import("std");
const messages = @import("../core/messages.zig");
const Renderer = @import("renderer.zig").Renderer;
const ipc = @import("../core/ipc.zig");

pub const StdInOutRenderer = struct {
    allocator: std.mem.Allocator,
    ipc_client: ?ipc.IpcClient = null,
    ipc_thread: ?std.Thread = null,
    quit_flag: *std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, quit_flag: *std.atomic.Value(bool)) !*StdInOutRenderer {
        const self = try allocator.create(StdInOutRenderer);
        self.* = .{
            .allocator = allocator,
            .quit_flag = quit_flag,
        };
        return self;
    }

    pub fn connect(self: *StdInOutRenderer, socket_path: []const u8) !void {
        self.ipc_client = try ipc.IpcClient.init(self.allocator, socket_path, .renderer);
        self.ipc_thread = try std.Thread.spawn(.{}, listenToIpc, .{self});
    }

    pub fn renderer(self: *StdInOutRenderer) Renderer {
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
        _ = ctx;
        std.debug.print("[{s}] {s}\n", .{ msg.subsystem, msg.message });
    }

    fn render_update(ctx: *anyopaque, data: std.json.Value) anyerror!void {
        _ = ctx;
        _ = data;
        std.debug.print("Update status changed.\n", .{});
    }

    fn render_invite(ctx: *anyopaque, data: messages.InvitationData) anyerror!void {
        _ = ctx;
        std.debug.print("\n*** INVITATION RECEIVED ***\n", .{});
        std.debug.print("From: {s}\n", .{data.from});
        std.debug.print("Release: {s}\n", .{data.release});
        std.debug.print("Deployment: {s}\n", .{data.deployment});
        if (data.vendorRelease) |v| std.debug.print("Vendor Rev: {s}\n", .{v});
        std.debug.print("Mandatory: {any}\n", .{data.mandatory});
        std.debug.print("Earliest: {s} | Latest: {s}\n", .{ data.earliestUpdate orelse "NOW", data.latestUpdate orelse "NEVER" });

        if (data.mandatory) {
            std.debug.print("Mandatory invitation automatically accepted.\n", .{});
        } else {
            std.debug.print("Actions: (a)CCEPT, (s)KIP, ASK ME (l)ATER\n", .{});
        }
    }

    fn render_state_change(ctx: *anyopaque, state: []const u8) anyerror!void {
        _ = ctx;
        std.debug.print("State Change: {s}\n", .{state});
    }

    fn get_user_input(ctx: *anyopaque, prompt: []const u8) anyerror![]u8 {
        const self: *StdInOutRenderer = @ptrCast(@alignCast(ctx));
        std.debug.print("{s}", .{prompt});
        const stdin = std.fs.File.stdin();

        // Use simpler way to read from stdin
        var buf: [1024]u8 = undefined;

        const size = try stdin.read(&buf);
        if (size == 0) return error.EndOfStream;

        // Trim newline
        var line = buf[0..size];
        if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        return try self.allocator.dupe(u8, line);
    }

    pub fn deinit(self: *StdInOutRenderer) void {
        self.quit_flag.store(true, .release);
        if (self.ipc_client) |*c| {
            std.posix.shutdown(c.stream.handle, .both) catch {};
        }
        if (self.ipc_thread) |t| t.join();
        if (self.ipc_client) |*c| c.deinit();
        self.allocator.destroy(self);
    }

    fn deinitVTable(ctx: *anyopaque) void {
        const self: *StdInOutRenderer = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn listenToIpc(self: *StdInOutRenderer) void {
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
                        _ = render_log(self, log_data.value) catch {};
                    }
                },
                .sync_progress => {
                    if (msg.data) |data| {
                        if (data == .object) {
                            const p = data.object.get("percentage");
                            const d = data.object.get("details");
                            if (p != null and d != null and p.? == .integer and d.? == .string) {
                                std.debug.print("[syncing] {d}%: {s}\n", .{ p.?.integer, d.?.string });
                            }
                        }
                    }
                },
                .render_invite => {
                    if (msg.data) |data| {
                        const invite_data = std.json.parseFromValue(messages.InvitationData, self.allocator, data, .{}) catch continue;
                        defer invite_data.deinit();
                        _ = render_invite(self, invite_data.value) catch {};

                        if (!invite_data.value.mandatory) {
                            // Start a thread to get input so we don't block the IPC listener
                            if (std.Thread.spawn(.{}, handleInvitationInput, .{self})) |t| {
                                t.detach();
                            } else |_| {}
                        }
                    }
                },
                .update_required => {
                    // Start a thread to get input for update
                    if (std.Thread.spawn(.{}, handleUpdateInput, .{self})) |t| {
                        t.detach();
                    } else |_| {}
                },
                .subsystem_stop => {
                    self.quit_flag.store(true, .release);
                },
                else => {},
            }
        }
    }

    fn handleInvitationInput(self: *StdInOutRenderer) void {
        const input = get_user_input(self, "Decision: ") catch return;
        defer self.allocator.free(input);

        var resp: ?[]const u8 = null;
        if (input.len > 0) {
            switch (input[0]) {
                'a', 'A' => resp = "accept",
                's', 'S' => resp = "skip",
                'l', 'L' => resp = "later",
                else => {},
            }
        }

        if (resp) |r| {
            if (self.ipc_client) |*client| {
                client.sendMessage(.background_job, .user_response, .{ .string = r }) catch {};
            }
        }
    }

    fn handleUpdateInput(self: *StdInOutRenderer) void {
        std.debug.print("UPDATE DECISION REQUIRED\n", .{});
        std.debug.print("An update cycle is in TESTING phase.\n", .{});
        std.debug.print("Select Outcome:\n", .{});
        std.debug.print("[U]PDATED  - Success (Immediate)\n", .{});
        std.debug.print("[D]ONE     - Success (Reboot)\n", .{});
        std.debug.print("[E]RROR    - Simulate Failure\n", .{});
        std.debug.print("[W]ONTGO   - Reject Update\n", .{});

        const input = get_user_input(self, "Action (10s timeout defaults to DONE): ") catch return;
        defer self.allocator.free(input);

        var resp: ?[]const u8 = null;
        if (input.len > 0) {
            switch (input[0]) {
                'u', 'U' => resp = "updated",
                'd', 'D' => resp = "done",
                'e', 'E' => resp = "error_status",
                'w', 'W' => resp = "wontgo",
                else => {},
            }
        }

        if (resp) |r| {
            if (self.ipc_client) |*client| {
                client.sendMessage(.background_job, .user_response, .{ .string = r }) catch {};
            }
        }
    }
};
