const std = @import("std");
const client_mod = @import("app").client_mod;
const logger_mod = @import("app").logger;
const validation = @import("app").validation;

// Test: Client initialization with valid hostname and port
test "client init with valid hostname and port" {
    const allocator = std.testing.allocator;

    // Create a temporary logger
    var temp_dir = try std.fs.cwd().makeOpenPath("test_client_logs", .{});
    defer temp_dir.close();

    var logger = try logger_mod.Logger.init("test_client_logs/test.log", false);
    defer logger.deinit();

    var client = try client_mod.Client.init(allocator, "pantahub.example.com", "8443", &logger);
    defer client.deinit();

    try std.testing.expectEqualStrings("pantahub.example.com", client.pantahub_host);
    try std.testing.expectEqualStrings("8443", client.pantahub_port);
    try std.testing.expect(client.token == null);

    // Clean up
    try std.fs.cwd().deleteTree("test_client_logs");
}

// Test: Client initialization with localhost
test "client init with localhost" {
    const allocator = std.testing.allocator;

    var temp_dir = try std.fs.cwd().makeOpenPath("test_client_logs_2", .{});
    defer temp_dir.close();

    var logger = try logger_mod.Logger.init("test_client_logs_2/test.log", false);
    defer logger.deinit();

    var client = try client_mod.Client.init(allocator, "localhost", "9999", &logger);
    defer client.deinit();

    try std.testing.expectEqualStrings("localhost", client.pantahub_host);
    try std.testing.expectEqualStrings("9999", client.pantahub_port);

    // Clean up
    try std.fs.cwd().deleteTree("test_client_logs_2");
}

// Test: Client initialization with invalid port (should fail)
test "client init with invalid port" {
    const allocator = std.testing.allocator;

    var temp_dir = try std.fs.cwd().makeOpenPath("test_client_logs_3", .{});
    defer temp_dir.close();

    var logger = try logger_mod.Logger.init("test_client_logs_3/test.log", false);
    defer logger.deinit();

    // Invalid port should fail
    try std.testing.expectError(
        validation.ValidationError.InvalidPort,
        client_mod.Client.init(allocator, "example.com", "99999", &logger),
    );

    // Clean up
    try std.fs.cwd().deleteTree("test_client_logs_3");
}

// Test: Client initialization with invalid hostname (should fail)
test "client init with invalid hostname" {
    const allocator = std.testing.allocator;

    var temp_dir = try std.fs.cwd().makeOpenPath("test_client_logs_4", .{});
    defer temp_dir.close();

    var logger = try logger_mod.Logger.init("test_client_logs_4/test.log", false);
    defer logger.deinit();

    // Invalid hostname should fail
    try std.testing.expectError(
        validation.ValidationError.InvalidHostname,
        client_mod.Client.init(allocator, "invalid_host!", "8080", &logger),
    );

    // Clean up
    try std.fs.cwd().deleteTree("test_client_logs_4");
}

// Test: UpdateStatus enum parsing
test "update status parsing" {
    // Test standard status parsing
    try std.testing.expectEqual(client_mod.UpdateStatus.parse("NEW"), client_mod.UpdateStatus.NEW);
    try std.testing.expectEqual(client_mod.UpdateStatus.parse("DOWNLOADING"), client_mod.UpdateStatus.DOWNLOADING);
    try std.testing.expectEqual(client_mod.UpdateStatus.parse("DONE"), client_mod.UpdateStatus.DONE);
    try std.testing.expectEqual(client_mod.UpdateStatus.parse("ERROR"), client_mod.UpdateStatus.ERROR);

    // Test case insensitivity
    try std.testing.expectEqual(client_mod.UpdateStatus.parse("done"), client_mod.UpdateStatus.DONE);
    try std.testing.expectEqual(client_mod.UpdateStatus.parse("DoNe"), client_mod.UpdateStatus.DONE);

    // Test CANCELED vs CANCELLED
    try std.testing.expectEqual(client_mod.UpdateStatus.parse("CANCELED"), client_mod.UpdateStatus.CANCELLED);
    try std.testing.expectEqual(client_mod.UpdateStatus.parse("CANCELLED"), client_mod.UpdateStatus.CANCELLED);
    try std.testing.expectEqual(client_mod.UpdateStatus.parse("canceled"), client_mod.UpdateStatus.CANCELLED);

    // Test invalid status
    try std.testing.expectEqual(client_mod.UpdateStatus.parse("INVALID"), null);
}

