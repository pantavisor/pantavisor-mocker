const std = @import("std");
const local_store = @import("app").local_store;
const update_flow = @import("app").update_flow;
const client_mod = @import("app").client_mod;
const config_mod = @import("app").config;
const logger_mod = @import("app").logger;

// Integration test for basic update flow initialization
test "update flow initialization" {
    const allocator = std.testing.allocator;

    // Create a temporary directory for testing
    var temp_dir = try std.fs.cwd().makeOpenPath("test_storage", .{});
    defer temp_dir.close();

    // Initialize a local store
    var store = try local_store.LocalStore.init(allocator, "test_storage", null, false);
    defer store.deinit();

    // Verify revisions were initialized
    const revs = try store.get_revisions();
    defer allocator.free(revs.rev);
    defer allocator.free(revs.try_rev);

    try std.testing.expectEqualStrings("0", revs.rev);
    try std.testing.expectEqualStrings("0", revs.try_rev);

    // Clean up test directory
    try std.fs.cwd().deleteTree("test_storage");
}

// Integration test for revision directory initialization
test "revision directory initialization" {
    const allocator = std.testing.allocator;

    var temp_dir = try std.fs.cwd().makeOpenPath("test_storage_2", .{});
    defer temp_dir.close();

    var store = try local_store.LocalStore.init(allocator, "test_storage_2", null, false);
    defer store.deinit();

    try store.init_revision_dirs("1");

    // Verify directories were created
    const rev_path = try std.fmt.allocPrint(allocator, "test_storage_2/trails/1", .{});
    defer allocator.free(rev_path);

    var dir = std.fs.cwd().openDir(rev_path, .{}) catch |err| {
        try std.testing.expect(false); // Should not fail
        return err;
    };
    dir.close();

    // Clean up
    try std.fs.cwd().deleteTree("test_storage_2");
}

// Integration test for progress file operations
test "progress file operations" {
    const allocator = std.testing.allocator;

    var temp_dir = try std.fs.cwd().makeOpenPath("test_storage_3", .{});
    defer temp_dir.close();

    var store = try local_store.LocalStore.init(allocator, "test_storage_3", null, false);
    defer store.deinit();

    try store.init_revision_dirs("0");

    const test_json = "{\"status\":\"DONE\",\"progress\":100}";
    try store.save_revision_progress("0", test_json);

    // Read back the progress
    const prog_path = try std.fs.path.join(allocator, &[_][]const u8{ "test_storage_3", "trails", "0", ".pv", "progress" });
    defer allocator.free(prog_path);

    const file = try std.fs.cwd().openFile(prog_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    try std.testing.expect(content.len > 0);

    // Clean up
    try std.fs.cwd().deleteTree("test_storage_3");
}

// Integration test for validation module
test "input validation" {
    const validation = @import("app").validation;

    // Test URL validation
    try validation.validate_url("https://pantahub.example.com/api");
    try validation.validate_url("http://localhost:8080/path");

    // Test hostname validation
    try validation.validate_hostname("example.com");
    try validation.validate_hostname("sub.example.com");

    // Test port validation
    const port = try validation.validate_port("8080");
    try std.testing.expectEqual(port, 8080);

    // Test SHA256 validation
    try validation.validate_sha256("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

    // Test invalid inputs return errors
    try std.testing.expectError(validation.ValidationError.InvalidUrl, validation.validate_url("invalid://example.com"));
    try std.testing.expectError(validation.ValidationError.EmptyInput, validation.validate_hostname(""));
    try std.testing.expectError(validation.ValidationError.InvalidPort, validation.validate_port("99999"));
}

// Integration test for configuration loading
test "configuration initialization" {
    const allocator = std.testing.allocator;

    var temp_dir = try std.fs.cwd().makeOpenPath("test_storage_config", .{});
    defer temp_dir.close();

    var store = try local_store.LocalStore.init(allocator, "test_storage_config", null, false);
    defer store.deinit();

    // Create a minimal logger for testing
    const log_path = try store.get_log_path("0");
    defer allocator.free(log_path);

    try store.init_log_dir("0");

    var log = try logger_mod.Logger.init(log_path, false);
    defer log.deinit();

    // Load configuration
    var cfg = try config_mod.load(allocator, store, &log);
    defer cfg.deinit();

    // Verify configuration was loaded
    try std.testing.expect(cfg.pantahub_host != null);

    // Clean up
    try std.fs.cwd().deleteTree("test_storage_config");
}
