const std = @import("std");
const messages = @import("messages.zig");
const Message = messages.Message;
const SubsystemId = messages.SubsystemId;

pub const IpcClient = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    id: SubsystemId,
    write_mutex: std.Thread.Mutex,
    read_mutex: std.Thread.Mutex,
    // Bytes pulled from the socket but not yet consumed. A single read() can
    // coalesce multiple newline-framed messages; keeping the leftover here (as
    // opposed to a per-call stack reader) ensures no message is ever dropped.
    read_buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8, id: SubsystemId) !IpcClient {
        const stream = try std.net.connectUnixSocket(socket_path);

        var client = IpcClient{
            .allocator = allocator,
            .stream = stream,
            .id = id,
            .write_mutex = .{},
            .read_mutex = .{},
            .read_buf = std.ArrayList(u8){},
        };

        // Register with core
        try client.sendMessage(.core, .subsystem_init, null);

        return client;
    }

    pub fn deinit(self: *IpcClient) void {
        self.read_buf.deinit(self.allocator);
        self.stream.close();
    }

    pub fn sendMessage(self: *IpcClient, to: SubsystemId, msg_type: messages.MessageType, data: ?std.json.Value) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        const msg = Message{
            .from = self.id,
            .to = to,
            .type = msg_type,
            .data = data,
        };
        const json = try msg.serialize(self.allocator);
        defer self.allocator.free(json);
        _ = try self.stream.write(json);
    }

    pub fn receiveMessage(self: *IpcClient) !std.json.Parsed(Message) {
        self.read_mutex.lock();
        defer self.read_mutex.unlock();

        const line = try self.readLineLocked();
        defer self.allocator.free(line);
        return try Message.deserialize(self.allocator, line);
    }

    /// Returns true if a full newline-terminated message is already buffered, so
    /// pollers don't wait on the socket for data that has already arrived.
    pub fn hasBufferedMessage(self: *IpcClient) bool {
        self.read_mutex.lock();
        defer self.read_mutex.unlock();
        return std.mem.indexOfScalar(u8, self.read_buf.items, '\n') != null;
    }

    /// Reads one newline-delimited message, returning an owned slice (without the
    /// trailing '\n'). Extra bytes read from the socket are retained in `read_buf`
    /// so coalesced messages are never lost. The caller must hold `read_mutex`.
    fn readLineLocked(self: *IpcClient) ![]u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.read_buf.items, '\n')) |nl| {
                const line = try self.allocator.dupe(u8, self.read_buf.items[0..nl]);
                errdefer self.allocator.free(line);
                const rest_start = nl + 1;
                const remaining = self.read_buf.items.len - rest_start;
                std.mem.copyForwards(u8, self.read_buf.items[0..remaining], self.read_buf.items[rest_start..]);
                self.read_buf.shrinkRetainingCapacity(remaining);
                return line;
            }

            var tmp: [4096]u8 = undefined;
            const n = try self.stream.read(&tmp);
            if (n == 0) return error.ConnectionClosed;
            try self.read_buf.appendSlice(self.allocator, tmp[0..n]);

            // Bound a single message so a peer that never sends '\n' cannot grow
            // the buffer without limit.
            if (self.read_buf.items.len > 65536 and
                std.mem.indexOfScalar(u8, self.read_buf.items, '\n') == null)
            {
                return error.MessageTooLong;
            }
        }
    }

    pub fn get_user_input(self: *IpcClient, to: SubsystemId, prompt: []const u8, timeout_ms: ?u32) ![]u8 {
        const data = std.json.Value{ .string = prompt };
        try self.sendMessage(to, .get_user_input, data);

        const start_time = std.time.milliTimestamp();

        // Block until we get user_response
        while (true) {
            // Only wait on the socket when no complete message is already
            // buffered; otherwise a coalesced message would be starved by poll().
            if (timeout_ms) |t| {
                if (!self.hasBufferedMessage()) {
                    const elapsed = std.time.milliTimestamp() - start_time;
                    if (elapsed >= t) return error.Timeout;

                    const remaining = t - @as(u32, @intCast(elapsed));
                    var fds = [1]std.posix.pollfd{.{
                        .fd = self.stream.handle,
                        .events = std.posix.POLL.IN,
                        .revents = 0,
                    }};
                    const ready_count = try std.posix.poll(&fds, @intCast(remaining));
                    if (ready_count == 0) return error.Timeout;
                }
            }

            var parsed = try self.receiveMessage();
            defer parsed.deinit();
            const msg = parsed.value;
            if (msg.type == .user_response) {
                if (msg.data) |d| {
                    if (d == .string) {
                        return try self.allocator.dupe(u8, d.string);
                    }
                }
            }
        }
    }
};
