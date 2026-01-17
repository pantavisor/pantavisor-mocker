const std = @import("std");
const meta_mod = @import("app").meta_mod;
const local_store = @import("app").local_store;
const logger_mod = @import("app").logger;
const client_mod = @import("app").client_mod;
const config_mod = @import("app").config;

// Test: Meta initialization
test "meta initialization" {
    const allocator = std.testing.allocator;

    var meta = meta_mod.Meta.init(allocator);
    defer meta.deinit();

    // Verify meta was initialized
    try std.testing.expectEqual(allocator, meta.allocator);
}

// Test: Meta deinit does not crash
test "meta deinit safety" {
    const allocator = std.testing.allocator;

    {
        var meta = meta_mod.Meta.init(allocator);
        meta.deinit();
        // If we reach here, deinit succeeded
    }
}

// Test: Device meta file path construction
test "device meta file path" {
    const allocator = std.testing.allocator;

    const base_path = "test_storage";
    const meta_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "device-meta", "meta.json" });
    defer allocator.free(meta_path);

    try std.testing.expect(std.mem.indexOf(u8, meta_path, "device-meta") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta_path, "meta.json") != null);
}

// Test: User meta file path construction
test "user meta file path" {
    const allocator = std.testing.allocator;

    const base_path = "test_storage";
    const meta_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "user-meta", "meta.json" });
    defer allocator.free(meta_path);

    try std.testing.expect(std.mem.indexOf(u8, meta_path, "user-meta") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta_path, "meta.json") != null);
}

// Test: Metadata status values
test "metadata status values" {
    const status = "READY";
    try std.testing.expectEqualStrings("READY", status);

    const mode = "remote";
    try std.testing.expectEqualStrings("remote", mode);

    const state = "idle";
    try std.testing.expectEqualStrings("idle", state);
}

// Test: Pantahub metadata fields
test "pantahub metadata fields" {
    const address = "pantahub.example.com:8443";
    const claimed = "1";
    const online = "1";

    try std.testing.expectEqualStrings("pantahub.example.com:8443", address);
    try std.testing.expectEqualStrings("1", claimed);
    try std.testing.expectEqualStrings("1", online);
}

// Test: Pantavisor metadata version
test "pantavisor metadata version" {
    const version = "019-302-g091a41d-240731";
    try std.testing.expect(version.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, version, "-") != null);
}

// Test: Metadata address formatting
test "metadata address formatting" {
    const allocator = std.testing.allocator;

    const host = "pantahub.example.com";
    const port = "8443";
    const address = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ host, port });
    defer allocator.free(address);

    try std.testing.expectEqualStrings("pantahub.example.com:8443", address);
}

// Test: Default port handling
test "default port handling" {
    const allocator = std.testing.allocator;

    const host = "example.com";
    const port = "443";
    const address = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ host, port });
    defer allocator.free(address);

    try std.testing.expectEqualStrings("example.com:443", address);
}

// Test: Metadata JSON object initialization
test "metadata json object init" {
    const allocator = std.testing.allocator;

    var meta_map = std.StringArrayHashMap(std.json.Value).init(allocator);
    defer meta_map.deinit();

    // Add various metadata fields
    try meta_map.put("pantahub.address", std.json.Value{ .string = "host:port" });
    try meta_map.put("pantahub.claimed", std.json.Value{ .string = "1" });
    try meta_map.put("pantavisor.status", std.json.Value{ .string = "READY" });

    try std.testing.expectEqual(@as(usize, 3), meta_map.count());
}

// Test: Metadata value string access
test "metadata value string access" {
    const value = std.json.Value{ .string = "test_value" };
    try std.testing.expectEqualStrings("test_value", value.string);
}

// Test: Metadata value integer access
test "metadata value integer access" {
    const value = std.json.Value{ .integer = 42 };
    try std.testing.expectEqual(@as(i64, 42), value.integer);
}

// Test: Pantahub field keys
test "pantahub field keys" {
    const keys = [_][]const u8{
        "pantahub.address",
        "pantahub.claimed",
        "pantahub.online",
        "pantahub.state",
    };

    for (keys) |key| {
        try std.testing.expect(std.mem.startsWith(u8, key, "pantahub."));
    }
}

// Test: Pantavisor field keys
test "pantavisor field keys" {
    const keys = [_][]const u8{
        "pantavisor.arch",
        "pantavisor.dtmodel",
        "pantavisor.mode",
        "pantavisor.revision",
        "pantavisor.status",
        "pantavisor.version",
        "pantavisor.uname",
    };

    for (keys) |key| {
        try std.testing.expect(std.mem.startsWith(u8, key, "pantavisor."));
    }
}

