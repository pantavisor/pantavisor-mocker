const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const curl = @import("../net/curl.zig");
const client_mod = @import("../net/client.zig");
const config_mod = @import("../core/config.zig");
const local_store = @import("../core/local_store.zig");
const ownership = @import("../core/ownership.zig");
const device_config = @import("device_config.zig");

const DEFAULT_HOST = "api.pantahub.com";
const DEFAULT_PORT = "443";
const PLACEHOLDER_TOKENS = [_][]const u8{ "YOUR_AUTOJOIN_TOKEN_HERE", "YOUR_AUTO_TOKEN" };

/// Check the runtime dependencies and the local setup, and tell the user what
/// to fix. Exits 1 when a required check fails; warnings don't fail.
pub const DoctorCmd = struct {
    storage: ?[]const u8 = null,
    config: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: ?[]const u8 = null,
    offline: bool = false,

    pub const meta = .{
        .description = "Check dependencies (libcurl, tmux, curl), config, storage and Pantahub connectivity.",
        .args = .{
            .storage = .{ .short = 's', .help = "Storage directory to check (default: ./storage when it exists)." },
            .config = .{ .short = 'c', .help = "Device config JSON to check." },
            .host = .{ .help = "Pantahub host for the connectivity check (default: from config/storage, else api.pantahub.com)." },
            .port = .{ .help = "Pantahub port for the connectivity check (default: from config/storage, else 443)." },
            .offline = .{ .help = "Skip the Pantahub connectivity check." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var report = Report{};
        std.debug.print("pantavisor-mocker {s} doctor ({s}-{s})\n\n", .{
            build_options.cli_version,
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
        });

        checkLibcurl(&report);
        checkTool(arena, &report, "tmux", &.{ "tmux", "-V" }, "needed by `swarm simulate` / `swarm run`");
        checkTool(arena, &report, "curl", &.{ "curl", "--version" }, "needed by the `pvcontrol` helper script");

        // Endpoint resolution: flags > device config > storage > defaults.
        var endpoint = Endpoint{};
        if (self.config) |path| checkDeviceConfig(arena, &report, path, &endpoint);
        const storage: ?[]const u8 = self.storage orelse blk: {
            std.fs.cwd().access("storage", .{}) catch break :blk null;
            break :blk "storage";
        };
        if (storage) |path| checkStorage(arena, &report, path, &endpoint);

        if (self.offline) {
            report.info("Pantahub connectivity check skipped (--offline)", .{});
        } else {
            const host = self.host orelse endpoint.host orelse DEFAULT_HOST;
            const port = self.port orelse endpoint.port orelse DEFAULT_PORT;
            checkConnectivity(arena, &report, host, port);
        }

        std.debug.print("\n{d} ok, {d} warning(s), {d} failure(s)\n", .{ report.ok_count, report.warn_count, report.fail_count });
        if (report.fail_count > 0) std.process.exit(1);
    }
};

const Endpoint = struct {
    host: ?[]const u8 = null,
    port: ?[]const u8 = null,
};

const Report = struct {
    ok_count: u32 = 0,
    warn_count: u32 = 0,
    fail_count: u32 = 0,

    fn ok(self: *Report, comptime fmt: []const u8, args: anytype) void {
        self.ok_count += 1;
        std.debug.print("  [ ok ] " ++ fmt ++ "\n", args);
    }

    fn warn(self: *Report, comptime fmt: []const u8, args: anytype) void {
        self.warn_count += 1;
        std.debug.print("  [warn] " ++ fmt ++ "\n", args);
    }

    fn fail(self: *Report, comptime fmt: []const u8, args: anytype) void {
        self.fail_count += 1;
        std.debug.print("  [FAIL] " ++ fmt ++ "\n", args);
    }

    fn info(_: *Report, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("  [info] " ++ fmt ++ "\n", args);
    }

    fn hint(_: *Report, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("         " ++ fmt ++ "\n", args);
    }
};

fn installHint(report: *Report, package: []const u8) void {
    switch (builtin.os.tag) {
        .macos => report.hint("install: brew install {s}", .{package}),
        else => report.hint("install: apt install {s} (or your distro's package manager)", .{package}),
    }
}

fn checkLibcurl(report: *Report) void {
    const info = curl.c.curl_version_info(curl.c.CURLVERSION_NOW);
    const version = std.mem.span(info.*.version);
    const ssl: []const u8 = if (info.*.ssl_version) |s| std.mem.span(s) else "no TLS";

    var https = false;
    if (info.*.protocols) |protocols| {
        var i: usize = 0;
        while (protocols[i]) |p| : (i += 1) {
            if (std.mem.eql(u8, std.mem.span(p), "https")) https = true;
        }
    }

    if (https and (info.*.features & curl.c.CURL_VERSION_SSL) != 0) {
        report.ok("libcurl {s} ({s}), https supported", .{ version, ssl });
    } else {
        report.fail("libcurl {s} has no HTTPS/TLS support", .{version});
        report.hint("Pantahub is only reachable over HTTPS; install a TLS-enabled libcurl", .{});
        installHint(report, if (builtin.os.tag == .macos) "curl" else "libcurl4");
    }
}

fn checkTool(allocator: std.mem.Allocator, report: *Report, name: []const u8, argv: []const []const u8, purpose: []const u8) void {
    const result = std.process.Child.run(.{ .allocator = allocator, .argv = argv }) catch {
        report.warn("{s} not found: {s}", .{ name, purpose });
        installHint(report, name);
        return;
    };
    const out = if (result.stdout.len > 0) result.stdout else result.stderr;
    report.ok("{s}", .{toolVersion(out, name)});
}

/// "name version" from a --version banner: the first two words of its first
/// line ("curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/..." -> "curl 8.5.0").
fn toolVersion(out: []const u8, fallback: []const u8) []const u8 {
    const line = std.mem.trim(u8, std.mem.sliceTo(out, '\n'), " \r\t");
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next() orelse return fallback;
    _ = it.next() orelse return line;
    return line[0..it.index];
}

fn isPlaceholderToken(token: []const u8) bool {
    for (PLACEHOLDER_TOKENS) |p| {
        if (std.mem.eql(u8, token, p)) return true;
    }
    return false;
}

fn checkDeviceConfig(allocator: std.mem.Allocator, report: *Report, path: []const u8, endpoint: *Endpoint) void {
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 100) catch |err| {
        report.fail("device config {s}: cannot read ({s})", .{ path, @errorName(err) });
        report.hint("create one with: pantavisor-mocker config -t <token> -o {s}", .{path});
        return;
    };
    const parsed = std.json.parseFromSliceLeaky(device_config.DeviceJsonSchema, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        report.fail("device config {s}: invalid JSON ({s})", .{ path, @errorName(err) });
        return;
    };
    report.ok("device config {s} parses", .{path});

    endpoint.host = parsed.pantahub.host;
    if (parsed.pantahub.port) |port| {
        endpoint.port = portString(allocator, port);
    }

    const token = parsed.pantahub.autojoin_token orelse "";
    if (token.len == 0 or isPlaceholderToken(token)) {
        report.warn("device config {s}: pantahub.autojoin_token is not set", .{path});
        report.hint("a new device can't register without it; an already registered storage still works", .{});
    }

    if (parsed.ownership.cert != null or parsed.ownership.key != null) {
        const dir = ownership.configDir(path);
        inline for (.{ "cert", "key" }) |field| {
            if (@field(parsed.ownership, field)) |rel| {
                const resolved = ownership.resolve(allocator, dir, rel) catch rel;
                if (std.fs.cwd().access(resolved, .{})) |_| {
                    report.ok("ownership " ++ field ++ " {s} found", .{resolved});
                } else |_| {
                    report.fail("ownership " ++ field ++ " {s} not found", .{resolved});
                }
            } else {
                report.fail("device config {s}: ownership needs both cert and key", .{path});
            }
        }
    }
}

fn portString(allocator: std.mem.Allocator, value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}) catch null,
        else => null,
    };
}

