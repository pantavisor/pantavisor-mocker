const std = @import("std");

pub const c = @cImport({
    @cInclude("curl/curl.h");
    @cInclude("stdlib.h");
});

// Import Shim Functions
extern "c" fn curl_shim_global_init() c.CURLcode;
extern "c" fn curl_shim_global_cleanup() void;
extern "c" fn curl_shim_init() ?*c.CURL;
extern "c" fn curl_shim_cleanup(handle: *c.CURL) void;
extern "c" fn curl_shim_perform(handle: *c.CURL) c.CURLcode;
extern "c" fn curl_shim_setopt_ptr(handle: *c.CURL, option: c.CURLoption, value: ?*anyopaque) c.CURLcode;
extern "c" fn curl_shim_setopt_long(handle: *c.CURL, option: c.CURLoption, value: c_long) c.CURLcode;
extern "c" fn curl_shim_getinfo_long(handle: *c.CURL, info: c.CURLINFO, value: *c_long) c.CURLcode;
extern "c" fn curl_shim_slist_append(list: ?*c.curl_slist, string: [*:0]const u8) ?*c.curl_slist;
extern "c" fn curl_shim_slist_free_all(list: ?*c.curl_slist) void;
extern "c" fn curl_shim_simple_request(url: [*:0]const u8, method: [*:0]const u8, payload: ?[*:0]const u8, headers: ?*c.curl_slist, response: *?[*]u8, response_len: *usize) c.CURLcode;

pub const Curl = struct {
    handle: *c.CURL,

    pub fn global_init() !void {
        if (curl_shim_global_init() != c.CURLE_OK) {
            return error.CurlGlobalInitFailed;
        }
    }

    pub fn global_cleanup() void {
        curl_shim_global_cleanup();
    }

    pub fn init() !Curl {
        const handle = curl_shim_init();
        if (handle == null) return error.CurlInitFailed;
        return Curl{ .handle = handle.? };
    }

    pub fn deinit(self: *Curl) void {
        curl_shim_cleanup(self.handle);
    }

    pub fn set_opt(self: *Curl, option: c_int, value: anytype) !void {
        const res = switch (@TypeOf(value)) {
            []const u8, [:0]const u8, [:0]u8, []u8 => curl_shim_setopt_ptr(self.handle, @as(c.CURLoption, @intCast(option)), @ptrCast(@constCast(value.ptr))),
            [*]const u8 => curl_shim_setopt_ptr(self.handle, @as(c.CURLoption, @intCast(option)), @ptrCast(@constCast(value))),
            usize => curl_shim_setopt_long(self.handle, @as(c.CURLoption, @intCast(option)), @as(c_long, @intCast(value))),
            i64 => curl_shim_setopt_long(self.handle, @as(c.CURLoption, @intCast(option)), @as(c_long, @intCast(value))),
            c_long => curl_shim_setopt_long(self.handle, @as(c.CURLoption, @intCast(option)), value),
            comptime_int => curl_shim_setopt_long(self.handle, @as(c.CURLoption, @intCast(option)), @as(c_long, @intCast(value))),
            bool => curl_shim_setopt_long(self.handle, @as(c.CURLoption, @intCast(option)), @as(c_long, if (value) 1 else 0)),
            *anyopaque, ?*anyopaque => curl_shim_setopt_ptr(self.handle, @as(c.CURLoption, @intCast(option)), value),
            ?*c.curl_slist => curl_shim_setopt_ptr(self.handle, @as(c.CURLoption, @intCast(option)), @ptrCast(value)),
            *BufferContext => curl_shim_setopt_ptr(self.handle, @as(c.CURLoption, @intCast(option)), @ptrCast(value)),
            else => blk: {
                // Function pointers
                if (@typeInfo(@TypeOf(value)) == .@"fn" or (@typeInfo(@TypeOf(value)) == .pointer and @typeInfo(@typeInfo(@TypeOf(value)).pointer.child) == .@"fn")) {
                    break :blk curl_shim_setopt_ptr(self.handle, @as(c.CURLoption, @intCast(option)), @ptrCast(@constCast(value)));
                }
                @compileError("Unsupported type for set_opt: " ++ @typeName(@TypeOf(value)));
            },
        };
        if (res != c.CURLE_OK) return error.CurlSetOptFailed;
    }

    pub fn perform(self: *Curl) !void {
        const res = curl_shim_perform(self.handle);
        if (res != c.CURLE_OK) {
            return error.CurlPerformFailed;
        }
    }

    pub fn get_info(self: *Curl, info: c_int, value: *c_long) !void {
        const res = c.curl_easy_getinfo(self.handle, @as(c.CURLINFO, @intCast(info)), value);
        if (res != c.CURLE_OK) return error.CurlGetInfoFailed;
    }

    pub fn simple_request(url: []const u8, method: []const u8, payload: ?[]const u8, headers: ?*c.curl_slist, allocator: std.mem.Allocator) ![]u8 {
        const url_z = try allocator.dupeZ(u8, url);
        defer allocator.free(url_z);
        const method_z = try allocator.dupeZ(u8, method);
        defer allocator.free(method_z);
        const payload_z = if (payload) |p| try allocator.dupeZ(u8, p) else null;
        defer if (payload_z) |p| allocator.free(p);

        var response_ptr: ?[*]u8 = null;
        var response_len: usize = 0;

        const res = curl_shim_simple_request(url_z, method_z, if (payload_z) |p| p else null, headers, &response_ptr, &response_len);
        if (res != c.CURLE_OK) return error.CurlPerformFailed;

        if (response_ptr) |ptr| {
            const owned = try allocator.dupe(u8, ptr[0..response_len]);
            // The C shim used malloc, so we should use free from libc
            std.c.free(ptr);
            return owned;
        }
        return allocator.dupe(u8, "");
    }
};

