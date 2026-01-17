const std = @import("std");

pub const ValidationError = error{
    InvalidUrl,
    InvalidHostname,
    InvalidPort,
    InvalidJson,
    EmptyInput,
    MalformedInput,
};

/// Validates that a URL has a valid scheme (http or https) and basic structure
pub fn validate_url(url: []const u8) ValidationError!void {
    if (url.len == 0) {
        return ValidationError.EmptyInput;
    }

    if (url.len > 2048) {
        return ValidationError.MalformedInput;
    }

    // Check for valid schemes
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return ValidationError.InvalidUrl;
    }

    // Basic check that URL has content after scheme
    const after_scheme = if (std.mem.startsWith(u8, url, "https://")) url[8..] else url[7..];
    if (after_scheme.len == 0) {
        return ValidationError.InvalidUrl;
    }

    // Check for valid characters (alphanumeric, -, ., :, /, _, ~, ?, &, =, %)
    for (after_scheme) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9' => {},
            '-', '.', ':', '/', '_', '~', '?', '&', '=', '%', '@', '+', '$', ',', ';', '#' => {},
            else => return ValidationError.InvalidUrl,
        }
    }
}

/// Validates that a hostname is not empty and contains valid characters
pub fn validate_hostname(hostname: []const u8) ValidationError!void {
    if (hostname.len == 0) {
        return ValidationError.EmptyInput;
    }

    if (hostname.len > 253) {
        return ValidationError.InvalidHostname;
    }

    // Check for valid hostname characters
    for (hostname) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9' => {},
            '-', '.' => {},
            else => return ValidationError.InvalidHostname,
        }
    }

    // Hostname shouldn't start with hyphen or dot
    if (hostname[0] == '-' or hostname[0] == '.') {
        return ValidationError.InvalidHostname;
    }

    // Hostname shouldn't end with hyphen or dot
    if (hostname[hostname.len - 1] == '-' or hostname[hostname.len - 1] == '.') {
        return ValidationError.InvalidHostname;
    }
}

/// Validates that a port number is valid (1-65535)
pub fn validate_port(port: []const u8) ValidationError!u16 {
    if (port.len == 0) {
        return ValidationError.EmptyInput;
    }

    if (port.len > 5) {
        return ValidationError.InvalidPort;
    }

    // Check that all characters are digits
    for (port) |c| {
        if (c < '0' or c > '9') {
            return ValidationError.InvalidPort;
        }
    }

    const port_num = std.fmt.parseInt(u16, port, 10) catch {
        return ValidationError.InvalidPort;
    };

    if (port_num < 1) {
        return ValidationError.InvalidPort;
    }

    return port_num;
}

/// Basic JSON structure validation - checks for balanced braces/brackets
pub fn validate_json_structure(json: []const u8) ValidationError!void {
    if (json.len == 0) {
        return ValidationError.EmptyInput;
    }

    var brace_count: i32 = 0;
    var bracket_count: i32 = 0;
    var in_string = false;
    var escape_next = false;

    for (json) |c| {
        if (escape_next) {
            escape_next = false;
            continue;
        }

        if (c == '\\') {
            escape_next = true;
            continue;
        }

        if (c == '"') {
            in_string = !in_string;
            continue;
        }

        if (in_string) {
            continue;
        }

        switch (c) {
            '{' => brace_count += 1,
            '}' => brace_count -= 1,
            '[' => bracket_count += 1,
            ']' => bracket_count -= 1,
            else => {},
        }

        if (brace_count < 0 or bracket_count < 0) {
            return ValidationError.InvalidJson;
        }
    }

    if (brace_count != 0 or bracket_count != 0 or in_string) {
        return ValidationError.InvalidJson;
    }
}

/// Validates revision string (should be numeric or valid identifier)
pub fn validate_revision(rev: []const u8) ValidationError!void {
    if (rev.len == 0) {
        return ValidationError.EmptyInput;
    }

    if (rev.len > 64) {
        return ValidationError.MalformedInput;
    }

    // Revision should be numeric or alphanumeric with hyphens
    for (rev) |c| {
        switch (c) {
            '0'...'9' => {},
            'a'...'z', 'A'...'Z' => {},
            '-', '_' => {},
            else => return ValidationError.MalformedInput,
        }
    }
}

/// Validates file path for basic security (prevents directory traversal)
pub fn validate_file_path(path: []const u8) ValidationError!void {
    if (path.len == 0) {
        return ValidationError.EmptyInput;
    }

    // Check for directory traversal attempts
    if (std.mem.indexOf(u8, path, "..") != null) {
        return ValidationError.MalformedInput;
    }

    // Path should not contain null bytes
    if (std.mem.indexOf(u8, path, "\x00") != null) {
        return ValidationError.MalformedInput;
    }
}

/// Validates a SHA256 hex string (64 characters, all hex digits)
pub fn validate_sha256(sha: []const u8) ValidationError!void {
    if (sha.len != 64) {
        return ValidationError.MalformedInput;
    }

    for (sha) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return ValidationError.MalformedInput,
        }
    }
}

test "validate_url with valid https" {
    try validate_url("https://pantahub.example.com/api/v1/update");
}

test "validate_url with valid http" {
    try validate_url("http://localhost:8080/path");
}

test "validate_url rejects invalid scheme" {
    try std.testing.expectError(ValidationError.InvalidUrl, validate_url("ftp://example.com"));
}

test "validate_url rejects empty" {
    try std.testing.expectError(ValidationError.EmptyInput, validate_url(""));
}

test "validate_hostname with valid name" {
    try validate_hostname("pantahub.example.com");
}

test "validate_hostname rejects invalid chars" {
    try std.testing.expectError(ValidationError.InvalidHostname, validate_hostname("example.com/path"));
}

test "validate_port with valid port" {
    const port = try validate_port("8080");
    try std.testing.expectEqual(port, 8080);
}

test "validate_port rejects invalid" {
    try std.testing.expectError(ValidationError.InvalidPort, validate_port("99999"));
}

test "validate_sha256 with valid hash" {
    try validate_sha256("a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e");
}

test "validate_sha256 rejects invalid length" {
    try std.testing.expectError(ValidationError.MalformedInput, validate_sha256("abc"));
}

test "validate_file_path rejects directory traversal" {
    try std.testing.expectError(ValidationError.MalformedInput, validate_file_path("../../etc/passwd"));
}
