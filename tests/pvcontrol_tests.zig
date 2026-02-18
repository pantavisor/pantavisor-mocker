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