// Simplified Write Buffer Context
pub const BufferContext = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BufferContext {
        return .{
            .buffer = std.ArrayList(u8){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BufferContext) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn write_callback(ptr: *anyopaque, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
        const real_size = size * nmemb;
        const self: *BufferContext = @ptrCast(@alignCast(userdata));
        const data: [*]const u8 = @ptrCast(ptr);
        self.buffer.appendSlice(self.allocator, data[0..real_size]) catch return 0;
        return real_size;
    }
};

// Re-export constants needed by client.zig
pub const CURLOPT_URL = c.CURLOPT_URL;
pub const CURLOPT_PORT = c.CURLOPT_PORT;
pub const CURLOPT_VERBOSE = c.CURLOPT_VERBOSE;
pub const CURLOPT_HEADER = c.CURLOPT_HEADER;
pub const CURLOPT_HTTPHEADER = c.CURLOPT_HTTPHEADER;
pub const CURLOPT_CUSTOMREQUEST = c.CURLOPT_CUSTOMREQUEST;
pub const CURLOPT_WRITEFUNCTION = c.CURLOPT_WRITEFUNCTION;
pub const CURLOPT_WRITEDATA = c.CURLOPT_WRITEDATA;
pub const CURLOPT_POSTFIELDS = c.CURLOPT_POSTFIELDS;
pub const CURLOPT_POSTFIELDSIZE = c.CURLOPT_POSTFIELDSIZE;
pub const CURLOPT_NOSIGNAL = c.CURLOPT_NOSIGNAL;
pub const CURLOPT_HTTP_VERSION = c.CURLOPT_HTTP_VERSION;
pub const CURLOPT_SSLCERT = c.CURLOPT_SSLCERT;
pub const CURLOPT_SSLKEY = c.CURLOPT_SSLKEY;
pub const CURL_HTTP_VERSION_1_1 = c.CURL_HTTP_VERSION_1_1;
pub const CURLINFO_RESPONSE_CODE = c.CURLINFO_RESPONSE_CODE;
pub const curl_slist = c.curl_slist;
pub const slist_append = curl_shim_slist_append;
pub const slist_free_all = curl_shim_slist_free_all;