/// Longest path std.net.Address.initUnix accepts (sun_path minus the NUL).
const max_socket_path = @typeInfo(@FieldType(std.posix.sockaddr.un, "path")).array.len - 1;

fn socketPathFits(storage: []const u8, rel: []const u8) bool {
    return storage.len + 1 + rel.len <= max_socket_path;
}

const NoopLog = struct {
    pub fn log(_: @This(), comptime _: []const u8, _: anytype) void {}
};

fn checkStorage(allocator: std.mem.Allocator, report: *Report, path: []const u8, endpoint: *Endpoint) void {
    // Sockets live under the storage dir: mocker.sock and pantavisor/pv-ctrl.
    const longest = "pantavisor/pv-ctrl";
    if (socketPathFits(path, longest)) {
        report.ok("storage {s}: socket paths fit ({d}/{d} chars)", .{ path, path.len + 1 + longest.len, max_socket_path });
    } else {
        report.fail("storage {s}: path too long for its unix sockets ({d} > {d} chars)", .{ path, path.len + 1 + longest.len, max_socket_path });
        report.hint("use a shorter storage path (e.g. -s ./dev1)", .{});
    }

    var dir = std.fs.cwd().openDir(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            report.info("storage {s} not initialized yet (`start -c` or `init` creates it)", .{path});
        } else {
            report.fail("storage {s}: cannot open ({s})", .{ path, @errorName(err) });
        }
        return;
    };
    defer dir.close();

    const probe = ".doctor-probe";
    if (dir.createFile(probe, .{})) |file| {
        file.close();
        dir.deleteFile(probe) catch {};
        report.ok("storage {s} is writable", .{path});
    } else |err| {
        report.fail("storage {s} is not writable ({s})", .{ path, @errorName(err) });
    }

    const store = local_store.LocalStore.init_view(allocator, path) catch return;
    // Allocated in the doctor's arena, so no deinit: the endpoint strings
    // taken from it below must outlive this function.
    const cfg = config_mod.load(allocator, store, NoopLog{}) catch |err| {
        report.fail("storage {s}: cannot load config/pantahub.config ({s})", .{ path, @errorName(err) });
        report.hint("re-create it with: pantavisor-mocker init -s {s} -c <device.json>", .{path});
        return;
    };
    if (endpoint.host == null) endpoint.host = cfg.pantahub_host;
    if (endpoint.port == null) endpoint.port = cfg.pantahub_port;

    if (cfg.creds_prn) |prn| {
        report.ok("storage {s}: registered as {s}", .{ path, prn });
    } else if (cfg.factory_autotok) |tok| {
        if (tok.len > 0 and !isPlaceholderToken(tok)) {
            report.info("storage {s}: not registered yet; will register with the autojoin token", .{path});
        } else {
            report.warn("storage {s}: not registered and no autojoin token", .{path});
        }
    } else {
        report.warn("storage {s}: not registered and no autojoin token", .{path});
        report.hint("set one with: pantavisor-mocker init -s {s} -t <token>", .{path});
    }

    if (cfg.client_cert != null and cfg.client_key != null) {
        report.ok("storage {s}: TLS ownership cert/key present", .{path});
    }
}