// Test: UpdateStatus toString
test "update status to string" {
    try std.testing.expectEqualStrings("NEW", client_mod.UpdateStatus.NEW.toString());
    try std.testing.expectEqualStrings("DOWNLOADING", client_mod.UpdateStatus.DOWNLOADING.toString());
    try std.testing.expectEqualStrings("DONE", client_mod.UpdateStatus.DONE.toString());
    try std.testing.expectEqualStrings("ERROR", client_mod.UpdateStatus.ERROR.toString());
    try std.testing.expectEqualStrings("CANCELLED", client_mod.UpdateStatus.CANCELLED.toString());
}

// Test: UpdateStatus isTerminal
test "update status is terminal" {
    try std.testing.expect(client_mod.UpdateStatus.DONE.isTerminal() == true);
    try std.testing.expect(client_mod.UpdateStatus.UPDATED.isTerminal() == true);
    try std.testing.expect(client_mod.UpdateStatus.WONTGO.isTerminal() == true);
    try std.testing.expect(client_mod.UpdateStatus.ERROR.isTerminal() == true);
    try std.testing.expect(client_mod.UpdateStatus.CANCELLED.isTerminal() == true);

    try std.testing.expect(client_mod.UpdateStatus.NEW.isTerminal() == false);
    try std.testing.expect(client_mod.UpdateStatus.DOWNLOADING.isTerminal() == false);
    try std.testing.expect(client_mod.UpdateStatus.SYNCING.isTerminal() == false);
    try std.testing.expect(client_mod.UpdateStatus.INPROGRESS.isTerminal() == false);
}

// Test: StepProgress initialization
test "step progress default initialization" {
    const progress = client_mod.StepProgress{};

    try std.testing.expectEqualStrings("", progress.status);
    try std.testing.expectEqual(@as(i64, 0), progress.progress);
    try std.testing.expectEqualStrings("", progress.@"status-msg");
    try std.testing.expectEqualStrings("", progress.logs);
    try std.testing.expectEqual(@as(i64, 0), progress.downloads.total.total_size);
}

// Test: DownloadProgress initialization
test "download progress default initialization" {
    const download_progress = client_mod.DownloadProgress{};

    try std.testing.expectEqual(@as(i64, 0), download_progress.total.total_size);
    try std.testing.expectEqual(@as(i64, 0), download_progress.total.total_downloaded);
    try std.testing.expect(download_progress.objects == null);
}

// Test: Client memory cleanup
test "client memory cleanup on deinit" {
    const allocator = std.testing.allocator;

    var temp_dir = try std.fs.cwd().makeOpenPath("test_client_logs_5", .{});
    defer temp_dir.close();

    var logger = try logger_mod.Logger.init("test_client_logs_5/test.log", false);
    defer logger.deinit();

    {
        var client = try client_mod.Client.init(allocator, "example.com", "8080", &logger);
        // Allocate a token
        client.token = try allocator.dupe(u8, "test_token_12345");
        client.deinit();
        // If we reach here without crashes, cleanup worked
    }

    // Clean up
    try std.fs.cwd().deleteTree("test_client_logs_5");
}

// Test: Client with various valid ports
test "client init with various valid ports" {
    const allocator = std.testing.allocator;

    var temp_dir = try std.fs.cwd().makeOpenPath("test_client_logs_6", .{});
    defer temp_dir.close();

    var logger = try logger_mod.Logger.init("test_client_logs_6/test.log", false);
    defer logger.deinit();

    // Test minimum port
    var client1 = try client_mod.Client.init(allocator, "example.com", "1", &logger);
    defer client1.deinit();
    try std.testing.expectEqualStrings("1", client1.pantahub_port);

    // Test maximum port
    var client2 = try client_mod.Client.init(allocator, "example.com", "65535", &logger);
    defer client2.deinit();
    try std.testing.expectEqualStrings("65535", client2.pantahub_port);

    // Test common HTTPS port
    var client3 = try client_mod.Client.init(allocator, "example.com", "443", &logger);
    defer client3.deinit();
    try std.testing.expectEqualStrings("443", client3.pantahub_port);

    // Clean up
    try std.fs.cwd().deleteTree("test_client_logs_6");
}

