const std = @import("std");

pub const SWARM_JSON_NAME = "swarm.json";

pub const PantahubConfig = struct {
    host: ?[]const u8 = null,
    port: ?std.json.Value = null,
    autojoin_token: ?[]const u8 = null,
};

pub const GenerateConfig = struct {
    appliances: u32 = 0,
    devices: u32 = 0,
};

pub const SimulateConfig = struct {
    auto: bool = false,
    headless: bool = false,
};

/// Schema of swarm.json: a single file that fully describes a swarm
/// workspace (Pantahub endpoint, autojoin token, metadata templates,
/// generation counts, automation weights and simulation options).
pub const SwarmJsonSchema = struct {
    pantahub: PantahubConfig = .{},
    group_key: ?[]const u8 = null,
    random_keys: ?[]const []const u8 = null,
    base: ?std.json.Value = null,
    channels: ?std.json.Value = null,
    models: ?[]const []const u8 = null,
    generate: GenerateConfig = .{},
    automation: ?std.json.Value = null,
    simulate: SimulateConfig = .{},
};

pub const SwarmWorkspace = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    autojoin_token: []const u8,
    group_key: []const u8,
    base_json: []const u8,
    channels_json: ?[]const u8,
    models: std.ArrayList([]const u8),
    random_keys: std.ArrayList([]const u8),
    host: ?[]const u8,
    port: ?[]const u8,
    automation_json: ?[]const u8,
    generate: GenerateConfig,
    simulate: SimulateConfig,

    /// Load workspace configuration. Prefers a single swarm.json file;
    /// falls back to the legacy multi-file layout (autojointoken.txt,
    /// group_key.txt, base.json, channels.json, models.txt, to_random_keys.txt).
    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !SwarmWorkspace {
        return initWithConfig(allocator, dir, null);
    }

    /// Like init, but with an explicit config file: a path relative to the
    /// workspace dir (or absolute). Lets several configurations live in the
    /// same folder (e.g. swarm-stage.json, swarm-prod.json). When a config is
    /// named explicitly, a missing file is an error — no legacy fallback.
    pub fn initWithConfig(allocator: std.mem.Allocator, dir: []const u8, config_name: ?[]const u8) !SwarmWorkspace {
        std.debug.assert(dir.len > 0);
        const name = config_name orelse SWARM_JSON_NAME;
        if (readFile(allocator, dir, name)) |content| {
            defer allocator.free(content);
            return initFromSwarmJson(allocator, dir, name, content);
        } else |err| {
            if (err != error.FileNotFound) return err;
            if (config_name != null) {
                std.debug.print("Error: config file '{s}' not found in '{s}'.\n", .{ name, dir });
                return err;
            }
            return initFromLegacyFiles(allocator, dir);
        }
    }

    fn emptyWorkspace(allocator: std.mem.Allocator, dir: []const u8) SwarmWorkspace {
        return .{
            .allocator = allocator,
            .dir = dir,
            .autojoin_token = "",
            .group_key = "",
            .base_json = "",
            .channels_json = null,
            .models = .{},
            .random_keys = .{},
            .host = null,
            .port = null,
            .automation_json = null,
            .generate = .{},
            .simulate = .{},
        };
    }

    fn initFromSwarmJson(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, content: []const u8) !SwarmWorkspace {
        std.debug.assert(content.len > 0);
        var parsed = std.json.parseFromSlice(SwarmJsonSchema, allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.debug.print("Error: invalid {s} in '{s}': {}\n", .{ name, dir, err });
            return err;
        };
        defer parsed.deinit();
        const cfg = parsed.value;

        var ws = emptyWorkspace(allocator, dir);
        errdefer ws.deinit();

        const token_trimmed = std.mem.trim(u8, cfg.pantahub.autojoin_token orelse "", " \t\r\n");
        if (token_trimmed.len == 0) {
            std.debug.print("Error: {s} in '{s}' is missing pantahub.autojoin_token.\n", .{ name, dir });
            return error.MissingAutojoinToken;
        }
        ws.autojoin_token = try allocator.dupe(u8, token_trimmed);
        ws.group_key = try allocator.dupe(u8, cfg.group_key orelse "");
        ws.base_json = if (cfg.base) |base|
            try serializeJsonValue(allocator, base)
        else
            try allocator.dupe(u8, "{}");
        if (cfg.channels) |channels| ws.channels_json = try serializeJsonValue(allocator, channels);
        if (cfg.pantahub.host) |host| ws.host = try allocator.dupe(u8, host);
        if (cfg.pantahub.port) |port| ws.port = try portToString(allocator, port);
        if (cfg.automation) |automation| ws.automation_json = try serializeJsonValue(allocator, automation);
        try dupeStrings(allocator, &ws.models, cfg.models orelse &.{});
        try dupeStrings(allocator, &ws.random_keys, cfg.random_keys orelse &.{});
        ws.generate = cfg.generate;
        ws.simulate = cfg.simulate;
        return ws;
    }

    /// Public so `swarm convert` can load the legacy layout explicitly,
    /// even when a swarm.json already exists (--force re-conversion).
    pub fn initFromLegacyFiles(allocator: std.mem.Allocator, dir: []const u8) !SwarmWorkspace {
        var ws = emptyWorkspace(allocator, dir);
        errdefer ws.deinit();

        ws.autojoin_token = readAndTrimFile(allocator, dir, "autojointoken.txt") catch |err| {
            std.debug.print("Error: Could not read {s} or autojointoken.txt in '{s}'. Run 'swarm init' first.\n", .{ SWARM_JSON_NAME, dir });
            return err;
        };
        ws.group_key = readAndTrimFile(allocator, dir, "group_key.txt") catch |err| {
            std.debug.print("Error: Could not read group_key.txt in '{s}'. Run 'swarm init' first.\n", .{dir});
            return err;
        };
        ws.base_json = readFile(allocator, dir, "base.json") catch |err| {
            std.debug.print("Error: Could not read base.json in '{s}'. Run 'swarm init' first.\n", .{dir});
            return err;
        };
        ws.channels_json = readFile(allocator, dir, "channels.json") catch null;
        if (readFile(allocator, dir, "models.txt")) |content| {
            defer allocator.free(content);
            try appendTrimmedLines(allocator, &ws.models, content);
        } else |_| {}
        if (readFile(allocator, dir, "to_random_keys.txt")) |content| {
            defer allocator.free(content);
            try appendTrimmedLines(allocator, &ws.random_keys, content);
        } else |_| {}
        return ws;
    }

    pub fn deinit(self: *SwarmWorkspace) void {
        self.allocator.free(self.autojoin_token);
        self.allocator.free(self.group_key);
        self.allocator.free(self.base_json);
        if (self.channels_json) |c| self.allocator.free(c);
        if (self.host) |h| self.allocator.free(h);
        if (self.port) |p| self.allocator.free(p);
        if (self.automation_json) |a| self.allocator.free(a);
        for (self.models.items) |m| {
            self.allocator.free(m);
        }
        self.models.deinit(self.allocator);
        for (self.random_keys.items) |key| {
            self.allocator.free(key);
        }
        self.random_keys.deinit(self.allocator);
    }

    pub fn readChannelsJson(self: SwarmWorkspace) !std.json.Parsed(std.json.Value) {
        const content = self.channels_json orelse {
            std.debug.print("Error: no channels configured (add 'channels' to {s} or create channels.json).\n", .{SWARM_JSON_NAME});
            return error.FileNotFound;
        };
        return std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
    }

    pub fn readModels(self: SwarmWorkspace) !std.ArrayList([]const u8) {
        var models = std.ArrayList([]const u8){};
        errdefer {
            for (models.items) |m| self.allocator.free(m);
            models.deinit(self.allocator);
        }
        for (self.models.items) |m| {
            const duped = try self.allocator.dupe(u8, m);
            errdefer self.allocator.free(duped);
            try models.append(self.allocator, duped);
        }
        return models;
    }
};

