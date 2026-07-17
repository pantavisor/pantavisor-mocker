const std = @import("std");
const messages = @import("messages.zig");
const ipc = @import("ipc.zig");
const local_store = @import("local_store.zig");
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
    last_rev_check_ms: i64 = 0,
    upload_thread: ?std.Thread = null,
    host: ?[]const u8 = null,
    port: ?[]const u8 = null,
    token: ?[]const u8 = null,
    use_https: bool = true,
    // Guards host/port/token/use_https/creds_changed, which the IPC run() thread
    // writes (on subsystem_init) and the uploadLoop thread reads concurrently.
    // `client` is deliberately NOT covered: it is owned exclusively by uploadLoop
    // (created, refreshed, and destroyed only there), because push_logs holds the
    // client for minutes outside any lock — another thread freeing it (as the
    // run() thread once did on re-init) is a use-after-free.
    creds_mutex: std.Thread.Mutex = .{},
    // Set under creds_mutex whenever run() installs new credentials; uploadLoop
    // consumes it and rebuilds its client with the fresh host/port/token.
    creds_changed: bool = false,

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

    /// Unblocks the run() loop (blocked in receiveMessage) so its thread can be
    /// joined. Callers must join the thread running run() between shutdown() and
    /// deinit(): deinit frees the IPC read buffer and credential strings that
    /// run() touches, so deinit-before-join is a use-after-free.
    pub fn shutdown(self: *LoggerSubsystem) void {
        self.quit_flag.store(true, .release);
        std.posix.shutdown(self.ipc_client.stream.handle, .both) catch {};
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
                            self.creds_mutex.lock();
                            defer self.creds_mutex.unlock();
                            // Only update the credential strings here — never touch
                            // self.client, which uploadLoop may be using in a
                            // minutes-long push_logs outside any lock. Setting
                            // creds_changed makes uploadLoop (the sole owner)
                            // rebuild its client with these values.
                            if (data.object.get("host")) |h| {
                                if (h == .string) {
                                    if (self.host) |old| self.allocator.free(old);
                                    self.host = try self.allocator.dupe(u8, h.string);
                                }
                            }
                            if (data.object.get("port")) |p| {
                                if (p == .string) {
                                    if (self.port) |old| self.allocator.free(old);
                                    self.port = try self.allocator.dupe(u8, p.string);
                                }
                            }
                            if (data.object.get("token")) |t| {
                                if (t == .string) {
                                    if (self.token) |old| self.allocator.free(old);
                                    self.token = try self.allocator.dupe(u8, t.string);
                                }
                            }
                            if (data.object.get("use_https")) |u| {
                                if (u == .bool) self.use_https = u.bool;
                            }
                            self.creds_changed = true;
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

        // Format on the heap: a fixed stack buffer would return NoSpaceLeft for an
        // over-length line, propagating out of the run loop and permanently killing
        // the logger subsystem for the rest of the process.
        const line = try std.fmt.allocPrint(self.allocator, "[{s}] {s}\n", .{ msg.subsystem, msg.message });
        defer self.allocator.free(line);
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

        // The revision changes only when an update completes, so re-reading and
        // re-parsing revision-info.json on every 1s flush is wasteful — gate it to
        // once every 5s (and always on the first flush).
        const now = std.time.milliTimestamp();
        if (self.current_rev == null or (now - self.last_rev_check_ms) >= 5000) {
            const rev = try self.store.get_revision();
            defer self.allocator.free(rev);
            self.last_rev_check_ms = now;

            if (self.current_rev == null or !std.mem.eql(u8, self.current_rev.?, rev)) {
                try self.store.init_log_dir(rev);
                const path = try self.store.get_log_path(rev);
                defer self.allocator.free(path);

                // Fully open the new file before touching current state, so a failure
                // here can't leave a closed handle installed (which would fail every
                // later write, grow the buffer unbounded, and double-close at deinit).
                const new_file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
                errdefer new_file.close();
                try new_file.seekFromEnd(0);
                const new_rev = try self.allocator.dupe(u8, rev);

                if (self.current_log_file) |f| f.close();
                if (self.current_rev) |r| self.allocator.free(r);
                self.current_log_file = new_file;
                self.current_rev = new_rev;
            }
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

            // Build or refresh the client under the creds lock so the run() thread
            // can't free host/port/token while we read them. This thread is the
            // sole owner of self.client: run() only flips creds_changed, so the
            // client can never be freed out from under the (minutes-long,
            // lock-free) push_logs call below.
            self.creds_mutex.lock();
            if (self.creds_changed) {
                self.creds_changed = false;
                if (self.client) |c| {
                    c.deinit();
                    self.allocator.destroy(c);
                    self.client = null;
                }
            }
            const have_creds = self.host != null and self.port != null and self.token != null;
            if (have_creds and self.client == null) {
                if (self.allocator.create(client_mod.Client)) |c| {
                    if (client_mod.Client.init(self.allocator, self.host.?, self.port.?, null)) |built| {
                        c.* = built;
                        c.use_https = self.use_https;
                        c.token = self.allocator.dupe(u8, self.token.?) catch null;
                        self.client = c;
                    } else |_| {
                        self.allocator.destroy(c);
                    }
                } else |_| {}
            }
            const client = self.client;
            self.creds_mutex.unlock();

            if (client) |c| {
                log_pusher.push_logs(self.allocator, c, &self.store, self) catch |err| {
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