// Test: DeviceCredentials structure
test "device credentials structure" {
    const allocator = std.testing.allocator;

    const prn = try allocator.dupe(u8, "prn:pantahub::device:test-device");
    const secret = try allocator.dupe(u8, "secret123");
    const challenge = try allocator.dupe(u8, "challenge456");

    const creds = client_mod.Client.DeviceCredentials{
        .prn = prn,
        .secret = secret,
        .challenge = challenge,
    };

    try std.testing.expectEqualStrings("prn:pantahub::device:test-device", creds.prn);
    try std.testing.expectEqualStrings("secret123", creds.secret);
    try std.testing.expectEqualStrings("challenge456", creds.challenge.?);

    allocator.free(prn);
    allocator.free(secret);
    allocator.free(challenge);
}

// Test: LogEntry structure
test "log entry structure" {
    const log_entry = client_mod.LogEntry{
        .tsec = 1234567890,
        .tnano = 123456789,
        .rev = "1",
        .plat = "arm64",
        .src = "app",
        .lvl = "INFO",
        .msg = "Test message",
    };

    try std.testing.expectEqual(@as(i64, 1234567890), log_entry.tsec);
    try std.testing.expectEqual(@as(i64, 123456789), log_entry.tnano);
    try std.testing.expectEqualStrings("1", log_entry.rev);
    try std.testing.expectEqualStrings("arm64", log_entry.plat);
    try std.testing.expectEqualStrings("app", log_entry.src);
    try std.testing.expectEqualStrings("INFO", log_entry.lvl);
    try std.testing.expectEqualStrings("Test message", log_entry.msg);
}

// Test: Step structure with full initialization
test "step structure initialization" {
    const step = client_mod.Step{
        .id = "step-001",
        .rev = 1,
        .device = "device-001",
        .owner = "owner-123",
        .@"trail-id" = "trail-001",
        .@"time-created" = "2024-01-01T00:00:00Z",
        .@"time-modified" = "2024-01-01T00:00:00Z",
        .@"step-time" = "2024-01-01T00:00:00Z",
        .@"progress-time" = "2024-01-01T00:00:00Z",
    };

    try std.testing.expectEqualStrings("step-001", step.id);
    try std.testing.expectEqual(@as(i64, 1), step.rev);
    try std.testing.expectEqualStrings("device-001", step.device);
}

// Test: StepObject structure
test "step object structure" {
    const step_obj = client_mod.StepObject{
        .id = "obj-001",
        .sha256sum = "356a192b7913b04c54574d18c28d46e6395428ab",
        .size = "1024",
        .sizeint = 1024,
        .objectname = "object.bin",
        .@"signed-geturl" = "https://storage.example.com/get/obj-001",
        .@"expire-time" = "2024-12-31T23:59:59Z",
        .now = "2024-01-01T00:00:00Z",
        .owner = "owner-123",
        .@"storage-id" = "storage-001",
        .@"time-created" = "2024-01-01T00:00:00Z",
        .@"time-modified" = "2024-01-01T00:00:00Z",
        .@"mime-type" = "application/octet-stream",
    };

    try std.testing.expectEqualStrings("obj-001", step_obj.id);
    try std.testing.expectEqualStrings("object.bin", step_obj.objectname);
    try std.testing.expectEqual(@as(i64, 1024), step_obj.sizeint);
}

// Test: Client initialization with subdomain hostname
test "client init with subdomain hostname" {
    const allocator = std.testing.allocator;

    var temp_dir = try std.fs.cwd().makeOpenPath("test_client_logs_7", .{});
    defer temp_dir.close();

    var logger = try logger_mod.Logger.init("test_client_logs_7/test.log", false);
    defer logger.deinit();

    var client = try client_mod.Client.init(allocator, "api.pantahub.example.com", "8443", &logger);
    defer client.deinit();

    try std.testing.expectEqualStrings("api.pantahub.example.com", client.pantahub_host);

    // Clean up
    try std.fs.cwd().deleteTree("test_client_logs_7");
}

// Test: UpdateStatus roundtrip (parse -> toString)
test "update status roundtrip" {
    const statuses = [_]client_mod.UpdateStatus{
        .NEW,
        .SYNCING,
        .QUEUED,
        .DOWNLOADING,
        .INPROGRESS,
        .TESTING,
        .UPDATED,
        .DONE,
        .WONTGO,
        .ERROR,
        .CANCELLED,
    };

    for (statuses) |status| {
        const str = status.toString();
        const parsed = client_mod.UpdateStatus.parse(str);
        try std.testing.expectEqual(status, parsed.?);
    }
}

// Test: Empty StepProgress
test "empty step progress" {
    const empty = client_mod.StepProgress{};
    try std.testing.expectEqual(@as(i64, 0), empty.progress);
    try std.testing.expect(empty.downloads.objects == null);
}