fn appendTrimmedLines(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), content: []const u8) !void {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const duped = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(duped);
        try list.append(allocator, duped);
    }
}

fn dupeStrings(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), items: []const []const u8) !void {
    for (items) |item| {
        const trimmed = std.mem.trim(u8, item, " \t\r\n");
        if (trimmed.len == 0) continue;
        const duped = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(duped);
        try list.append(allocator, duped);
    }
}

pub fn serializeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}

pub fn portToString(allocator: std.mem.Allocator, port: std.json.Value) ![]u8 {
    return switch (port) {
        .string => |s| try allocator.dupe(u8, s),
        .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        else => blk: {
            std.debug.print("Error: {s} pantahub.port must be a string or integer.\n", .{SWARM_JSON_NAME});
            break :blk error.InvalidPort;
        },
    };
}

pub fn generateHexId() [8]u8 {
    var bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

pub fn generateRandomNumeric() [12]u8 {
    var result: [12]u8 = undefined;
    var rand_bytes: [12]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    for (&result, rand_bytes) |*r, b| {
        r.* = '0' + (b % 10);
    }
    return result;
}

/// Build a merged JSON object string for device-meta by combining:
/// base JSON + channel overlay + random values + group key + extra key/value pairs.
/// All merging is done by parsing into std.json.Value and using its ObjectMap.
pub fn buildMergedDeviceMeta(
    allocator: std.mem.Allocator,
    base_json_str: []const u8,
    channel_overlay_value: ?std.json.Value,
    random_keys: []const []const u8,
    group_key: []const u8,
    group_value: []const u8,
    extra_pairs: []const [2][]const u8,
) ![]u8 {
    // Parse base JSON into a Value (treat parse failure as empty object)
    var parsed_base_opt: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, allocator, base_json_str, .{}) catch null;
    defer if (parsed_base_opt) |*p| p.deinit();

    // We need to build a new JSON string by collecting all key-value pairs
    // Use an ArrayList to accumulate JSON entries
    var entries = std.ArrayList(JsonEntry){};
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        entries.deinit(allocator);
    }

    // 1. Add base entries (if valid)
    if (parsed_base_opt) |parsed_base| {
        if (parsed_base.value == .object) {
            var base_it = parsed_base.value.object.iterator();
            while (base_it.next()) |entry| {
                try addEntry(allocator, &entries, entry.key_ptr.*, jsonValueToString(allocator, entry.value_ptr.*) catch continue);
            }
        }
    }

    // 2. Merge channel overlay
    if (channel_overlay_value) |overlay| {
        if (overlay == .object) {
            var overlay_it = overlay.object.iterator();
            while (overlay_it.next()) |entry| {
                try addEntry(allocator, &entries, entry.key_ptr.*, jsonValueToString(allocator, entry.value_ptr.*) catch continue);
            }
        }
    }

    // 3. Add random values
    for (random_keys) |rkey| {
        const rand_val = generateRandomNumeric();
        try addEntry(allocator, &entries, rkey, try allocator.dupe(u8, &rand_val));
    }

    // 4. Add group key
    if (group_key.len > 0) {
        try addEntry(allocator, &entries, group_key, try allocator.dupe(u8, group_value));
    }

    // 5. Add extra pairs
    for (extra_pairs) |pair| {
        try addEntry(allocator, &entries, pair[0], try allocator.dupe(u8, pair[1]));
    }

    // Serialize to JSON string
    return try serializeEntries(allocator, entries.items);
}

