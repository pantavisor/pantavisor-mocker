const std = @import("std");
const ipc = @import("app").ipc;

// Spins up a unix-socket listener the IpcClient can connect to. The listen
// backlog accepts the connection, so the client can be created before accept().
fn setupSocket(dir: []const u8, sock_name: []const u8, buf: []u8) !std.net.Server {
    std.fs.cwd().makePath(dir) catch {};
    const sock_path = try std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, sock_name });
    std.fs.cwd().deleteFile(sock_path) catch {};
    const address = try std.net.Address.initUnix(sock_path);
    return try address.listen(.{});
}

test "ipc: coalesced messages in one read are all delivered" {
    const allocator = std.testing.allocator;
    const tmp_dir = "tmp_ipc_test_coalesce";
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};
    var path_buf: [128]u8 = undefined;
    var server = try setupSocket(tmp_dir, "ipc.sock", &path_buf);
    defer server.deinit();

    var client = try ipc.IpcClient.init(allocator, tmp_dir ++ "/ipc.sock", .logger);
    defer client.deinit();

    const conn = try server.accept();
    defer conn.stream.close();

    // Two newline-framed messages delivered in a single write (coalesced).
    const two_msgs =
        "{\"from\":\"core\",\"to\":\"logger\",\"type\":\"response_ok\"}\n" ++
        "{\"from\":\"core\",\"to\":\"logger\",\"type\":\"subsystem_start\"}\n";
    try conn.stream.writeAll(two_msgs);

    var first = try client.receiveMessage();
    defer first.deinit();
    try std.testing.expectEqual(@import("app").messages.MessageType.response_ok, first.value.type);

    var second = try client.receiveMessage();
    defer second.deinit();
    try std.testing.expectEqual(@import("app").messages.MessageType.subsystem_start, second.value.type);
}

test "ipc: oversized unframed data drops the connection instead of growing the buffer" {
    const allocator = std.testing.allocator;
    const tmp_dir = "tmp_ipc_test_overflow";
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};
    var path_buf: [128]u8 = undefined;
    var server = try setupSocket(tmp_dir, "ipc.sock", &path_buf);
    defer server.deinit();

    var client = try ipc.IpcClient.init(allocator, tmp_dir ++ "/ipc.sock", .logger);
    defer client.deinit();

    const conn = try server.accept();
    defer conn.stream.close();

    // Stream >64KB with no '\n': the framing bound must trip.
    const chunk = [_]u8{'A'} ** 4096;
    var sent: usize = 0;
    while (sent < 80 * 1024) : (sent += chunk.len) {
        try conn.stream.writeAll(&chunk);
    }

    try std.testing.expectError(error.MessageTooLong, client.receiveMessage());

    // The oversized bytes must not be retained: otherwise every caller's
    // catch-and-retry loop re-reads into an ever-growing buffer.
    try std.testing.expectEqual(@as(usize, 0), client.read_buf.items.len);

    // And the connection must be dead so retrying callers break out of their
    // receive loops instead of busy-looping on the same poisoned stream.
    try std.testing.expectError(error.ConnectionClosed, client.receiveMessage());
}
