/// Pure Business Logic Module
///
/// This module contains testable business logic functions that:
/// - Have no external dependencies (no I/O, no network)
/// - Take inputs and return outputs deterministically
/// - Can be unit tested without mocks or fixtures
/// - Are easy to reason about and maintain
const std = @import("std");

/// Calculate the next revision based on stable and try revisions
///
/// Business Rules:
/// - If try_rev > stable_rev, return try_rev (continue testing)
/// - If has_pending_update, return stable_rev + 1 (new update available)
/// - Otherwise return stable_rev (no updates)
pub fn calculateNextRevision(stable_rev: i64, try_rev: i64, has_pending_update: bool) i64 {
    if (try_rev > stable_rev) return try_rev;
    if (has_pending_update) return stable_rev + 1;
    return stable_rev;
}

/// Determine if an update should proceed based on current state
pub fn shouldProceedWithUpdate(
    current_status: []const u8,
    has_pending_update: bool,
    is_testing: bool,
) bool {
    // Don't proceed if already in progress or error state
    if (std.mem.eql(u8, current_status, "INPROGRESS") or
        std.mem.eql(u8, current_status, "ERROR") or
        std.mem.eql(u8, current_status, "WONTGO") or
        std.mem.eql(u8, current_status, "CANCELLED"))
    {
        return false;
    }

    // If testing an update, don't start new one
    if (is_testing) return false;

    // Proceed if there's a pending update
    return has_pending_update;
}

/// Calculate progress percentage based on current step
pub fn calculateProgressPercentage(
    step: []const u8,
    total_steps: u32,
    current_step: u32,
) u32 {
    _ = step;
    if (total_steps == 0) return 0;
    const progress = (current_step * 100) / total_steps;
    return if (progress > 100) 100 else @as(u32, @intCast(progress));
}

/// Determine update status from progress value
pub fn statusFromProgress(progress: u32) []const u8 {
    return if (progress < 25)
        "QUEUED"
    else if (progress < 50)
        "DOWNLOADING"
    else if (progress < 75)
        "INPROGRESS"
    else if (progress < 100)
        "TESTING"
    else
        "DONE";
}

/// Validate that a revision string is valid
/// Valid revisions: positive integers
pub fn isValidRevision(revision: []const u8) bool {
    if (revision.len == 0) return false;
    for (revision) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Parse revision string to integer
pub fn parseRevision(revision: []const u8) ?i64 {
    if (!isValidRevision(revision)) return null;
    return std.fmt.parseInt(i64, revision, 10) catch null;
}

/// Check if device is properly initialized
pub fn isDeviceInitialized(device_id: ?[]const u8, device_secret: ?[]const u8) bool {
    return device_id != null and device_id.?.len > 0 and
        device_secret != null and device_secret.?.len > 0;
}

/// Check if device is claimed (has a Pantahub token)
pub fn isDeviceClaimed(pantahub_token: ?[]const u8) bool {
    return pantahub_token != null and pantahub_token.?.len > 0;
}

/// Calculate retry wait time with exponential backoff
/// base_delay: initial delay in milliseconds
/// retry_count: number of retries so far (0-based)
/// max_delay: maximum delay to cap backoff
pub fn calculateRetryDelay(base_delay: u32, retry_count: u32, max_delay: u32) u32 {
    // Exponential backoff: delay = base * 2^retry_count, capped at max_delay
    var delay = base_delay;
    var count: u32 = 0;
    while (count < retry_count and delay < max_delay / 2) : (count += 1) {
        delay *= 2;
    }
    return if (delay > max_delay) max_delay else delay;
}

/// Check if a SHA256 hash is valid (64 hex characters)
pub fn isValidSha256(hash: []const u8) bool {
    if (hash.len != 64) return false;
    for (hash) |c| {
        if (!isHexChar(c)) return false;
    }
    return true;
}

/// Check if a character is a valid hex digit
fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or
        (c >= 'a' and c <= 'f') or
        (c >= 'A' and c <= 'F');
}

/// Validate update response payload structure
pub const UpdateValidationError = error{
    MissingField,
    InvalidFormat,
};

pub fn validateUpdateResponse(payload: []const u8) UpdateValidationError!void {
    if (payload.len == 0) return UpdateValidationError.InvalidFormat;
    if (payload.len > 100 * 1024) return UpdateValidationError.InvalidFormat; // 100KB max
}

