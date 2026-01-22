const std = @import("std");
const local_store = @import("local_store.zig");

pub const Config = struct {
    allocator: std.mem.Allocator,
    pantahub_host: ?[]const u8,
    pantahub_port: ?[]const u8,
    creds_id: ?[]const u8,
    creds_secret: ?[]const u8,
    creds_prn: ?[]const u8,
    creds_challenge: ?[]const u8 = null,
    is_claimed: bool = false,
    devmeta_interval_s: u64 = 60,
    usrmeta_interval_s: u64 = 60,
    factory_autotok: ?[]const u8 = null,
    client_cert: ?[]const u8 = null,
    client_key: ?[]const u8 = null,

    // Mocker JSON overrides
    mocker_meta: ?std.json.Value = null,
    mocker_json_parsed: ?std.json.Parsed(std.json.Value) = null,

    pub fn deinit(self: *Config) void {
        std.debug.assert(self.devmeta_interval_s >= 0);
        std.debug.assert(self.usrmeta_interval_s >= 0);
        if (self.pantahub_host) |v| self.allocator.free(v);
        if (self.pantahub_port) |v| self.allocator.free(v);
        if (self.creds_id) |v| self.allocator.free(v);
        if (self.creds_secret) |v| self.allocator.free(v);
        if (self.creds_prn) |v| self.allocator.free(v);
        if (self.creds_challenge) |v| self.allocator.free(v);
        if (self.factory_autotok) |v| self.allocator.free(v);
        if (self.client_cert) |v| self.allocator.free(v);
        if (self.client_key) |v| self.allocator.free(v);

        if (self.mocker_json_parsed) |p| p.deinit();
    }

    pub fn save_credentials(self: *Config, store: local_store.LocalStore, prn: []const u8, secret: []const u8, challenge: ?[]const u8) !void {
        std.debug.assert(prn.len > 0);
        std.debug.assert(secret.len > 0);
        try store.save_config_value("PH_CREDS_PRN", prn);
        try store.save_config_value("PH_CREDS_SECRET", secret);
        if (challenge) |c| try store.save_config_value("PH_CREDS_CHALLENGE", c);

        if (self.creds_prn) |v| self.allocator.free(v);
        self.creds_prn = try self.allocator.dupe(u8, prn);

        if (self.creds_secret) |v| self.allocator.free(v);
        self.creds_secret = try self.allocator.dupe(u8, secret);

        if (self.creds_challenge) |v| self.allocator.free(v);
        self.creds_challenge = if (challenge) |c| try self.allocator.dupe(u8, c) else null;
    }

    pub fn set_claimed(self: *Config, store: local_store.LocalStore, claimed: bool) !void {
        try store.save_config_value("PH_IS_CLAIMED", if (claimed) "1" else "0");
        self.is_claimed = claimed;
    }
};

