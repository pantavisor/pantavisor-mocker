const std = @import("std");
const messages = @import("../core/messages.zig");
const ipc = @import("../core/ipc.zig");
const local_store = @import("../storage/local_store.zig");
const client_mod = @import("../net/client.zig");
const log_pusher = @import("../net/log_pusher.zig");

pub const LoggerSubsystem = struct {
    allocator: std.mem.Allocator,
    ipc_client: ipc.IpcClient,
    store: local_store.LocalStore,
    client: ?*client_mod.Client = null,
    quit_flag: *std.atomic.Value(bool),
    current_log_file: ?std.fs.File = null,
    current_rev: ?[]const u8 = null,
    upload_thread: ?std.Thread = null,
    host: ?[]const u8 = null,
    port: ?[]const u8 = null,
    token: ?[]const u8 = null,

    // Buffering
    log_buffer: std.ArrayList(u8),
    buffer_mutex: std.Thread.Mutex,
    flush_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8, storage_path: []const u8, quit_flag: *std.atomic.Value(bool)) !LoggerSubsystem {
        const ipc_client = try ipc.IpcClient.init(allocator, socket_path, .logger);
        const store = try local_store.LocalStore.init(allocator, storage_path, null, false);

        return LoggerSubsystem{
            .allocator = allocator,
            .ipc_client = ipc_client,
            .store = store,
            .quit_flag = quit_flag,
            .upload_thread = null,
            .host = null,
            .port = null,
            .token = null,
            .log_buffer = .{},
            .buffer_mutex = .{},
            .flush_thread = null,
        };
    }

    pub fn deinit(self: *LoggerSubsystem) void {
        self.quit_flag.store(true, .release);
        if (self.upload_thread) |t| t.join();
        if (self.flush_thread) |t| t.join();

        // Final flush
        self.flushBuffer() catch {};

        std.posix.shutdown(self.ipc_client.stream.handle, .both) catch {};
        self.ipc_client.deinit();
        self.store.deinit();
        if (self.current_log_file) |f| f.close();
        if (self.current_rev) |r| self.allocator.free(r);
        if (self.host) |h| self.allocator.free(h);
        if (self.port) |p| self.allocator.free(p);
        if (self.token) |t| self.allocator.free(t);
        if (self.client) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.log_buffer.deinit(self.allocator);
    }

    pub fn run(self: *LoggerSubsystem) !void {
        self.upload_thread = try std.Thread.spawn(.{}, uploadLoop, .{self});
        self.flush_thread = try std.Thread.spawn(.{}, flushLoop, .{self});

        while (!self.quit_flag.load(.acquire)) {
            var parsed = self.ipc_client.receiveMessage() catch |err| {
                if (err == error.ConnectionClosed) break;
                continue;
            };
            defer parsed.deinit();

            const msg = parsed.value;
            switch (msg.type) {
                .response_ok => {
                    if (msg.from == .core) {
                        try self.ipc_client.sendMessage(.core, .subsystem_ready, null);
                    }
                },
                .subsystem_init => {
                    if (msg.data) |data| {
                        if (data == .object) {
                            if (data.object.get("host")) |h| {
                                if (self.host) |old| self.allocator.free(old);
                                self.host = try self.allocator.dupe(u8, h.string);
                            }
                            if (data.object.get("port")) |p| {
                                if (self.port) |old| self.allocator.free(old);
                                self.port = try self.allocator.dupe(u8, p.string);
                            }
                            if (data.object.get("token")) |t| {
                                if (self.token) |old| self.allocator.free(old);
                                self.token = try self.allocator.dupe(u8, t.string);
                            }
                        }
                    }
                },
                .log_message => {
                    if (msg.data) |data| {
                        const log_data = try std.json.parseFromValue(messages.LogData, self.allocator, data, .{});
                        defer log_data.deinit();
                        try self.handleLogMessage(log_data.value);

                        // Forward to renderer for display
                        self.ipc_client.sendMessage(.renderer, .render_log, data) catch {};
                    }
                },
                else => {},
            }
        }
    }

    fn handleLogMessage(self: *LoggerSubsystem, msg: messages.LogData) !void {
        self.buffer_mutex.lock();
        defer self.buffer_mutex.unlock();

        var buf: [4096]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "[{s}] {s}\n", .{ msg.subsystem, msg.message });
        try self.log_buffer.appendSlice(self.allocator, line);

        if (self.log_buffer.items.len > 4096) {
            try self.flushBufferLocked();
        }
    }

    fn flushLoop(self: *LoggerSubsystem) void {
        while (!self.quit_flag.load(.acquire)) {
            std.Thread.sleep(1 * std.time.ns_per_s);
            self.buffer_mutex.lock();
            self.flushBufferLocked() catch |err| {
                self.log("flush error: {any}", .{err});
            };
            self.buffer_mutex.unlock();
        }
    }

    fn flushBuffer(self: *LoggerSubsystem) !void {
        self.buffer_mutex.lock();
        defer self.buffer_mutex.unlock();
        try self.flushBufferLocked();
    }

    fn flushBufferLocked(self: *LoggerSubsystem) !void {
        if (self.log_buffer.items.len == 0) return;

        const rev = try self.store.get_revision();
        defer self.allocator.free(rev);

        if (self.current_rev == null or !std.mem.eql(u8, self.current_rev.?, rev)) {
            if (self.current_log_file) |f| f.close();
            if (self.current_rev) |r| self.allocator.free(r);

            self.current_rev = try self.allocator.dupe(u8, rev);
            const path = try self.store.get_log_path(rev);
            defer self.allocator.free(path);

            self.current_log_file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
            try self.current_log_file.?.seekFromEnd(0);
        }

        if (self.current_log_file) |file| {
            try file.writeAll(self.log_buffer.items);
            self.log_buffer.clearRetainingCapacity();
        }
    }

    fn uploadLoop(self: *LoggerSubsystem) void {
        while (!self.quit_flag.load(.acquire)) {

            // Sleep in small increments to check quit_flag frequently
            var i: usize = 0;
            while (i < 300 and !self.quit_flag.load(.acquire)) : (i += 1) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }

            if (self.quit_flag.load(.acquire)) break;

            if (self.host != null and self.port != null and self.token != null) {
                if (self.client == null) {
                    self.client = self.allocator.create(client_mod.Client) catch continue;
                    self.client.?.* = client_mod.Client.init(
                        self.allocator,
                        self.host.?,
                        self.port.?,
                        null,
                    ) catch {
                        self.allocator.destroy(self.client.?);
                        self.client = null;
                        continue;
                    };
                    self.client.?.token = self.allocator.dupe(u8, self.token.?) catch null;
                }

                log_pusher.push_logs(self.allocator, self.client.?, &self.store, self) catch |err| {
                    self.log("push_logs error: {any}", .{err});
                };
            }
        }
    }

    pub fn log(self: *LoggerSubsystem, comptime format: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, format, args) catch return;

        const log_data = messages.LogData{
            .level = "INFO",
            .subsystem = "logger",
            .message = msg,
            .timestamp = std.time.timestamp(),
        };

        var map = std.StringArrayHashMap(std.json.Value).init(self.allocator);
        defer map.deinit();
        map.put("level", .{ .string = log_data.level }) catch {};
        map.put("subsystem", .{ .string = log_data.subsystem }) catch {};
        map.put("message", .{ .string = log_data.message }) catch {};
        map.put("timestamp", .{ .integer = log_data.timestamp }) catch {};

        self.ipc_client.sendMessage(.renderer, .render_log, .{ .object = map }) catch {};
    }
};
