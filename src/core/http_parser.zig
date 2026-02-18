const std = @import("std");

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
};

pub const HttpRequest = struct {
    method: HttpMethod,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,

    pub fn deinit(self: *HttpRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        var it = self.headers.keyIterator();
        while (it.next()) |key| {
            const value = self.headers.get(key.*).?;
            allocator.free(value);
            allocator.free(key.*);
        }
        self.headers.deinit();
        if (self.body) |body| {
            allocator.free(body);
        }
    }
};

pub const HttpResponse = struct {
    status_code: u16,
    status_text: []const u8,
    content_type: []const u8,
    body: []const u8,

    pub fn serialize(self: HttpResponse, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(allocator);

        try buf.writer(allocator).print(
            "HTTP/1.1 {d} {s}\r\n",
            .{ self.status_code, self.status_text },
        );
        try buf.writer(allocator).print(
            "Content-Type: {s}\r\n",
            .{self.content_type},
        );
        try buf.writer(allocator).print(
            "Content-Length: {d}\r\n",
            .{self.body.len},
        );
        try buf.writer(allocator).print("Connection: close\r\n", .{});
        try buf.writer(allocator).print("\r\n", .{});
        try buf.writer(allocator).writeAll(self.body);

        return buf.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub fn parseMethod(method_str: []const u8) !HttpMethod {
    if (std.mem.eql(u8, method_str, "GET")) return .GET;
    if (std.mem.eql(u8, method_str, "POST")) return .POST;
    if (std.mem.eql(u8, method_str, "PUT")) return .PUT;
    if (std.mem.eql(u8, method_str, "DELETE")) return .DELETE;
    return error.InvalidMethod;
}

pub fn parseRequest(allocator: std.mem.Allocator, data: []const u8) !HttpRequest {
    var lines = std.mem.splitSequence(u8, data, "\r\n");

    // Parse request line
    const request_line = lines.next() orelse return error.InvalidRequest;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = parts.next() orelse return error.InvalidRequest;
    const path = parts.next() orelse return error.InvalidRequest;
    const version = parts.next() orelse return error.InvalidRequest;

    if (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0")) {
        return error.InvalidVersion;
    }

    const method = try parseMethod(method_str);

    // Parse headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = headers.keyIterator();
        while (it.next()) |key| {
            const value = headers.get(key.*).?;
            allocator.free(value);
            allocator.free(key.*);
        }
        headers.deinit();
    }

    var content_length: ?usize = null;

    while (lines.next()) |line| {
        if (line.len == 0) break;

        if (std.mem.indexOf(u8, line, ": ")) |colon_idx| {
            const key = try allocator.dupe(u8, line[0..colon_idx]);
            const value = try allocator.dupe(u8, line[colon_idx + 2 ..]);
            try headers.put(key, value);

            if (std.ascii.eqlIgnoreCase(key, "Content-Length")) {
                content_length = std.fmt.parseInt(usize, value, 10) catch null;
            }
        }
    }

    // Parse body if present
    var body: ?[]const u8 = null;
    if (content_length) |len| {
        if (len > 0) {
            // Find the end of headers (double CRLF)
            const header_end = std.mem.indexOf(u8, data, "\r\n\r\n");
            if (header_end) |end| {
                const body_start = end + 4;
                if (body_start + len <= data.len) {
                    body = try allocator.dupe(u8, data[body_start .. body_start + len]);
                }
            }
        }
    }

    const path_dup = try allocator.dupe(u8, path);
    errdefer allocator.free(path_dup);

    return HttpRequest{
        .method = method,
        .path = path_dup,
        .headers = headers,
        .body = body,
    };
}

test "parse simple GET request" {
    const allocator = std.testing.allocator;
    const request = "GET /containers HTTP/1.1\r\nHost: localhost\r\n\r\n";

    var parsed = try parseRequest(allocator, request);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(HttpMethod.GET, parsed.method);
    try std.testing.expectEqualStrings("/containers", parsed.path);
    try std.testing.expect(parsed.body == null);
}

test "parse POST request with body" {
    const allocator = std.testing.allocator;
    const request = "POST /signal HTTP/1.1\r\nContent-Length: 30\r\n\r\n{\"type\":\"ready\",\"payload\":\"\"}";

    var parsed = try parseRequest(allocator, request);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(HttpMethod.POST, parsed.method);
    try std.testing.expectEqualStrings("/signal", parsed.path);
    try std.testing.expect(parsed.body != null);
    try std.testing.expectEqualStrings("{\"type\":\"ready\",\"payload\":\"\"}", parsed.body.?);
}

test "serialize response" {
    const allocator = std.testing.allocator;
    const response = HttpResponse{
        .status_code = 200,
        .status_text = "OK",
        .content_type = "application/json",
        .body = "{\"status\":\"ok\"}",
    };

    const serialized = try response.serialize(allocator);
    defer allocator.free(serialized);

    try std.testing.expect(std.mem.containsAtLeast(u8, serialized, 1, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.containsAtLeast(u8, serialized, 1, "Content-Type: application/json"));
    try std.testing.expect(std.mem.containsAtLeast(u8, serialized, 1, "{\"status\":\"ok\"}"));
}
