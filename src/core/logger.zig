const std = @import("std");
const ipc = @import("../core/ipc.zig");
const messages = @import("../core/messages.zig");

pub const Logger = struct {
    file: std.fs.File,
    mutex: std.Thread.Mutex,
    debug_mode: bool,
    ipc_client: ?*ipc.IpcClient = null,
    allocator: ?std.mem.Allocator = null,

    pub fn init(path: []const u8, debug_mode: bool) !Logger {
        std.debug.assert(path.len > 0);
        const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
        try file.seekFromEnd(0);
        std.debug.assert(file.handle != -1);

        return Logger{
            .file = file,
            .mutex = .{},
            .debug_mode = debug_mode,
        };
    }

    pub fn deinit(self: *Logger) void {
        std.debug.assert(self.file.handle != -1);
        self.file.close();
    }

    pub fn log(self: *Logger, comptime format: []const u8, args: anytype) void {
        std.debug.assert(format.len > 0);
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&buf, format ++ "\n", args)) |written| {
            std.debug.assert(written.len > 0);

            if (self.ipc_client) |client| {
                const msg = if (written.len > 0 and written[written.len - 1] == '\n')
                    written[0 .. written.len - 1]
                else
                    written;

                const log_data = messages.LogData{
                    .level = "INFO",
                    .subsystem = "background",
                    .message = msg,
                    .timestamp = std.time.timestamp(),
                };

                // Convert log_data to json.Value
                var map = std.StringArrayHashMap(std.json.Value).init(self.allocator.?);
                defer map.deinit();
                map.put("level", .{ .string = log_data.level }) catch {};
                map.put("subsystem", .{ .string = log_data.subsystem }) catch {};
                map.put("message", .{ .string = log_data.message }) catch {};
                map.put("timestamp", .{ .integer = log_data.timestamp }) catch {};

                client.sendMessage(.logger, .log_message, .{ .object = map }) catch {};
                return;
            }
            self.file.writeAll(written) catch {};
        } else |_| {
            const msg = "Log message too long\n";
            if (self.ipc_client) |client| {
                const log_data = messages.LogData{
                    .level = "ERROR",
                    .subsystem = "background",
                    .message = "Log message too long",
                    .timestamp = std.time.timestamp(),
                };

                var map = std.StringArrayHashMap(std.json.Value).init(self.allocator.?);
                defer map.deinit();
                map.put("level", .{ .string = log_data.level }) catch {};
                map.put("subsystem", .{ .string = log_data.subsystem }) catch {};
                map.put("message", .{ .string = log_data.message }) catch {};
                map.put("timestamp", .{ .integer = log_data.timestamp }) catch {};

                client.sendMessage(.logger, .log_message, .{ .object = map }) catch {};
                return;
            }
            self.file.writeAll(msg) catch {};
        }
    }

    pub fn log_debug(self: *Logger, comptime format: []const u8, args: anytype) void {
        if (self.debug_mode) {
            self.log("[DEBUG] " ++ format, args);
        }
    }

    pub fn switch_log_file(self: *Logger, new_path: []const u8) !void {
        std.debug.assert(new_path.len > 0);
        self.mutex.lock();
        defer self.mutex.unlock();

        self.file.close();
        const file = try std.fs.cwd().createFile(new_path, .{ .read = true, .truncate = false });
        try file.seekFromEnd(0);
        std.debug.assert(file.handle != -1);
        self.file = file;
    }
};