const JsonEntry = struct {
    key: []const u8,
    value: []const u8,
};

fn addEntry(allocator: std.mem.Allocator, entries: *std.ArrayList(JsonEntry), key: []const u8, value: []const u8) !void {
    // Remove existing entry with same key (last write wins)
    var i: usize = 0;
    while (i < entries.items.len) {
        if (std.mem.eql(u8, entries.items[i].key, key)) {
            allocator.free(entries.items[i].key);
            allocator.free(entries.items[i].value);
            _ = entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
    try entries.append(allocator, .{
        .key = try allocator.dupe(u8, key),
        .value = value,
    });
}

fn jsonValueToString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .null => try allocator.dupe(u8, "null"),
        else => error.UnsupportedJsonType,
    };
}

fn serializeEntries(allocator: std.mem.Allocator, entries: []const JsonEntry) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    try writer.writeByte('{');
    for (entries, 0..) |entry, i| {
        if (i > 0) try writer.writeByte(',');
        // Write key as JSON string
        try writer.writeByte('"');
        try writeJsonEscaped(writer, entry.key);
        try writer.writeAll("\":\"");
        try writeJsonEscaped(writer, entry.value);
        try writer.writeByte('"');
    }
    try writer.writeByte('}');

    return try allocator.dupe(u8, out.items);
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

