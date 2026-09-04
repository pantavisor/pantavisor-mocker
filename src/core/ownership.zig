//! TLS ownership material: the client certificate and private key a device
//! presents to Pantahub's ownership validation endpoint. The mocker looks
//! for them at `<storage>/ownership/cert.pem` and `<storage>/ownership/key.pem`
//! (see config.zig); this module installs them there from user-supplied paths.
const std = @import("std");

pub const DIR_NAME = "ownership";
pub const CERT_NAME = "cert.pem";
pub const KEY_NAME = "key.pem";

/// `"ownership": { "cert": "...", "key": "..." }` block shared by swarm.json
/// and device.json. Relative paths are resolved against the config file's
/// directory.
pub const Config = struct {
    cert: ?[]const u8 = null,
    key: ?[]const u8 = null,

    /// Both or neither must be set. Returns true when a cert/key pair is configured.
    pub fn validate(self: Config, what: []const u8) !bool {
        if ((self.cert == null) != (self.key == null)) {
            std.debug.print("Error: {s}: ownership.cert and ownership.key must be given together.\n", .{what});
            return error.InvalidOwnershipConfig;
        }
        return self.cert != null;
    }
};

/// Resolve `path` against `base_dir` unless it is absolute. Caller owns the result.
pub fn resolve(allocator: std.mem.Allocator, base_dir: []const u8, path: []const u8) ![]u8 {
    std.debug.assert(path.len > 0);
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &[_][]const u8{ base_dir, path });
}

/// Directory containing a config file, for resolving relative ownership paths.
pub fn configDir(config_path: []const u8) []const u8 {
    return std.fs.path.dirname(config_path) orelse ".";
}

/// Copy the TLS client certificate and private key into `<storage>/ownership/`
/// as `cert.pem` and `key.pem`. The key is written with mode 0600.
pub fn install(allocator: std.mem.Allocator, storage: []const u8, cert_src: []const u8, key_src: []const u8) !void {
    std.debug.assert(storage.len > 0);
    std.debug.assert(cert_src.len > 0);
    std.debug.assert(key_src.len > 0);

    const dir_path = try std.fs.path.join(allocator, &[_][]const u8{ storage, DIR_NAME });
    defer allocator.free(dir_path);
    try std.fs.cwd().makePath(dir_path);

    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    std.fs.cwd().copyFile(cert_src, dir, CERT_NAME, .{}) catch |err| {
        std.debug.print("Error: cannot copy ownership cert '{s}': {s}\n", .{ cert_src, @errorName(err) });
        return err;
    };
    std.fs.cwd().copyFile(key_src, dir, KEY_NAME, .{ .override_mode = 0o600 }) catch |err| {
        std.debug.print("Error: cannot copy ownership key '{s}': {s}\n", .{ key_src, @errorName(err) });
        return err;
    };
}

/// Install the pair described by a (validated) Config, resolving relative
/// paths against `base_dir`. No-op when no pair is configured.
pub fn installFromConfig(allocator: std.mem.Allocator, storage: []const u8, base_dir: []const u8, cfg: Config, what: []const u8) !void {
    if (!try cfg.validate(what)) return;
    const cert = try resolve(allocator, base_dir, cfg.cert.?);
    defer allocator.free(cert);
    const key = try resolve(allocator, base_dir, cfg.key.?);
    defer allocator.free(key);
    try install(allocator, storage, cert, key);
}

test "install copies cert and key into storage/ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "c.pem", .data = "CERT" });
    try tmp.dir.writeFile(.{ .sub_path = "k.pem", .data = "KEY" });

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const storage = try std.fs.path.join(std.testing.allocator, &.{ base, "store" });
    defer std.testing.allocator.free(storage);

    // relative paths resolved against base via installFromConfig
    try installFromConfig(std.testing.allocator, storage, base, .{ .cert = "c.pem", .key = "k.pem" }, "test");

    const cert = try tmp.dir.readFileAlloc(std.testing.allocator, "store/ownership/cert.pem", 64);
    defer std.testing.allocator.free(cert);
    try std.testing.expectEqualStrings("CERT", cert);
    const key = try tmp.dir.readFileAlloc(std.testing.allocator, "store/ownership/key.pem", 64);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("KEY", key);
}

test "install fails on missing source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ base, "nope.pem" });
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.FileNotFound, install(std.testing.allocator, base, missing, missing));
}

test "config validation" {
    try std.testing.expect(!try (Config{}).validate("t"));
    try std.testing.expect(try (Config{ .cert = "a", .key = "b" }).validate("t"));
    try std.testing.expectError(error.InvalidOwnershipConfig, (Config{ .cert = "a" }).validate("t"));
    try std.testing.expectError(error.InvalidOwnershipConfig, (Config{ .key = "b" }).validate("t"));
}

test "resolve keeps absolute, joins relative" {
    const a = try resolve(std.testing.allocator, "/base", "/abs/c.pem");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("/abs/c.pem", a);
    const r = try resolve(std.testing.allocator, "/base", "certs/c.pem");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("/base/certs/c.pem", r);
    try std.testing.expectEqualStrings("/etc/x", configDir("/etc/x/swarm.json"));
    try std.testing.expectEqualStrings(".", configDir("swarm.json"));
}
