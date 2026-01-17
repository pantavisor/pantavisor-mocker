const std = @import("std");
const validation = @import("app").validation;

const testing = std.testing;

test "validation.validate_url: valid http url" {
    try validation.validate_url("http://example.com");
}

test "validation.validate_url: valid https url" {
    try validation.validate_url("https://example.com");
}

test "validation.validate_url: valid https url with port" {
    try validation.validate_url("https://example.com:443");
}

test "validation.validate_url: valid https url with path" {
    try validation.validate_url("https://example.com/api/v1");
}

test "validation.validate_url: valid https url with query params" {
    try validation.validate_url("https://example.com/api?param=value");
}

test "validation.validate_url: valid https url with fragment" {
    try validation.validate_url("https://example.com/#section");
}

test "validation.validate_url: valid complex url" {
    try validation.validate_url("https://example.com:8443/api/v1/devices/123?status=active#info");
}

test "validation.validate_url: empty url" {
    try testing.expectError(validation.ValidationError.EmptyInput, validation.validate_url(""));
}

test "validation.validate_url: no scheme" {
    try testing.expectError(validation.ValidationError.InvalidUrl, validation.validate_url("example.com"));
}

test "validation.validate_url: invalid scheme" {
    try testing.expectError(validation.ValidationError.InvalidUrl, validation.validate_url("ftp://example.com"));
}

test "validation.validate_url: too long" {
    const too_long_url = "https://" ++ "a" ** 2048;
    try testing.expectError(validation.ValidationError.MalformedInput, validation.validate_url(too_long_url));
}

test "validation.validate_url: invalid characters" {
    try testing.expectError(validation.ValidationError.InvalidUrl, validation.validate_url("https://example.com/with spaces"));
}

test "validation.validate_hostname: valid hostname" {
    try validation.validate_hostname("example.com");
}

test "validation.validate_hostname: valid hostname with subdomain" {
    try validation.validate_hostname("api.example.com");
}

test "validation.validate_hostname: valid hostname with hyphens" {
    try validation.validate_hostname("my-example-server.com");
}

test "validation.validate_hostname: valid single label" {
    try validation.validate_hostname("localhost");
}

test "validation.validate_hostname: empty hostname" {
    try testing.expectError(validation.ValidationError.EmptyInput, validation.validate_hostname(""));
}

test "validation.validate_hostname: too long" {
    const too_long = "a" ** 254;
    try testing.expectError(validation.ValidationError.InvalidHostname, validation.validate_hostname(too_long));
}

test "validation.validate_hostname: starts with hyphen" {
    try testing.expectError(validation.ValidationError.InvalidHostname, validation.validate_hostname("-example.com"));
}

test "validation.validate_hostname: ends with hyphen" {
    try testing.expectError(validation.ValidationError.InvalidHostname, validation.validate_hostname("example.com-"));
}

test "validation.validate_hostname: starts with dot" {
    try testing.expectError(validation.ValidationError.InvalidHostname, validation.validate_hostname(".example.com"));
}

test "validation.validate_hostname: ends with dot" {
    try testing.expectError(validation.ValidationError.InvalidHostname, validation.validate_hostname("example.com."));
}

test "validation.validate_hostname: invalid characters" {
    try testing.expectError(validation.ValidationError.InvalidHostname, validation.validate_hostname("example_com"));
}

test "validation.validate_port: valid http port" {
    const result = try validation.validate_port("80");
    try testing.expectEqual(result, 80);
}

test "validation.validate_port: valid https port" {
    const result = try validation.validate_port("443");
    try testing.expectEqual(result, 443);
}

test "validation.validate_port: valid custom port" {
    const result = try validation.validate_port("8080");
    try testing.expectEqual(result, 8080);
}

test "validation.validate_port: maximum valid port" {
    const result = try validation.validate_port("65535");
    try testing.expectEqual(result, 65535);
}

test "validation.validate_port: empty port" {
    try testing.expectError(validation.ValidationError.EmptyInput, validation.validate_port(""));
}

test "validation.validate_port: too long" {
    try testing.expectError(validation.ValidationError.InvalidPort, validation.validate_port("123456"));
}

test "validation.validate_port: non-numeric" {
    try testing.expectError(validation.ValidationError.InvalidPort, validation.validate_port("abc"));
}

test "validation.validate_port: mixed alpha-numeric" {
    try testing.expectError(validation.ValidationError.InvalidPort, validation.validate_port("80abc"));
}

test "validation.validate_port: zero port" {
    try testing.expectError(validation.ValidationError.InvalidPort, validation.validate_port("0"));
}

test "validation.validate_port: negative number" {
    try testing.expectError(validation.ValidationError.InvalidPort, validation.validate_port("-1"));
}

test "validation.validate_port: exceeds maximum" {
    try testing.expectError(validation.ValidationError.InvalidPort, validation.validate_port("65536"));
}
