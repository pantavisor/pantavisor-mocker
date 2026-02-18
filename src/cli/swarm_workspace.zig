const std = @import("std");

pub const SwarmWorkspace = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    autojoin_token: []const u8,
    group_key: []const u8,
    base_json: []const u8,
    random_keys: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !SwarmWorkspace {
        const autojoin_token = readAndTrimFile(allocator, dir, "autojointoken.txt") catch |err| {
            std.debug.print("Error: Could not read autojointoken.txt in '{s}'. Run 'swarm init' first.\n", .{dir});
            return err;
        };
        errdefer allocator.free(autojoin_token);

        const group_key = readAndTrimFile(allocator, dir, "group_key.txt") catch |err| {
            std.debug.print("Error: Could not read group_key.txt in '{s}'. Run 'swarm init' first.\n", .{dir});
            return err;
        };
        errdefer allocator.free(group_key);

        const base_json = readFile(allocator, dir, "base.json") catch |err| {
            std.debug.print("Error: Could not read base.json in '{s}'. Run 'swarm init' first.\n", .{dir});
            return err;
        };
        errdefer allocator.free(base_json);

        var random_keys = std.ArrayList([]const u8){};
        const random_keys_content = readFile(allocator, dir, "to_random_keys.txt") catch null;
        if (random_keys_content) |content| {
            defer allocator.free(content);
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                const duped = try allocator.dupe(u8, trimmed);
                try random_keys.append(allocator, duped);
            }
        }

        return SwarmWorkspace{
            .allocator = allocator,
            .dir = dir,
            .autojoin_token = autojoin_token,
            .group_key = group_key,
            .base_json = base_json,
            .random_keys = random_keys,
        };
    }

    pub fn deinit(self: *SwarmWorkspace) void {
        self.allocator.free(self.autojoin_token);
        self.allocator.free(self.group_key);
        self.allocator.free(self.base_json);
        for (self.random_keys.items) |key| {
            self.allocator.free(key);
        }
        self.random_keys.deinit(self.allocator);
    }

    pub fn readChannelsJson(self: SwarmWorkspace) !std.json.Parsed(std.json.Value) {
        const content = try readFile(self.allocator, self.dir, "channels.json");
        defer self.allocator.free(content);
        return std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
    }

    pub fn readModels(self: SwarmWorkspace) !std.ArrayList([]const u8) {
        const content = try readFile(self.allocator, self.dir, "models.txt");
        defer self.allocator.free(content);

        var models = std.ArrayList([]const u8){};
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const duped = try self.allocator.dupe(u8, trimmed);
            try models.append(self.allocator, duped);
        }
        return models;
    }
};

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

/// Write a mocker.json file with merged device-meta.
pub fn writeMockerJson(allocator: std.mem.Allocator, mocker_json_path: []const u8, device_meta_json: []const u8) !void {
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

    // Parse existing mocker.json
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, existing, .{}) catch {
        // If invalid, write fresh
        const fresh = try std.fmt.allocPrint(allocator, "{{\"device-meta\":{s}}}", .{device_meta_json});
        defer allocator.free(fresh);
        const file = try std.fs.cwd().createFile(mocker_json_path, .{});
        defer file.close();
        try file.writeAll(fresh);
        return;
    };
    defer parsed.deinit();

    // Parse the new device-meta
    var meta_parsed = std.json.parseFromSlice(std.json.Value, allocator, device_meta_json, .{}) catch {
        return;
    };
    defer meta_parsed.deinit();

    // Build the output: merge device-meta into existing
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

    // Write other top-level keys
    try writer.writeByte('{');
    var first = true;

    var root_it = parsed.value.object.iterator();
    while (root_it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "device-meta")) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeByte('"');
        try writeJsonEscaped(writer, entry.key_ptr.*);
        try writer.writeAll("\":");

        // Serialize value using json fmt
        const val_str = jsonValueToString(allocator, entry.value_ptr.*) catch continue;
        defer allocator.free(val_str);
        try writer.writeByte('"');
        try writeJsonEscaped(writer, val_str);
        try writer.writeByte('"');
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
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
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
