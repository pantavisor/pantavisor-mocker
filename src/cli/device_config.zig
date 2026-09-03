const std = @import("std");
const local_store = @import("../core/local_store.zig");
const swarm_workspace = @import("swarm_workspace.zig");

/// Schema of a single-device config file (the individual-device counterpart
/// of swarm.json): everything one mocker needs in one JSON — Pantahub
/// endpoint and autojoin token, device metadata, automation weights and
/// metadata sync intervals.
///
/// {
///   "pantahub": { "host": "api.pantahub.com", "port": "443", "autojoin_token": "..." },
///   "device-meta": { "pantavisor.arch": "aarch64/64/EL" },
///   "automation": { "enabled": true, "update": { "done": 100 } },
///   "intervals": { "devmeta": 10, "usrmeta": 10 }
/// }
pub const DeviceJsonSchema = struct {
    pantahub: swarm_workspace.PantahubConfig = .{},
    @"device-meta": ?std.json.Value = null,
    automation: ?std.json.Value = null,
    intervals: DeviceIntervals = .{},
    gc: DeviceGc = .{},
};

pub const DeviceIntervals = struct {
    devmeta: ?u32 = null,
    usrmeta: ?u32 = null,
};

pub const DeviceGc = struct {
    interval: ?u32 = null,
    logs_max_age: ?u32 = null,
};

pub const Overrides = struct {
    token: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: ?[]const u8 = null,
};

/// Apply a device config file to a storage directory: scaffolds the storage,
/// writes the endpoint/token/intervals into pantahub.config and merges
/// device-meta plus the automation block into mocker.json. CLI overrides win
/// over file values. Registration credentials (PH_CREDS_PRN/SECRET) are never
/// touched, so re-applying on every start is safe.
pub fn apply(
    allocator: std.mem.Allocator,
    storage_path: []const u8,
    config_path: []const u8,
    overrides: Overrides,
) !void {
    std.debug.assert(storage_path.len > 0);
    std.debug.assert(config_path.len > 0);

    const content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 100) catch |err| {
        std.debug.print("Error: could not read device config '{s}': {}\n", .{ config_path, err });
        return err;
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(DeviceJsonSchema, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Error: invalid device config '{s}': {}\n", .{ config_path, err });
        return err;
    };
    defer parsed.deinit();
    const cfg = parsed.value;

    const token = overrides.token orelse cfg.pantahub.autojoin_token;
    var store = try local_store.LocalStore.init(allocator, storage_path, token, true);
    defer store.deinit();

    try applyPantahubConfig(allocator, &store, cfg, overrides, token);
    try applyMockerJson(allocator, storage_path, cfg);
}

fn applyPantahubConfig(
    allocator: std.mem.Allocator,
    store: *local_store.LocalStore,
    cfg: DeviceJsonSchema,
    overrides: Overrides,
    token: ?[]const u8,
) !void {
    if (overrides.host orelse cfg.pantahub.host) |host| {
        try store.save_config_value("PH_CREDS_HOST", host);
    }
    if (overrides.port) |port| {
        try store.save_config_value("PH_CREDS_PORT", port);
    } else if (cfg.pantahub.port) |port_value| {
        const port = try swarm_workspace.portToString(allocator, port_value);
        defer allocator.free(port);
        try store.save_config_value("PH_CREDS_PORT", port);
    }
    if (token) |t| {
        if (t.len > 0) try store.save_config_value("PH_FACTORY_AUTOTOK", t);
    }
    var buf: [16]u8 = undefined;
    if (cfg.intervals.devmeta) |secs| {
        try store.save_config_value("PH_METADATA_DEVMETA_INTERVAL", try std.fmt.bufPrint(&buf, "{d}", .{secs}));
    }
    if (cfg.intervals.usrmeta) |secs| {
        try store.save_config_value("PH_METADATA_USRMETA_INTERVAL", try std.fmt.bufPrint(&buf, "{d}", .{secs}));
    }
    if (cfg.gc.interval) |secs| {
        try store.save_config_value("PH_GC_INTERVAL", try std.fmt.bufPrint(&buf, "{d}", .{secs}));
    }
    if (cfg.gc.logs_max_age) |secs| {
        try store.save_config_value("PH_GC_LOGS_MAX_AGE", try std.fmt.bufPrint(&buf, "{d}", .{secs}));
    }
}

fn applyMockerJson(allocator: std.mem.Allocator, storage_path: []const u8, cfg: DeviceJsonSchema) !void {
    if (cfg.@"device-meta" == null and cfg.automation == null) return;

    const mocker_path = try std.fs.path.join(allocator, &[_][]const u8{ storage_path, "config", "mocker.json" });
    defer allocator.free(mocker_path);

    const device_meta_json = if (cfg.@"device-meta") |dm|
        try swarm_workspace.serializeJsonValue(allocator, dm)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(device_meta_json);

    const automation_json: ?[]u8 = if (cfg.automation) |a|
        try swarm_workspace.serializeJsonValue(allocator, a)
    else
        null;
    defer if (automation_json) |a| allocator.free(a);

    try swarm_workspace.writeMockerJson(allocator, mocker_path, device_meta_json, automation_json);
}

test "apply device config scaffolds storage" {
    const allocator = std.testing.allocator;
    const test_dir = "device_cfg_test";
    std.fs.cwd().makePath(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const device_json =
        \\{
        \\  "pantahub": { "host": "api.example.com", "port": 12365, "autojoin_token": "DEVTOK" },
        \\  "device-meta": { "pantavisor.arch": "aarch64/64/EL", "custom.key": "v1" },
        \\  "automation": { "enabled": true, "update": { "done": 100 } },
        \\  "intervals": { "devmeta": 30, "usrmeta": 60 }
        \\}
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/device.json", .data = device_json });

    try apply(allocator, test_dir ++ "/storage", test_dir ++ "/device.json", .{});

    const config = try std.fs.cwd().readFileAlloc(allocator, test_dir ++ "/storage/config/pantahub.config", 1024 * 10);
    defer allocator.free(config);
    try std.testing.expect(std.mem.indexOf(u8, config, "PH_CREDS_HOST=api.example.com\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "PH_CREDS_PORT=12365\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "PH_FACTORY_AUTOTOK=DEVTOK\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "PH_METADATA_DEVMETA_INTERVAL=30\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "PH_METADATA_USRMETA_INTERVAL=60\n") != null);

    const mocker = try std.fs.cwd().readFileAlloc(allocator, test_dir ++ "/storage/config/mocker.json", 1024 * 50);
    defer allocator.free(mocker);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, mocker, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("automation").?.object.get("enabled").?.bool);
    try std.testing.expectEqualStrings("v1", parsed.value.object.get("device-meta").?.object.get("custom.key").?.string);

    // CLI overrides win over file values, re-apply is safe
    try apply(allocator, test_dir ++ "/storage", test_dir ++ "/device.json", .{ .host = "other.example.com" });
    const config2 = try std.fs.cwd().readFileAlloc(allocator, test_dir ++ "/storage/config/pantahub.config", 1024 * 10);
    defer allocator.free(config2);
    try std.testing.expect(std.mem.indexOf(u8, config2, "PH_CREDS_HOST=other.example.com\n") != null);
}
