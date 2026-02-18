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

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8, id: SubsystemId) !IpcClient {
        const stream = try std.net.connectUnixSocket(socket_path);

        var client = IpcClient{
            .allocator = allocator,
            .stream = stream,
            .id = id,
            .write_mutex = .{},
            .read_mutex = .{},
        };

        // Register with core
        try client.sendMessage(.core, .subsystem_init, null);

        return client;
    }

    pub fn deinit(self: *IpcClient) void {
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

        var buf: [1024]u8 = undefined;
        var r = self.stream.reader(&buf);
        const reader = r.interface().adaptToOldInterface();
        const line = reader.readUntilDelimiterAlloc(self.allocator, '\n', 8192) catch |err| {
            if (err == error.EndOfStream) return error.ConnectionClosed;
            return err;
        };
        defer self.allocator.free(line);
        return try Message.deserialize(self.allocator, line);
    }

    pub fn get_user_input(self: *IpcClient, to: SubsystemId, prompt: []const u8, timeout_ms: ?u32) ![]u8 {
        const data = std.json.Value{ .string = prompt };
        try self.sendMessage(to, .get_user_input, data);

        const start_time = std.time.milliTimestamp();

        // Block until we get user_response
        while (true) {
            if (timeout_ms) |t| {
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
