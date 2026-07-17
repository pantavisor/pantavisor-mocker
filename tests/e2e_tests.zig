//! End-to-end tests: run the ACTUAL pantavisor-mocker binary as a child
//! process and interact with it from the outside — through its CLI, its
//! storage directory, and its pv-ctrl unix socket — exactly like a user or
//! pantavisor client would. No app code is linked into this file; the binary
//! path is injected by build.zig (`zig build e2e`).
//!
//! The tests are hermetic: a tiny in-process mock hub answers the binary's
//! pantahub HTTP calls on 127.0.0.1, so nothing ever reaches the real API and
//! no devices get registered anywhere.

const std = @import("std");
const build_options = @import("build_options");

const mocker_bin = build_options.mocker_bin;

// ---------------------------------------------------------------------------
// Mock pantahub: answers /auth/login with a token and everything else with
// "{}", which the mocker's unclaimed-device poll loop happily retries on.
// ---------------------------------------------------------------------------
const MockHub = struct {
    server: std.net.Server,
    thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    login_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    request_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn start(allocator: std.mem.Allocator) !*MockHub {
        const self = try allocator.create(MockHub);
        errdefer allocator.destroy(self);
        const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
        self.* = .{ .server = try addr.listen(.{ .reuse_address = true }) };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn port(self: *MockHub) u16 {
        return self.server.listen_address.getPort();
    }

    fn stop(self: *MockHub, allocator: std.mem.Allocator) void {
        self.quit.store(true, .release);
        // Unblock accept() with a dummy connection.
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |c| c.close() else |_| {}
        if (self.thread) |t| t.join();
        self.server.deinit();
        allocator.destroy(self);
    }

    fn serve(self: *MockHub) void {
        while (!self.quit.load(.acquire)) {
            const conn = self.server.accept() catch break;
            self.handle(conn.stream) catch {};
            conn.stream.close();
        }
    }

    fn handle(self: *MockHub, stream: std.net.Stream) !void {
        var buf: [16384]u8 = undefined;
        var total: usize = 0;
        var headers_end: usize = 0;
        while (total < buf.len) {
            const n = try stream.read(buf[total..]);
            if (n == 0) return;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |e| {
                headers_end = e + 4;
                break;
            }
        }
        if (headers_end == 0) return;

        // Drain the declared body so curl doesn't see a reset mid-send.
        var content_length: usize = 0;
        var it = std.mem.splitSequence(u8, buf[0..headers_end], "\r\n");
        while (it.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                const v = std.mem.trim(u8, line["content-length:".len..], " ");
                content_length = std.fmt.parseInt(usize, v, 10) catch 0;
            }
        }
        var body_read = total - headers_end;
        while (body_read < content_length) {
            const n = try stream.read(&buf);
            if (n == 0) break;
            body_read += n;
        }

        _ = self.request_count.fetchAdd(1, .monotonic);
        const req_line = buf[0..(std.mem.indexOf(u8, buf[0..headers_end], "\r\n") orelse headers_end)];

        const body: []const u8 = if (std.mem.startsWith(u8, req_line, "POST /auth/login")) blk: {
            _ = self.login_count.fetchAdd(1, .monotonic);
            break :blk "{\"token\":\"e2e-test-token\"}";
        } else "{}";

        var out: [512]u8 = undefined;
        const resp = try std.fmt.bufPrint(&out, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
        try stream.writeAll(resp);
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn writeHubConfig(allocator: std.mem.Allocator, storage: []const u8, hub_port: u16) !void {
    const cfg_dir = try std.fmt.allocPrint(allocator, "{s}/config", .{storage});
    defer allocator.free(cfg_dir);
    try std.fs.cwd().makePath(cfg_dir);

    const cfg_path = try std.fmt.allocPrint(allocator, "{s}/pantahub.config", .{cfg_dir});
    defer allocator.free(cfg_path);
    // Seeded creds skip registration; http://127.0.0.1 keeps everything local.
    const content = try std.fmt.allocPrint(allocator,
        \\PH_CREDS_HOST=http://127.0.0.1
        \\PH_CREDS_PORT={d}
        \\PH_CREDS_ID=6a5a5c0c2594c30009ae05e1
        \\PH_CREDS_PRN=prn:::devices:/6a5a5c0c2594c30009ae05e1
        \\PH_CREDS_SECRET=e2e-secret
        \\PH_METADATA_DEVMETA_INTERVAL=2
        \\PH_METADATA_USRMETA_INTERVAL=2
        \\
    , .{hub_port});
    defer allocator.free(content);
    try std.fs.cwd().writeFile(.{ .sub_path = cfg_path, .data = content });
}

/// Kills the child if the test hasn't marked it done within timeout_ms, so a
/// hung binary fails the test instead of hanging CI forever.
const Watchdog = struct {
    thread: std.Thread,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn arm(self: *Watchdog, child: *std.process.Child, timeout_ms: usize) !void {
        self.done = std.atomic.Value(bool).init(false);
        self.thread = try std.Thread.spawn(.{}, run, .{ self, child, timeout_ms });
    }

    fn run(self: *Watchdog, child: *std.process.Child, timeout_ms: usize) void {
        var elapsed: usize = 0;
        while (elapsed < timeout_ms and !self.done.load(.acquire)) : (elapsed += 100) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        if (!self.done.load(.acquire)) _ = child.kill() catch {};
    }

    fn disarm(self: *Watchdog) void {
        self.done.store(true, .release);
        self.thread.join();
    }
};

fn waitForFile(path: []const u8, timeout_ms: usize) !void {
    var elapsed: usize = 0;
    while (elapsed < timeout_ms) : (elapsed += 100) {
        if (std.fs.cwd().access(path, .{})) |_| return else |_| {}
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    return error.FileNeverAppeared;
}

fn pvctrlRequest(allocator: std.mem.Allocator, socket_path: []const u8, request: []const u8) ![]u8 {
    const stream = try std.net.connectUnixSocket(socket_path);
    defer stream.close();
    try stream.writeAll(request);
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
        // Responses close the connection, but don't rely on it for small ones.
        if (out.items.len > 1024 * 1024) break;
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "e2e: --help exits 0 and lists commands" {
    const allocator = std.testing.allocator;
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ mocker_bin, "--help" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
    // Usage text is printed via std.debug.print, i.e. to stderr.
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "start"));
}

test "e2e: full lifecycle — start, pv-ctrl object round-trip, clean reboot shutdown" {
    const allocator = std.testing.allocator;
    const storage = "tmp_e2e_lifecycle";
    std.fs.cwd().deleteTree(storage) catch {};
    defer std.fs.cwd().deleteTree(storage) catch {};

    var hub = try MockHub.start(allocator);
    defer hub.stop(allocator);
    try writeHubConfig(allocator, storage, hub.port());

    var child = std.process.Child.init(&[_][]const u8{ mocker_bin, "start", "--storage", storage, "--no-tui" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    var watchdog: Watchdog = undefined;
    try watchdog.arm(&child, 30_000);
    defer watchdog.disarm();

    // The REAL binary must bring up its pv-ctrl socket.
    const sock = storage ++ "/pantavisor/pv-ctrl";
    try waitForFile(sock, 15_000);

    // GET /containers answers over the live socket.
    {
        const resp = try pvctrlRequest(allocator, sock, "GET /containers HTTP/1.1\r\n\r\n");
        defer allocator.free(resp);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "HTTP/1.1 200 OK"));
    }

    // Streamed object upload against the real process: 256KB, chunked writes.
    const body = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 13 +% 3);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &hash, .{});
    const sha = std.fmt.bytesToHex(hash, .lower);
    {
        const stream = try std.net.connectUnixSocket(sock);
        defer stream.close();
        const head = try std.fmt.allocPrint(allocator, "PUT /objects/{s} HTTP/1.1\r\nContent-Length: {d}\r\n\r\n", .{ sha, body.len });
        defer allocator.free(head);
        try stream.writeAll(head);
        var sent: usize = 0;
        while (sent < body.len) {
            const end = @min(sent + 32 * 1024, body.len);
            try stream.writeAll(body[sent..end]);
            sent = end;
        }
        var buf: [1024]u8 = undefined;
        const n = try stream.read(&buf);
        try std.testing.expect(std.mem.containsAtLeast(u8, buf[0..n], 1, "HTTP/1.1 200 OK"));
    }

    // The object landed in the storage tree, byte-identical.
    {
        const obj_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ storage, sha });
        defer allocator.free(obj_path);
        const stored = try std.fs.cwd().readFileAlloc(allocator, obj_path, 1024 * 1024);
        defer allocator.free(stored);
        try std.testing.expectEqualSlices(u8, body, stored);
    }

    // ...and the binary serves it back over GET /objects/<sha>.
    {
        const req = try std.fmt.allocPrint(allocator, "GET /objects/{s} HTTP/1.1\r\n\r\n", .{sha});
        defer allocator.free(req);
        const resp = try pvctrlRequest(allocator, sock, req);
        defer allocator.free(resp);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "HTTP/1.1 200 OK"));
        // Body follows the blank line; verify its tail matches the upload.
        const split = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.NoBody;
        try std.testing.expectEqualSlices(u8, body, resp[split + 4 ..]);
    }

    // REBOOT_DEVICE must shut the whole process down cleanly (exit 0) — this
    // exercises the real shutdown ordering: router drain, logger join, renderer.
    {
        const resp = try pvctrlRequest(allocator, sock, "POST /commands HTTP/1.1\r\nContent-Length: 13\r\n\r\nREBOOT_DEVICE");
        defer allocator.free(resp);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "HTTP/1.1 200 OK"));
    }
    const term = try child.wait();
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);

    // The mocker really talked to the (mock) hub, and only to it.
    try std.testing.expect(hub.login_count.load(.acquire) >= 1);
}

test "e2e: --one-shot runs a cycle and exits 0 on its own" {
    const allocator = std.testing.allocator;
    const storage = "tmp_e2e_oneshot";
    std.fs.cwd().deleteTree(storage) catch {};
    defer std.fs.cwd().deleteTree(storage) catch {};

    var hub = try MockHub.start(allocator);
    defer hub.stop(allocator);
    try writeHubConfig(allocator, storage, hub.port());

    var child = std.process.Child.init(&[_][]const u8{ mocker_bin, "start", "--storage", storage, "--no-tui", "--one-shot" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    var watchdog: Watchdog = undefined;
    try watchdog.arm(&child, 30_000);
    defer watchdog.disarm();

    // One-shot's internal watchdog fires after ~10s; the process must exit 0
    // by itself, having scaffolded its storage tree.
    const term = try child.wait();
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);

    try std.fs.cwd().access(storage ++ "/revision-info.json", .{});
    try std.fs.cwd().access(storage ++ "/config/pantahub.config", .{});
    try std.fs.cwd().access(storage ++ "/logs", .{});
    try std.testing.expect(hub.request_count.load(.acquire) >= 1);
}