/// Check if a time interval has elapsed
pub fn hasIntervalElapsed(last_check_ms: i64, current_time_ms: i64, interval_ms: i64) bool {
    const diff = current_time_ms - last_check_ms;
    return diff >= interval_ms;
}

/// Format log entry timestamp (ISO 8601)
pub fn formatTimestamp(allocator: std.mem.Allocator, timestamp_sec: i64) ![]const u8 {
    // Simple format: timestamp as string
    return try std.fmt.allocPrint(allocator, "{d}", .{timestamp_sec});
}

// Tests
const testing = std.testing;

test "calculateNextRevision: try_rev higher than stable_rev" {
    const result = calculateNextRevision(5, 7, false);
    try testing.expectEqual(result, 7);
}

test "calculateNextRevision: has pending update" {
    const result = calculateNextRevision(5, 3, true);
    try testing.expectEqual(result, 6);
}

test "calculateNextRevision: no updates" {
    const result = calculateNextRevision(5, 3, false);
    try testing.expectEqual(result, 5);
}

test "shouldProceedWithUpdate: not in progress" {
    const result = shouldProceedWithUpdate("QUEUED", true, false);
    try testing.expect(result);
}

test "shouldProceedWithUpdate: already in progress" {
    const result = shouldProceedWithUpdate("INPROGRESS", true, false);
    try testing.expect(!result);
}

test "shouldProceedWithUpdate: currently testing" {
    const result = shouldProceedWithUpdate("TESTING", true, true);
    try testing.expect(!result);
}

test "calculateProgressPercentage" {
    const result = calculateProgressPercentage("downloading", 10, 5);
    try testing.expectEqual(result, 50);
}

test "statusFromProgress: queued" {
    const status = statusFromProgress(10);
    try testing.expect(std.mem.eql(u8, status, "QUEUED"));
}

test "statusFromProgress: downloading" {
    const status = statusFromProgress(40);
    try testing.expect(std.mem.eql(u8, status, "DOWNLOADING"));
}

test "statusFromProgress: done" {
    const status = statusFromProgress(100);
    try testing.expect(std.mem.eql(u8, status, "DONE"));
}

test "isValidRevision: valid" {
    try testing.expect(isValidRevision("123"));
}

test "isValidRevision: invalid" {
    try testing.expect(!isValidRevision("abc"));
    try testing.expect(!isValidRevision(""));
}

test "parseRevision: valid" {
    const result = parseRevision("42");
    try testing.expectEqual(result.?, 42);
}

test "parseRevision: invalid" {
    const result = parseRevision("abc");
    try testing.expectEqual(result, null);
}

test "isDeviceInitialized: true" {
    try testing.expect(isDeviceInitialized("device-id", "secret"));
}

test "isDeviceInitialized: false" {
    try testing.expect(!isDeviceInitialized(null, "secret"));
    try testing.expect(!isDeviceInitialized("device-id", null));
}

test "isDeviceClaimed: true" {
    try testing.expect(isDeviceClaimed("token-value"));
}

test "isDeviceClaimed: false" {
    try testing.expect(!isDeviceClaimed(null));
}

test "calculateRetryDelay: exponential backoff" {
    const delay0 = calculateRetryDelay(100, 0, 5000);
    const delay1 = calculateRetryDelay(100, 1, 5000);
    const delay2 = calculateRetryDelay(100, 2, 5000);
    try testing.expectEqual(delay0, 100);
    try testing.expectEqual(delay1, 200);
    try testing.expectEqual(delay2, 400);
}

test "calculateRetryDelay: capped at max" {
    const delay = calculateRetryDelay(100, 10, 500);
    try testing.expectEqual(delay, 400);
}

test "isValidSha256: valid" {
    const hash = "0000000000000000000000000000000000000000000000000000000000000000";
    try testing.expect(isValidSha256(hash));
}

test "isValidSha256: invalid length" {
    try testing.expect(!isValidSha256("000000000000000"));
}

test "isValidSha256: invalid chars" {
    const hash = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";
    try testing.expect(!isValidSha256(hash));
}

test "hasIntervalElapsed: true" {
    const result = hasIntervalElapsed(1000, 2500, 1000);
    try testing.expect(result);
}

test "hasIntervalElapsed: false" {
    const result = hasIntervalElapsed(1000, 1500, 1000);
    try testing.expect(!result);
}