pub fn load(allocator: std.mem.Allocator, store: local_store.LocalStore, log: anytype) !Config {
    std.debug.assert(store.base_path.len > 0);
    const config_content = try store.read_config(allocator);
    defer allocator.free(config_content);
    std.debug.assert(config_content.len >= 0);

    var cfg = Config{
        .allocator = allocator,
        .pantahub_host = null,
        .pantahub_port = null,
        .creds_id = null,
        .creds_secret = null,
        .creds_prn = null,
        .creds_challenge = null,
        .is_claimed = false,
        .devmeta_interval_s = 60,
        .usrmeta_interval_s = 60,
        .factory_autotok = null,
    };
    errdefer cfg.deinit();

    var it = std.mem.splitScalar(u8, config_content, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var parts = std.mem.splitScalar(u8, line, '=');
        const key = parts.first();
        const value = parts.next() orelse continue;
        const trimmed_value = std.mem.trim(u8, value, " \t\r");
        if (trimmed_value.len == 0) continue;

        if (std.mem.eql(u8, key, "PH_CREDS_HOST")) {
            if (cfg.pantahub_host) |v| allocator.free(v);
            cfg.pantahub_host = try allocator.dupe(u8, trimmed_value);
        } else if (std.mem.eql(u8, key, "PH_CREDS_PORT")) {
            if (cfg.pantahub_port) |v| allocator.free(v);
            cfg.pantahub_port = try allocator.dupe(u8, trimmed_value);
        } else if (std.mem.eql(u8, key, "PH_CREDS_ID")) {
            if (cfg.creds_id) |v| allocator.free(v);
            cfg.creds_id = try allocator.dupe(u8, trimmed_value);
        } else if (std.mem.eql(u8, key, "PH_CREDS_SECRET")) {
            if (cfg.creds_secret) |v| allocator.free(v);
            cfg.creds_secret = try allocator.dupe(u8, trimmed_value);
        } else if (std.mem.eql(u8, key, "PH_CREDS_PRN")) {
            if (cfg.creds_prn) |v| allocator.free(v);
            cfg.creds_prn = try allocator.dupe(u8, trimmed_value);
        } else if (std.mem.eql(u8, key, "PH_CREDS_CHALLENGE")) {
            if (cfg.creds_challenge) |v| allocator.free(v);
            cfg.creds_challenge = try allocator.dupe(u8, trimmed_value);
        } else if (std.mem.eql(u8, key, "PH_IS_CLAIMED")) {
            cfg.is_claimed = std.mem.eql(u8, trimmed_value, "1");
        } else if (std.mem.eql(u8, key, "PH_METADATA_DEVMETA_INTERVAL")) {
            cfg.devmeta_interval_s = std.fmt.parseInt(u64, trimmed_value, 10) catch 60;
        } else if (std.mem.eql(u8, key, "PH_METADATA_USRMETA_INTERVAL")) {
            cfg.usrmeta_interval_s = std.fmt.parseInt(u64, trimmed_value, 10) catch 60;
        } else if (std.mem.eql(u8, key, "factory.autotok") or std.mem.eql(u8, key, "PH_FACTORY_AUTOTOK")) {
            if (cfg.factory_autotok) |v| allocator.free(v);
            cfg.factory_autotok = try allocator.dupe(u8, trimmed_value);
        }
    }
    if (cfg.pantahub_host == null) cfg.pantahub_host = try allocator.dupe(u8, "api.pantahub.com");

    // Check for ownership/cert.pem and key.pem
    const cert_path = try std.fs.path.join(allocator, &[_][]const u8{ store.base_path, "ownership", "cert.pem" });
    const key_path = try std.fs.path.join(allocator, &[_][]const u8{ store.base_path, "ownership", "key.pem" });

    const cert_exists = blk: {
        std.fs.cwd().access(cert_path, .{}) catch break :blk false;
        break :blk true;
    };
    const key_exists = blk: {
        std.fs.cwd().access(key_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (cert_exists and key_exists) {
        cfg.client_cert = cert_path; // ownership transferred to cfg
        cfg.client_key = key_path; // ownership transferred to cfg
    } else {
        allocator.free(cert_path);
        allocator.free(key_path);
    }

    const mock_content = try store.read_mocker_json(allocator, log);
    defer allocator.free(mock_content);

    if (mock_content.len > 0) {
        if (std.json.parseFromSlice(std.json.Value, allocator, mock_content, .{ .duplicate_field_behavior = .use_last })) |parsed| {
            cfg.mocker_json_parsed = parsed;
            if (parsed.value == .object) {
                if (parsed.value.object.get("device-meta")) |dm| {
                    if (dm == .object) {
                        cfg.mocker_meta = dm;
                    }
                }
            }
        } else |err| {
            log.log("Failed to parse mocker.json: {any}", .{err});
        }
    }

    std.debug.assert(cfg.pantahub_host != null);
    return cfg;
}

test "config load" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir({});
    defer tmp_dir.cleanup();

    const NoopLogger = struct {
        pub fn log(self: @This(), comptime fmt: []const u8, args: anytype) void {
            _ = self;
            _ = fmt;
            _ = args;
        }
    };
    var noop_log = NoopLogger{};

    const config_content =
        \\PH_CREDS_HOST=test.pantahub.com
        \\PH_CREDS_PORT=1234
        \\PH_CREDS_PRN=prn:test
        \\PH_CREDS_SECRET=secret
        \\PH_METADATA_DEVMETA_INTERVAL=10
        \\
    ;

    try tmp_dir.dir.makePath("config");
    try tmp_dir.dir.writeFile(.{ .sub_path = "config/pantahub.config", .data = config_content });
    try tmp_dir.dir.writeFile(.{ .sub_path = "config/mocker.json", .data = "{\"device-meta\": {\"custom.key\": \"custom.value\"}}" });

    // Mock LocalStore behavior by using the temp dir path
    // Since LocalStore uses absolute paths or relative to CWD, we might need to adjust.
    // For unit testing config.load, we can mock the store or just point it to tmp dir.
    // LocalStore.init takes base_path.

    // We need the absolute path of tmp_dir for LocalStore
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    // Actually, std.testing.tmpDir makes a directory relative to cwd usually?
    // We can just use the path provided by tmp_dir.
    // But LocalStore uses fs.cwd().openFile(base_path/...).

    // Let's rely on LocalStore accepting a relative path.
    // tmp_dir.parent_path is not public?
    // We can just create a LocalStore with "." and rely on the fact that we can't easily injection-mock it without dependency injection.
    // But wait, `load` takes `LocalStore` struct by value.
    // And `LocalStore.read_config` uses `base_path`.

    // Let's create a dummy LocalStore that points to the tmp dir.
    // We'll write to "config/pantahub.config" in the current directory for the test? No, that's bad.

    // Better: Refactor `load` to take a reader or a slice?
    // TigerStyle says: "Pass dependencies explicitly". `store` is a dependency.
    // But `store.read_config` is coupled to filesystem.

    // Let's modify `LocalStore` to allow mocking or just test `Config` by writing a file to a known temp location.

    // Actually, I'll just write the test to create a "storage_test" directory in cwd, run test, delete it.

    const test_base = "storage_test_config";
    std.fs.cwd().makePath(test_base ++ "/config") catch {};
    defer std.fs.cwd().deleteTree(test_base) catch {};

    try std.fs.cwd().writeFile(.{ .sub_path = test_base ++ "/config/pantahub.config", .data = config_content });

    const store = try local_store.LocalStore.init(allocator, test_base, null, false);
    // store.deinit is not needed if we free base_path manually or just leak in test (allocator detects leaks).
    // store passed by value to load.

    var cfg = try load(allocator, store, &noop_log);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("test.pantahub.com", cfg.pantahub_host.?);
    try std.testing.expectEqualStrings("1234", cfg.pantahub_port.?);
    try std.testing.expectEqualStrings("prn:test", cfg.creds_prn.?);
    try std.testing.expectEqualStrings("secret", cfg.creds_secret.?);
    try std.testing.expectEqual(10, cfg.devmeta_interval_s);

    // Cleanup store internals
    allocator.free(store.base_path);
}