fn discard(_: *anyopaque, size: usize, nmemb: usize, _: *anyopaque) callconv(.c) usize {
    return size * nmemb;
}

fn checkConnectivity(allocator: std.mem.Allocator, report: *Report, host: []const u8, port: []const u8) void {
    const scheme = if (client_mod.Client.isLocalAddress(host)) "http" else "https";
    const url = std.fmt.allocPrintSentinel(allocator, "{s}://{s}:{s}/", .{ scheme, host, port }, 0) catch return;

    var handle = curl.Curl.init() catch {
        report.fail("Pantahub {s}: cannot create a curl handle", .{url});
        return;
    };
    defer handle.deinit();
    var sink: u8 = 0;
    handle.set_opt(curl.c.CURLOPT_URL, url) catch {};
    handle.set_opt(curl.c.CURLOPT_WRITEFUNCTION, &discard) catch {};
    handle.set_opt(curl.c.CURLOPT_WRITEDATA, @as(*anyopaque, &sink)) catch {};
    handle.set_opt(curl.c.CURLOPT_CONNECTTIMEOUT, 5) catch {};
    handle.set_opt(curl.c.CURLOPT_TIMEOUT, 10) catch {};

    const res = curl.c.curl_easy_perform(handle.handle);
    if (res != curl.c.CURLE_OK) {
        report.fail("Pantahub {s} unreachable: {s}", .{ url, std.mem.span(curl.c.curl_easy_strerror(res)) });
        switch (res) {
            curl.c.CURLE_PEER_FAILED_VERIFICATION, curl.c.CURLE_SSL_CACERT_BADFILE => {
                report.hint("TLS verification failed: install CA certificates (ca-certificates)", .{});
            },
            curl.c.CURLE_COULDNT_RESOLVE_HOST => report.hint("check the host name and your DNS", .{}),
            else => report.hint("check the host/port, your network and any proxy settings", .{}),
        }
        return;
    }
    var status: c_long = 0;
    handle.get_info(curl.c.CURLINFO_RESPONSE_CODE, &status) catch {};
    report.ok("Pantahub {s} reachable (HTTP {d})", .{ url, status });
}

test "placeholder tokens are detected" {
    try std.testing.expect(isPlaceholderToken("YOUR_AUTOJOIN_TOKEN_HERE"));
    try std.testing.expect(!isPlaceholderToken("abc123"));
}

test "tool version is the first two words" {
    try std.testing.expectEqualStrings("curl 8.5.0", toolVersion("curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0\nRelease-Date: x\n", "curl"));
    try std.testing.expectEqualStrings("tmux 3.4", toolVersion("tmux 3.4\n", "tmux"));
    try std.testing.expectEqualStrings("tmux", toolVersion("", "tmux"));
}

test "socket path limit" {
    try std.testing.expect(socketPathFits("storage", "pantavisor/pv-ctrl"));
    const long = "x" ** 120;
    try std.testing.expect(!socketPathFits(long, "pantavisor/pv-ctrl"));
}