/// Write a mocker.json file with merged device-meta and an optional
/// automation block copied verbatim from the workspace configuration.
pub fn writeMockerJson(
    allocator: std.mem.Allocator,
    mocker_json_path: []const u8,
    device_meta_json: []const u8,
    automation_json: ?[]const u8,
) !void {
    // Read existing mocker.json
    const existing = blk: {
        const file = std.fs.cwd().openFile(mocker_json_path, .{}) catch |err| {
            if (err == error.FileNotFound) break :blk try allocator.dupe(u8, "{}");
            return err;
        };
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 1024 * 50);
    };
    defer allocator.free(existing);

    // Parse existing mocker.json (treat invalid content as empty object)
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, existing, .{}) catch
        try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();

    // Parse the new device-meta
    var meta_parsed = std.json.parseFromSlice(std.json.Value, allocator, device_meta_json, .{}) catch {
        return;
    };
    defer meta_parsed.deinit();

    if (parsed.value != .object) return;

    // Collect all entries for device-meta (existing + new)
    var dm_entries = std.ArrayList(JsonEntry){};
    defer {
        for (dm_entries.items) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        dm_entries.deinit(allocator);
    }

    // Get existing device-meta entries
    if (parsed.value.object.get("device-meta")) |dm| {
        if (dm == .object) {
            var it = dm.object.iterator();
            while (it.next()) |entry| {
                const val_str = jsonValueToString(allocator, entry.value_ptr.*) catch continue;
                try addEntry(allocator, &dm_entries, entry.key_ptr.*, val_str);
            }
        }
    }

    // Overlay new entries
    if (meta_parsed.value == .object) {
        var it = meta_parsed.value.object.iterator();
        while (it.next()) |entry| {
            const val_str = jsonValueToString(allocator, entry.value_ptr.*) catch continue;
            try addEntry(allocator, &dm_entries, entry.key_ptr.*, val_str);
        }
    }

    // Build output JSON
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    // Write other top-level keys, preserving their JSON structure
    try writer.writeByte('{');
    var first = true;

    var root_it = parsed.value.object.iterator();
    while (root_it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "device-meta")) continue;
        if (automation_json != null and std.mem.eql(u8, entry.key_ptr.*, "automation")) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeByte('"');
        try writeJsonEscaped(writer, entry.key_ptr.*);
        try writer.writeAll("\":");
        try writer.print("{f}", .{std.json.fmt(entry.value_ptr.*, .{})});
    }

    // Write automation block verbatim (workspace config wins)
    if (automation_json) |auto_json| {
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("\"automation\":");
        try writer.writeAll(auto_json);
    }

    // Write device-meta
    if (!first) try writer.writeByte(',');
    try writer.writeAll("\"device-meta\":");
    const dm_json = try serializeEntries(allocator, dm_entries.items);
    defer allocator.free(dm_json);
    try writer.writeAll(dm_json);

    try writer.writeByte('}');

    const file = try std.fs.cwd().createFile(mocker_json_path, .{});
    defer file.close();
    try file.writeAll(out.items);
}

fn readFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    const path = if (std.fs.path.isAbsolute(name))
        name
    else
        try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 100);
}

fn readAndTrimFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const content = try readFile(allocator, dir, name);
    defer allocator.free(content);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

