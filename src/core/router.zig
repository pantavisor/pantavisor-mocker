const std = @import("std");
const messages = @import("messages.zig");
const SubsystemId = messages.SubsystemId;
const Message = messages.Message;

const SubsystemStatus = enum {
    unknown,
    registered,
    ready,
    running,
    stopped,
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    subsystems: std.AutoHashMap(SubsystemId, std.net.Stream),
    subsystem_status: std.AutoHashMap(SubsystemId, SubsystemStatus),
    subsystems_mutex: std.Thread.Mutex,
    quit_flag: *std.atomic.Value(bool),
    active_connections: std.atomic.Value(usize),

    const MAX_CONNECTIONS: usize = 16;

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8, quit_flag: *std.atomic.Value(bool)) !Router {
        return .{
            .allocator = allocator,
            .socket_path = try allocator.dupe(u8, socket_path),
            .subsystems = std.AutoHashMap(SubsystemId, std.net.Stream).init(allocator),
            .subsystem_status = std.AutoHashMap(SubsystemId, SubsystemStatus).init(allocator),
            .subsystems_mutex = .{},
            .quit_flag = quit_flag,
            .active_connections = std.atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *Router) void {
        self.subsystems_mutex.lock();
        defer self.subsystems_mutex.unlock();
        var it = self.subsystems.valueIterator();
        while (it.next()) |stream| {
            stream.close();
        }
        self.subsystems.deinit();
        self.subsystem_status.deinit();
        std.fs.cwd().deleteFile(self.socket_path) catch {};
        self.allocator.free(self.socket_path);
    }

    pub fn requestShutdown(self: *Router) void {
        self.quit_flag.store(true, .release);
        // Wake up blocking accept() by connecting to the socket
        const dummy_conn = std.net.connectUnixSocket(self.socket_path) catch null;
        if (dummy_conn) |c| c.close();
    }

    pub fn run(self: *Router) !void {
        std.fs.cwd().deleteFile(self.socket_path) catch {};

        // Ensure the directory exists
        if (std.fs.path.dirname(self.socket_path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        const address = try std.net.Address.initUnix(self.socket_path);
        var server = try address.listen(.{ .reuse_address = true });
        defer server.deinit();

        // Set non-blocking to allow checking quit_flag
        // Wait, std.net.Server doesn't easily support non-blocking accept in a portable way without more work.
        // For now, we'll use a separate thread for the listener and accept blocking.

        while (!self.quit_flag.load(.acquire)) {
            const conn = server.accept() catch continue;

            if (self.active_connections.load(.acquire) >= MAX_CONNECTIONS) {
                std.log.warn("Router: connection limit reached ({}), rejecting new connection", .{MAX_CONNECTIONS});
                conn.stream.close();
                continue;
            }

            _ = self.active_connections.fetchAdd(1, .monotonic);
            const thread = try std.Thread.spawn(.{}, handleConnectionWrapper, .{ self, conn.stream });
            thread.detach();
        }
    }

    fn handleConnectionWrapper(self: *Router, stream: std.net.Stream) void {
        handleConnection(self, stream) catch |err| {
            std.log.err("Router connection handler error: {}", .{err});
        };
    }

    fn handleConnection(self: *Router, stream: std.net.Stream) !void {
        defer _ = self.active_connections.fetchSub(1, .monotonic);
        var buf: [1024]u8 = undefined;
        var r = stream.reader(&buf);
        const reader = r.interface().adaptToOldInterface();

        while (!self.quit_flag.load(.acquire)) {
            const line = reader.readUntilDelimiterAlloc(self.allocator, '\n', 8192) catch |err| {
                if (err == error.EndOfStream) break;
                continue;
            };
            defer self.allocator.free(line);

            var parsed = Message.deserialize(self.allocator, line) catch continue;
            defer parsed.deinit();

            const msg = parsed.value;
            if (msg.type == .subsystem_init and msg.to == .core) {
                self.subsystems_mutex.lock();
                defer self.subsystems_mutex.unlock();
                try self.subsystems.put(msg.from, stream);
                try self.subsystem_status.put(msg.from, .registered);

                // If this is background job, check if we can start it immediately (if others are ready)
                if (msg.from == .background_job) {
                    try self.checkAndStartBackgroundJob();
                }

                const resp = Message{
                    .from = .core,
                    .to = msg.from,
                    .type = .response_ok,
                };
                const json = try resp.serialize(self.allocator);
                defer self.allocator.free(json);
                _ = stream.write(json) catch |err| {
                    std.log.err("Router: failed to send response_ok to subsystem {s}: {}", .{ @tagName(msg.from), err });
                };
                continue;
            }

            if (msg.to == .core) {
                try self.handleCoreMessage(msg);
            } else {
                try self.routeMessage(msg);
            }
        }
    }

    fn handleCoreMessage(self: *Router, msg: Message) !void {
        if (msg.type == .subsystem_ready) {
            self.subsystems_mutex.lock();
            defer self.subsystems_mutex.unlock();

            try self.subsystem_status.put(msg.from, .ready);
            try self.checkAndStartBackgroundJob();
        }
    }

    fn checkAndStartBackgroundJob(self: *Router) !void {
        // Mutex is expected to be locked by caller
        const renderer_status = self.subsystem_status.get(.renderer) orelse .unknown;
        const logger_status = self.subsystem_status.get(.logger) orelse .unknown;

        const renderer_ok = (renderer_status == .ready);
        const logger_ok = (logger_status == .ready);

        if (renderer_ok and logger_ok) {
            if (self.subsystems.get(.background_job)) |stream| {
                const bg_status = self.subsystem_status.get(.background_job) orelse .unknown;
                if (bg_status == .registered) {
                    const start_msg = Message{ .from = .core, .to = .background_job, .type = .subsystem_start };
                    const json = try start_msg.serialize(self.allocator);
                    defer self.allocator.free(json);
                    _ = stream.write(json) catch |err| {
                        std.log.err("Router: failed to send subsystem_start to background_job: {}", .{err});
                    };

                    try self.subsystem_status.put(.background_job, .running);
                }
            }
        }
    }

    fn routeMessage(self: *Router, msg: Message) !void {
        if (msg.to == .core) {
            // Handle core messages (e.g. status updates)
            return;
        }

        self.subsystems_mutex.lock();
        defer self.subsystems_mutex.unlock();

        if (self.subsystems.get(msg.to)) |stream| {
            const json = try msg.serialize(self.allocator);
            defer self.allocator.free(json);
            _ = std.posix.send(stream.handle, json, std.posix.MSG.NOSIGNAL) catch |err| {
                std.log.err("Router: failed to send message to subsystem {s}: {}", .{ @tagName(msg.to), err });
            };
        } else {
            // Target subsystem not found
        }
    }
};
