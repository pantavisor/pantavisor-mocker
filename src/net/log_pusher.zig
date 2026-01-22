const std = @import("std");
const client_mod = @import("client.zig");
const local_store = @import("../core/local_store.zig");
const logger_mod = @import("../core/logger.zig");

pub fn push_logs(allocator: std.mem.Allocator, client: *client_mod.Client, store: *local_store.LocalStore, log: anytype) !void {
    if (client.token == null) return;
    std.debug.assert(client.pantahub_host.len > 0);
    std.debug.assert(store.base_path.len > 0);

    const rev = try store.get_revision();
    defer allocator.free(rev);

    const log_path = try store.get_log_path(rev);
    defer allocator.free(log_path);

    const offset = try store.get_log_offset(rev);

    const file = std.fs.cwd().openFile(log_path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();

    const file_size = (try file.stat()).size;
    if (file_size <= offset) return;

    try file.seekTo(offset);

    var entries = std.ArrayList(client_mod.LogEntry){};
    defer {
        for (entries.items) |e| allocator.free(e.msg);
        entries.deinit(allocator);
    }

    var line_buf = std.ArrayList(u8){};
    defer line_buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    var buf_start: usize = 0;
    var buf_end: usize = 0;
    var current_pos: u64 = offset;

    while (true) {
        if (buf_start == buf_end) {
            buf_start = 0;
            buf_end = file.read(&read_buf) catch |err| return err;
            if (buf_end == 0) break; // EOF
        }

        const c = read_buf[buf_start];
        buf_start += 1;
        current_pos += 1;

        if (c == '\n') {
            const line = line_buf.items;
            if (line.len > 0) {
                const now = std.time.timestamp();
                const now_ns = std.time.nanoTimestamp();

                const msg_dupe = try allocator.dupe(u8, line);
                errdefer allocator.free(msg_dupe);
                try entries.append(allocator, .{
                    .tsec = now,
                    .tnano = @as(i64, @intCast(@mod(now_ns, 1_000_000_000))),
                    .rev = rev,
                    .plat = "pantavisor",
                    .src = "/pantavisor.log",
                    .lvl = "INFO",
                    .msg = msg_dupe,
                });
            }
            line_buf.clearRetainingCapacity();
            if (entries.items.len >= 100) break;
        } else {
            try line_buf.append(allocator, c);
        }
    }

    // Handle last line if it doesn't end with newline
    if (line_buf.items.len > 0 and entries.items.len < 100) {
        const line = line_buf.items;
        const now = std.time.timestamp();
        const now_ns = std.time.nanoTimestamp();
        const msg_dupe = try allocator.dupe(u8, line);
        errdefer allocator.free(msg_dupe);
        try entries.append(allocator, .{
            .tsec = now,
            .tnano = @as(i64, @intCast(@mod(now_ns, 1_000_000_000))),
            .rev = rev,
            .plat = "pantavisor",
            .src = "/pantavisor.log",
            .lvl = "INFO",
            .msg = msg_dupe,
        });
    }

    if (entries.items.len > 0) {
        log.log(
            "Pushing {d} log entries for revision {s}...",
            .{ entries.items.len, rev },
        );
        client.post_logs(entries.items) catch |err| {
            log.log("Failed to push logs: {any}", .{err});
            return;
        };
        try store.set_log_offset(rev, current_pos);
    }
}