test "swarm.json workspace parsing" {
    const allocator = std.testing.allocator;
    const test_dir = "swarm_ws_test_json";
    std.fs.cwd().makePath(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const swarm_json =
        \\{
        \\  "pantahub": { "host": "api.example.com", "port": 12365, "autojoin_token": "TOK123" },
        \\  "group_key": "grp.key",
        \\  "random_keys": ["rand.one", "rand.two"],
        \\  "base": { "pantavisor.arch": "aarch64/64/EL" },
        \\  "channels": { "CH1": { "policy": "green" } },
        \\  "models": ["Model A", "Model B"],
        \\  "generate": { "appliances": 2, "devices": 3 },
        \\  "automation": { "enabled": true, "update": { "done": 100 } },
        \\  "simulate": { "auto": true, "headless": true }
        \\}
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/swarm.json", .data = swarm_json });

    var ws = try SwarmWorkspace.init(allocator, test_dir);
    defer ws.deinit();

    try std.testing.expectEqualStrings("TOK123", ws.autojoin_token);
    try std.testing.expectEqualStrings("grp.key", ws.group_key);
    try std.testing.expectEqualStrings("api.example.com", ws.host.?);
    try std.testing.expectEqualStrings("12365", ws.port.?);
    try std.testing.expectEqual(@as(u32, 2), ws.generate.appliances);
    try std.testing.expectEqual(@as(u32, 3), ws.generate.devices);
    try std.testing.expect(ws.simulate.auto);
    try std.testing.expect(ws.simulate.headless);
    try std.testing.expectEqual(@as(usize, 2), ws.models.items.len);
    try std.testing.expectEqualStrings("Model A", ws.models.items[0]);
    try std.testing.expectEqual(@as(usize, 2), ws.random_keys.items.len);
    try std.testing.expect(ws.automation_json != null);
    try std.testing.expect(std.mem.indexOf(u8, ws.automation_json.?, "enabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, ws.base_json, "pantavisor.arch") != null);

    var channels = try ws.readChannelsJson();
    defer channels.deinit();
    try std.testing.expect(channels.value.object.get("CH1") != null);
}

test "named config file loads instead of swarm.json" {
    const allocator = std.testing.allocator;
    const test_dir = "swarm_ws_test_named";
    std.fs.cwd().makePath(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Default swarm.json and an alternate config side by side
    try std.fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/swarm.json", .data = "{\"pantahub\":{\"autojoin_token\":\"DEFAULT\"}}" });
    try std.fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/swarm-stage.json", .data = "{\"pantahub\":{\"host\":\"api.stage.example.com\",\"autojoin_token\":\"STAGE\"}}" });

    var ws = try SwarmWorkspace.initWithConfig(allocator, test_dir, "swarm-stage.json");
    defer ws.deinit();
    try std.testing.expectEqualStrings("STAGE", ws.autojoin_token);
    try std.testing.expectEqualStrings("api.stage.example.com", ws.host.?);

    var ws_default = try SwarmWorkspace.initWithConfig(allocator, test_dir, null);
    defer ws_default.deinit();
    try std.testing.expectEqualStrings("DEFAULT", ws_default.autojoin_token);

    // Explicitly named but missing config is an error, no legacy fallback
    try std.testing.expectError(error.FileNotFound, SwarmWorkspace.initWithConfig(allocator, test_dir, "nope.json"));
}

test "swarm.json missing token is rejected" {
    const allocator = std.testing.allocator;
    const test_dir = "swarm_ws_test_notoken";
    std.fs.cwd().makePath(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    try std.fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/swarm.json", .data = "{}" });
    try std.testing.expectError(error.MissingAutojoinToken, SwarmWorkspace.init(allocator, test_dir));
}

test "legacy workspace files still load" {
    const allocator = std.testing.allocator;
    const test_dir = "swarm_ws_test_legacy";
    std.fs.cwd().makePath(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    try std.fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/autojointoken.txt", .data = "LEGACYTOK\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/group_key.txt", .data = "grp.key\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/base.json", .data = "{\"a\":\"b\"}" });
    try std.fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/models.txt", .data = "Model X\n\nModel Y\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/to_random_keys.txt", .data = "rand.key\n" });

    var ws = try SwarmWorkspace.init(allocator, test_dir);
    defer ws.deinit();

    try std.testing.expectEqualStrings("LEGACYTOK", ws.autojoin_token);
    try std.testing.expectEqualStrings("grp.key", ws.group_key);
    try std.testing.expect(ws.host == null);
    try std.testing.expectEqual(@as(usize, 2), ws.models.items.len);
    try std.testing.expectEqual(@as(usize, 1), ws.random_keys.items.len);
    try std.testing.expect(ws.channels_json == null);
    try std.testing.expectError(error.FileNotFound, ws.readChannelsJson());
}

test "writeMockerJson with automation block" {
    const allocator = std.testing.allocator;
    const test_dir = "swarm_ws_test_mocker";
    std.fs.cwd().makePath(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const path = test_dir ++ "/mocker.json";
    const automation = "{\"enabled\":true,\"update\":{\"done\":100}}";
    try writeMockerJson(allocator, path, "{\"k\":\"v\"}", automation);

    const written = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 50);
    defer allocator.free(written);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, written, .{});
    defer parsed.deinit();

    const auto_val = parsed.value.object.get("automation").?;
    try std.testing.expect(auto_val.object.get("enabled").?.bool);
    const dm = parsed.value.object.get("device-meta").?;
    try std.testing.expectEqualStrings("v", dm.object.get("k").?.string);
}