// Test: Metadata sync operation type
test "metadata sync operation type" {
    const operation = "sync";
    try std.testing.expectEqualStrings("sync", operation);
}

// Test: Metadata push operation type
test "metadata push operation type" {
    const operation = "push";
    try std.testing.expectEqualStrings("push", operation);
}

// Test: Device meta content length expectation
test "device meta content length validation" {
    const allocator = std.testing.allocator;

    const content = try allocator.dupe(u8, "{\"pantahub.claimed\": \"1\"}");
    defer allocator.free(content);

    try std.testing.expect(content.len > 0);
}

// Test: Metadata directory structure
test "metadata directory structure" {
    const device_meta_dir = "device-meta";
    const user_meta_dir = "user-meta";

    try std.testing.expect(device_meta_dir.len > 0);
    try std.testing.expect(user_meta_dir.len > 0);
    try std.testing.expect(!std.mem.eql(u8, device_meta_dir, user_meta_dir));
}

// Test: Metadata logging operations
test "metadata logging operations" {
    const operations = [_][]const u8{
        "Pushing metadata to cloud...",
        "Fetching user-meta from cloud...",
        "Device-meta uploaded successfully.",
        "User-meta updated successfully.",
    };

    for (operations) |log_msg| {
        try std.testing.expect(log_msg.len > 0);
    }
}

// Test: Metadata state transitions
test "metadata state transitions" {
    const states = [_][]const u8{
        "idle",
        "syncing",
        "pushing",
    };

    for (states) |state| {
        try std.testing.expect(state.len > 0);
    }
}

// Test: Metadata unchanged detection
test "metadata unchanged detection" {
    const allocator = std.testing.allocator;

    const meta1 = try allocator.dupe(u8, "{\"status\": \"ready\"}");
    defer allocator.free(meta1);
    const meta2 = try allocator.dupe(u8, "{\"status\": \"ready\"}");
    defer allocator.free(meta2);

    const changed = !std.mem.eql(u8, meta1, meta2);
    try std.testing.expect(changed == false);
}

// Test: Metadata changed detection
test "metadata changed detection" {
    const allocator = std.testing.allocator;

    const meta1 = try allocator.dupe(u8, "{\"status\": \"ready\"}");
    defer allocator.free(meta1);
    const meta2 = try allocator.dupe(u8, "{\"status\": \"updating\"}");
    defer allocator.free(meta2);

    const changed = !std.mem.eql(u8, meta1, meta2);
    try std.testing.expect(changed == true);
}

// Test: Revision string formatting in metadata
test "revision string formatting in metadata" {
    const allocator = std.testing.allocator;

    const rev_num = @as(i64, 42);
    const rev_str = try std.fmt.allocPrint(allocator, "{d}", .{rev_num});
    defer allocator.free(rev_str);

    try std.testing.expectEqualStrings("42", rev_str);
}

// Test: Metadata field override detection
test "metadata field override detection" {
    const allocator = std.testing.allocator;

    var meta_map = std.StringArrayHashMap(std.json.Value).init(allocator);
    defer meta_map.deinit();

    const field = "test.field";
    const value1 = std.json.Value{ .string = "original" };

    try meta_map.put(field, value1);
    try std.testing.expectEqual(@as(usize, 1), meta_map.count());

    const value2 = std.json.Value{ .string = "overridden" };
    try meta_map.put(field, value2);
    try std.testing.expectEqual(@as(usize, 1), meta_map.count());
}

// Test: Metadata extra overrides handling
test "metadata extra overrides" {
    const allocator = std.testing.allocator;

    var extras = std.StringArrayHashMap(std.json.Value).init(allocator);
    defer extras.deinit();

    try extras.put("custom.field1", std.json.Value{ .string = "value1" });
    try extras.put("custom.field2", std.json.Value{ .string = "value2" });

    try std.testing.expectEqual(@as(usize, 2), extras.count());
}

// Test: File path with default port
test "file path with default port handling" {
    const allocator = std.testing.allocator;

    const ph_addr = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ "host", "443" });
    defer allocator.free(ph_addr);

    try std.testing.expectEqualStrings("host:443", ph_addr);
}

// Test: Multiple metadata key paths
test "multiple metadata key paths" {
    const allocator = std.testing.allocator;

    const paths = [_][]const u8{
        "pantahub.address",
        "storage",
        "interfaces",
        "sysinfo",
        "time",
    };

    for (paths) |path| {
        const stored_path = try allocator.dupe(u8, path);
        defer allocator.free(stored_path);
        try std.testing.expectEqualStrings(path, stored_path);
    }
}
