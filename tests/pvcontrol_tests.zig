const std = @import("std");
const http_parser = @import("app").core_mocker.pvcontrol_server.http_parser;
const pvcontrol_server = @import("app").core_mocker.pvcontrol_server;
const local_store = @import("app").local_store;
const logger = @import("app").logger;

test "http_parser: parse GET request" {
    const allocator = std.testing.allocator;
    const raw = "GET /containers HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var req = try http_parser.parseRequest(allocator, raw);
    defer req.deinit(allocator);

    try std.testing.expectEqual(http_parser.HttpMethod.GET, req.method);
    try std.testing.expectEqualStrings("/containers", req.path);
}

test "http_parser: parse POST request with body" {
    const allocator = std.testing.allocator;
    const raw = "POST /commands HTTP/1.1\r\nContent-Length: 13\r\n\r\nREBOOT_DEVICE";
    var req = try http_parser.parseRequest(allocator, raw);
    defer req.deinit(allocator);

    try std.testing.expectEqual(http_parser.HttpMethod.POST, req.method);
    try std.testing.expectEqualStrings("/commands", req.path);
    try std.testing.expectEqualStrings("REBOOT_DEVICE", req.body.?);
}

test "pvcontrol_server: integration test" {
    const allocator = std.testing.allocator;
    const tmp_dir_path = "tmp_pvcontrol_test";
    std.fs.cwd().makePath(tmp_dir_path) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir_path) catch {};

    var quit_flag = std.atomic.Value(bool).init(false);

    // Setup storage
    var store = try local_store.LocalStore.init(allocator, tmp_dir_path, null, false);
    defer store.deinit();

    try store.init_revision_dirs("0");
    try store.save_revision_state("0", "{\"config\":{\"components\":{\"c1\":{\"group\":\"g1\"}}}}");

    // Setup logger
    const log_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir_path, "test.log" });
    defer allocator.free(log_path);
    var log = try logger.Logger.init(log_path, true);
    defer log.deinit();

    var server = try pvcontrol_server.PvControlServer.init(allocator, tmp_dir_path, &quit_flag, true, &log);
    defer server.deinit();

    try server.start();
    // Wait for server to start and create socket
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Connect to socket
    const stream = try std.net.connectUnixSocket(server.socket_path);
    defer stream.close();

    // Send GET /containers
    try stream.writeAll("GET /containers HTTP/1.1\r\n\r\n");

    var buf: [4096]u8 = undefined;
    const n = try stream.read(&buf);
    const response = buf[0..n];

    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"name\":\"c1\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"group\":\"g1\""));

    // Test REBOOT_DEVICE command
    const stream2 = try std.net.connectUnixSocket(server.socket_path);
    defer stream2.close();
    try stream2.writeAll("POST /commands HTTP/1.1\r\nContent-Length: 13\r\n\r\nREBOOT_DEVICE");

    const n2 = try stream2.read(&buf);
    const response2 = buf[0..n2];
    try std.testing.expect(std.mem.containsAtLeast(u8, response2, 1, "HTTP/1.1 200 OK"));

    // Wait a bit for quit flag to be set
    std.Thread.sleep(100 * std.time.ns_per_ms);
    try std.testing.expect(quit_flag.load(.acquire) == true);
}

test "pvcontrol_server: huge Content-Length is rejected, not allocated" {
    const allocator = std.testing.allocator;
    const tmp_dir_path = "tmp_pvcontrol_test_cl";
    std.fs.cwd().makePath(tmp_dir_path) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir_path) catch {};

    var quit_flag = std.atomic.Value(bool).init(false);

    var store = try local_store.LocalStore.init(allocator, tmp_dir_path, null, false);
    defer store.deinit();
    try store.init_revision_dirs("0");
    try store.save_revision_state("0", "{\"config\":{\"components\":{}}}");

    const log_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir_path, "test.log" });
    defer allocator.free(log_path);
    var log = try logger.Logger.init(log_path, true);
    defer log.deinit();

    var server = try pvcontrol_server.PvControlServer.init(allocator, tmp_dir_path, &quit_flag, true, &log);
    defer server.deinit();
    try server.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    var buf: [4096]u8 = undefined;

    // maxInt(usize): pre-fix this overflows `headers_end + cl` and panics the
    // handler thread (aborting the whole process in Debug/ReleaseSafe).
    {
        const stream = try std.net.connectUnixSocket(server.socket_path);
        defer stream.close();
        try stream.writeAll("POST /commands HTTP/1.1\r\nContent-Length: 18446744073709551615\r\n\r\n");
        const n = try stream.read(&buf);
        try std.testing.expect(std.mem.containsAtLeast(u8, buf[0..n], 1, "413"));
    }

    // Large but non-overflowing: pre-fix this is a multi-GB allocation.
    {
        const stream = try std.net.connectUnixSocket(server.socket_path);
        defer stream.close();
        try stream.writeAll("POST /commands HTTP/1.1\r\nContent-Length: 4294967296\r\n\r\n");
        const n = try stream.read(&buf);
        try std.testing.expect(std.mem.containsAtLeast(u8, buf[0..n], 1, "413"));
    }

    // Object uploads legitimately carry huge bodies (container images): a 200MB
    // declared PUT /objects must NOT be rejected. The server allocates and waits
    // for the body; shutting down our write side makes it read EOF and drop the
    // connection without a response — so EOF here proves "accepted", while a 413
    // would arrive as readable bytes.
    {
        const stream = try std.net.connectUnixSocket(server.socket_path);
        defer stream.close();
        const sha = "a" ** 64;
        try stream.writeAll("PUT /objects/" ++ sha ++ " HTTP/1.1\r\nContent-Length: 209715200\r\n\r\n");
        std.posix.shutdown(stream.handle, .send) catch {};
        const n = try stream.read(&buf);
        try std.testing.expectEqual(@as(usize, 0), n);
    }

    // ...but even object uploads have a ceiling.
    {
        const stream = try std.net.connectUnixSocket(server.socket_path);
        defer stream.close();
        const sha = "a" ** 64;
        try stream.writeAll("PUT /objects/" ++ sha ++ " HTTP/1.1\r\nContent-Length: 2147483649\r\n\r\n");
        const n = try stream.read(&buf);
        try std.testing.expect(std.mem.containsAtLeast(u8, buf[0..n], 1, "413"));
    }

    // Sanity: a normal-sized body still works after the cap.
    {
        const stream = try std.net.connectUnixSocket(server.socket_path);
        defer stream.close();
        try stream.writeAll("POST /commands HTTP/1.1\r\nContent-Length: 13\r\n\r\nREBOOT_DEVICE");
        const n = try stream.read(&buf);
        try std.testing.expect(std.mem.containsAtLeast(u8, buf[0..n], 1, "HTTP/1.1 200 OK"));
    }
}

test "pvcontrol_server: streamed object upload round-trip" {
    const allocator = std.testing.allocator;
    const tmp_dir_path = "tmp_pvcontrol_test_objstream";
    std.fs.cwd().makePath(tmp_dir_path) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir_path) catch {};

    var quit_flag = std.atomic.Value(bool).init(false);

    var store = try local_store.LocalStore.init(allocator, tmp_dir_path, null, false);
    defer store.deinit();
    try store.init_revision_dirs("0");
    try store.save_revision_state("0", "{\"config\":{\"components\":{}}}");

    const log_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir_path, "test.log" });
    defer allocator.free(log_path);
    var log = try logger.Logger.init(log_path, true);
    defer log.deinit();

    var server = try pvcontrol_server.PvControlServer.init(allocator, tmp_dir_path, &quit_flag, true, &log);
    defer server.deinit();
    try server.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 1MB body, sent in several writes so both the prefill (bytes pulled in
    // with the headers) and the streamed-read path are exercised.
    const body = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &hash, .{});
    const sha = std.fmt.bytesToHex(hash, .lower);

    var buf: [4096]u8 = undefined;

    // Correct sha: streamed to disk, verified, renamed into place.
    {
        const stream = try std.net.connectUnixSocket(server.socket_path);
        defer stream.close();
        const head = try std.fmt.allocPrint(allocator, "PUT /objects/{s} HTTP/1.1\r\nContent-Length: {d}\r\n\r\n", .{ sha, body.len });
        defer allocator.free(head);
        try stream.writeAll(head);
        var sent: usize = 0;
        while (sent < body.len) {
            const end = @min(sent + 64 * 1024, body.len);
            try stream.writeAll(body[sent..end]);
            sent = end;
        }
        const n = try stream.read(&buf);
        try std.testing.expect(std.mem.containsAtLeast(u8, buf[0..n], 1, "HTTP/1.1 200 OK"));
    }

    // The stored object must be byte-identical to what was sent.
    {
        const obj_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ tmp_dir_path, sha });
        defer allocator.free(obj_path);
        const stored = try std.fs.cwd().readFileAlloc(allocator, obj_path, 2 * 1024 * 1024);
        defer allocator.free(stored);
        try std.testing.expectEqualSlices(u8, body, stored);
    }

    // Wrong sha: rejected, and neither the object nor the temp file remains.
    {
        const bad_sha = "b" ** 64;
        const stream = try std.net.connectUnixSocket(server.socket_path);
        defer stream.close();
        const head = try std.fmt.allocPrint(allocator, "PUT /objects/{s} HTTP/1.1\r\nContent-Length: {d}\r\n\r\n", .{ bad_sha, body.len });
        defer allocator.free(head);
        try stream.writeAll(head);
        try stream.writeAll(body);
        const n = try stream.read(&buf);
        try std.testing.expect(std.mem.containsAtLeast(u8, buf[0..n], 1, "400"));

        const obj_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ tmp_dir_path, bad_sha });
        defer allocator.free(obj_path);
        try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(obj_path, .{}));
        const tmp_upload = try std.fmt.allocPrint(allocator, "{s}/objects/.upload-{s}", .{ tmp_dir_path, bad_sha });
        defer allocator.free(tmp_upload);
        try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(tmp_upload, .{}));
    }
}
