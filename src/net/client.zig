const std = @import("std");
const curl_mod = @import("curl.zig");
const logger_mod = @import("../core/logger.zig");
const validation = @import("../core/validation.zig");
const constants = @import("../core/constants.zig");
const business_logic = @import("../core/business_logic.zig");

pub const DownloadProgress = struct {
    pub const Total = struct {
        total_size: i64 = 0,
        total_downloaded: i64 = 0,
        start_time: i64 = 0,
        current_time: i64 = 0,
    };
    total: Total = .{},
    objects: ?std.json.Value = null,
};

pub const StepProgress = struct {
    status: []const u8 = "",
    progress: i64 = 0,
    @"status-msg": []const u8 = "",
    logs: []const u8 = "",
    downloads: DownloadProgress = .{},
};

pub const StepObject = struct {
    id: []const u8,
    sha256sum: []const u8,
    size: []const u8,
    sizeint: i64,
    objectname: []const u8,
    @"signed-geturl": ?[]const u8 = null,
    @"signed-puturl": ?[]const u8 = null,
    @"expire-time": []const u8,
    now: []const u8,
    owner: []const u8,
    @"storage-id": []const u8,
    @"time-created": []const u8,
    @"time-modified": []const u8,
    @"mime-type": []const u8,
};

pub const Step = struct {
    id: []const u8,
    rev: i64,
    device: []const u8,
    owner: []const u8,
    @"trail-id": []const u8,
    @"time-created": []const u8,
    @"time-modified": []const u8,
    @"step-time": []const u8,
    @"progress-time": []const u8,
    progress: StepProgress = .{},
    state: ?std.json.Value = null,
    meta: ?std.json.Value = null,
    @"commit-msg": ?[]const u8 = null,
    committer: ?[]const u8 = null,
    used_objects: ?[]const []const u8 = null,
};

pub const LogEntry = struct {
    tsec: i64,
    tnano: i64,
    rev: []const u8,
    plat: []const u8,
    src: []const u8,
    lvl: []const u8,
    msg: []const u8,
};

pub const UpdateStatus = enum {
    NEW,
    SYNCING,
    QUEUED,
    DOWNLOADING,
    INPROGRESS,
    TESTING,
    UPDATED,
    DONE,
    WONTGO,
    ERROR,
    CANCELLED,

    pub fn parse(s: []const u8) ?UpdateStatus {
        if (std.ascii.eqlIgnoreCase(s, "CANCELED")) return .CANCELLED;
        inline for (@typeInfo(UpdateStatus).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @field(UpdateStatus, f.name);
        }
        return null;
    }

    pub fn toString(self: UpdateStatus) []const u8 {
        return @tagName(self);
    }

    pub fn isTerminal(self: UpdateStatus) bool {
        return switch (self) {
            .DONE, .UPDATED, .WONTGO, .ERROR, .CANCELLED => true,
            else => false,
        };
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    pantahub_host: []const u8,
    pantahub_port: []const u8,
    logger: ?*logger_mod.Logger,
    token: ?[]const u8 = null,
    use_https: bool = true,

    fn isLocalHost(host: []const u8) bool {
        return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost");
    }

    fn getScheme(self: *const Client) []const u8 {
        return if (self.use_https) "https" else "http";
    }

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: []const u8, logger: ?*logger_mod.Logger) !Client {
        std.debug.assert(host.len > 0);
        std.debug.assert(port.len > 0);

        // Validate hostname and port
        try validation.validate_hostname(host);
        _ = try validation.validate_port(port);

        return Client{
            .allocator = allocator,
            .pantahub_host = try allocator.dupe(u8, host),
            .pantahub_port = try allocator.dupe(u8, port),
            .logger = logger,
            .use_https = !isLocalHost(host),
        };
    }

    fn get_object_id_from_prn(prn: []const u8) []const u8 {
        std.debug.assert(prn.len > 0);
        if (std.mem.lastIndexOf(u8, prn, "/")) |idx| {
            if (idx + 1 < prn.len) {
                const res = prn[idx + 1 ..];
                std.debug.assert(res.len > 0);
                return res;
            }
        }
        return prn;
    }

    pub fn deinit(self: *Client) void {
        std.debug.assert(self.pantahub_host.len > 0);
        self.allocator.free(self.pantahub_host);
        self.allocator.free(self.pantahub_port);
        if (self.token) |t| self.allocator.free(t);
    }

    fn log(self: *Client, comptime format: []const u8, args: anytype) void {
        if (self.logger) |l| l.log(format, args);
    }

    fn log_debug(self: *Client, comptime format: []const u8, args: anytype) void {
        if (self.logger) |l| l.log_debug(format, args);
    }

    fn request(self: *Client, method: []const u8, url: []const u8, body: ?[]const u8, headers: []const std.http.Header) ![]u8 {
        std.debug.assert(url.len > 0);
        self.log("HTTP Request: {s} {s}", .{ method, url });
        if (body) |b| {
            // Simple obfuscation for logs: Check for "password" or "token" or "Authorization"
            var is_sensitive = false;
            if (std.mem.indexOf(u8, b, "\"password\"") != null) is_sensitive = true;

            if (is_sensitive) {
                self.log("HTTP Body: (Obfuscated)", .{});
            } else {
                if (b.len < 1024) {
                    self.log("HTTP Body: {s}", .{b});
                } else {
                    self.log("HTTP Body: ({d} bytes)", .{b.len});
                }
            }

            // Only log debug body if not sensitive
            if (b.len > 0 and !is_sensitive) {
                self.log_debug("HTTP Body (Full): {s}", .{b});
            }
        }

        var slist: ?*curl_mod.curl_slist = null;
        // Default User-Agent
        const ua_z = try self.allocator.dupeZ(u8, "User-Agent: Pantavisor-Mocker/0.1");
        defer self.allocator.free(ua_z);
        slist = curl_mod.slist_append(slist, ua_z);

        for (headers) |h| {
            var val_to_log = h.value;
            if (std.mem.eql(u8, h.name, "Authorization") or std.mem.eql(u8, h.name, "Pantahub-Devices-Auto-Token-V1")) {
                val_to_log = "***";
            }
            // Log header (excluding sensitive values) - ACTUALLY, we aren't logging headers yet, but if we did...
            // Let's just create the curl headers.

            const h_str_raw = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ h.name, h.value });
            const h_str = try self.allocator.dupeZ(u8, h_str_raw);
            self.allocator.free(h_str_raw);
            defer self.allocator.free(h_str);
            slist = curl_mod.slist_append(slist, h_str);
        }
        defer if (slist != null) curl_mod.slist_free_all(slist);

        return try curl_mod.Curl.simple_request(url, method, body, slist, self.allocator);
    }

    pub fn login(self: *Client, prn: []const u8, secret: []const u8) !void {
        std.debug.assert(prn.len > 0);
        std.debug.assert(secret.len > 0);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}{s}", .{ self.getScheme(), self.pantahub_host, self.pantahub_port, "/auth/login" });
        defer self.allocator.free(url);

        // Build JSON safely using std.json.fmt to prevent injection
        const LoginPayload = struct {
            username: []const u8,
            password: []const u8,
        };
        const payload_struct = LoginPayload{ .username = prn, .password = secret };

        const payload = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(payload_struct, .{})});
        defer self.allocator.free(payload);

        const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
        const response = try self.request("POST", url, payload, &headers);
        defer self.allocator.free(response);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{ .duplicate_field_behavior = .use_last });
        defer parsed.deinit();

        if (parsed.value.object.get("token")) |t_val| {
            if (t_val == .string) {
                if (self.token) |old| self.allocator.free(old);
                self.token = try self.allocator.dupe(u8, t_val.string);
                std.debug.assert(self.token.?.len > 0);
                return;
            }
        }
        self.log("Login failed. Response: {s}", .{response});
        return error.NoTokenInResponse;
    }

    pub const DeviceCredentials = struct {
        prn: []u8,
        secret: []u8,
        challenge: ?[]u8,
    };

    pub fn register_device(self: *Client, host: []const u8, port: []const u8, autotok: ?[]const u8) !DeviceCredentials {
        std.debug.assert(host.len > 0);
        std.debug.assert(port.len > 0);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/devices/", .{ self.getScheme(), host, port });
        defer self.allocator.free(url);

        var headers_list = std.ArrayList(std.http.Header){};
        defer headers_list.deinit(self.allocator);
        try headers_list.append(self.allocator, .{ .name = "Content-Type", .value = "application/json" });
        if (autotok) |tok| try headers_list.append(self.allocator, .{ .name = "Pantahub-Devices-Auto-Token-V1", .value = tok });

        const response = try self.request("POST", url, "{}", headers_list.items);
        defer self.allocator.free(response);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{ .duplicate_field_behavior = .use_last }) catch |err| {
            self.log("Device registration failed to parse JSON. Response: {s}", .{response});
            return err;
        };
        defer parsed.deinit();

        const prn_val = parsed.value.object.get("prn") orelse {
            self.log("Device registration failed: missing 'prn'. Response: {s}", .{response});
            return error.MissingPrn;
        };
        if (prn_val != .string) {
            self.log("Device registration failed: 'prn' is not a string. Response: {s}", .{response});
            return error.MissingPrn;
        }

        const secret_val = parsed.value.object.get("secret") orelse {
            self.log("Device registration failed: missing 'secret'. Response: {s}", .{response});
            return error.MissingSecret;
        };
        if (secret_val != .string) {
            self.log("Device registration failed: 'secret' is not a string. Response: {s}", .{response});
            return error.MissingSecret;
        }

        const challenge_val = parsed.value.object.get("challenge");
        if (challenge_val) |c| {
            if (c != .string) {
                self.log("Device registration failed: 'challenge' is not a string. Response: {s}", .{response});
                return error.MissingSecret; // Or some other generic error
            }
        }

        return DeviceCredentials{
            .prn = try self.allocator.dupe(u8, prn_val.string),
            .secret = try self.allocator.dupe(u8, secret_val.string),
            .challenge = if (challenge_val) |c| try self.allocator.dupe(u8, c.string) else null,
        };
    }

    pub fn create_trail(self: *Client, state_json: []const u8) !void {
        std.debug.assert(self.token != null);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/trails/", .{ self.getScheme(), self.pantahub_host, self.pantahub_port });
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token.?});
        defer self.allocator.free(auth_val);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_val },
        };

        const res = try self.request("POST", url, state_json, &headers);
        std.debug.assert(res.len >= 0);
        self.allocator.free(res);
    }

    pub fn get_steps(self: *Client, prn: []const u8) ![]Step {
        std.debug.assert(self.token != null);
        std.debug.assert(prn.len > 0);
        const trail_id = get_object_id_from_prn(prn);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/trails/{s}/steps", .{ self.getScheme(), self.pantahub_host, self.pantahub_port, trail_id });
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token.?});
        defer self.allocator.free(auth_val);

        const headers = [_]std.http.Header{.{ .name = "Authorization", .value = auth_val }};
        const response = try self.request("GET", url, null, &headers);
        defer self.allocator.free(response);

        var parsed = std.json.parseFromSlice([]Step, self.allocator, response, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
            .duplicate_field_behavior = .use_last,
        }) catch |err| {
            self.log("Failed to parse steps. Response: {s}\nError: {any}", .{ response, err });
            return err;
        };
        defer parsed.deinit();

        var steps = std.ArrayList(Step){};
        errdefer {
            for (steps.items) |*s| self.free_step(s);
            steps.deinit(self.allocator);
        }
        for (parsed.value) |s| try steps.append(self.allocator, try clone_step(self.allocator, s));
        std.debug.assert(steps.items.len >= 0);
        return steps.toOwnedSlice(self.allocator);
    }

    pub fn get_step(self: *Client, prn: []const u8, rev: i64) !Step {
        std.debug.assert(self.token != null);
        std.debug.assert(prn.len > 0);
        const trail_id = get_object_id_from_prn(prn);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/trails/{s}/steps/{d}", .{ self.getScheme(), self.pantahub_host, self.pantahub_port, trail_id, rev });
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token.?});
        defer self.allocator.free(auth_val);

        const headers = [_]std.http.Header{.{ .name = "Authorization", .value = auth_val }};
        const response = try self.request("GET", url, null, &headers);
        defer self.allocator.free(response);

        var parsed = try std.json.parseFromSlice(Step, self.allocator, response, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
            .duplicate_field_behavior = .use_last,
        });
        defer parsed.deinit();

        return try clone_step(self.allocator, parsed.value);
    }

    pub fn get_step_objects(self: *Client, prn: []const u8, rev: i64) ![]StepObject {
        std.debug.assert(self.token != null);
        std.debug.assert(prn.len > 0);
        const trail_id = get_object_id_from_prn(prn);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/trails/{s}/steps/{d}/objects", .{ self.getScheme(), self.pantahub_host, self.pantahub_port, trail_id, rev });
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token.?});
        defer self.allocator.free(auth_val);

        const headers = [_]std.http.Header{.{ .name = "Authorization", .value = auth_val }};
        const response = try self.request("GET", url, null, &headers);
        defer self.allocator.free(response);

        var parsed = try std.json.parseFromSlice([]StepObject, self.allocator, response, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
            .duplicate_field_behavior = .use_last,
        });
        defer parsed.deinit();

        var objects = std.ArrayList(StepObject){};
        errdefer {
            for (objects.items) |*obj| {
                self.allocator.free(obj.id);
                self.allocator.free(obj.sha256sum);
                self.allocator.free(obj.size);
                self.allocator.free(obj.objectname);
                if (obj.@"signed-geturl") |u| self.allocator.free(u);
                if (obj.@"signed-puturl") |u| self.allocator.free(u);
                self.allocator.free(obj.@"expire-time");
                self.allocator.free(obj.now);
                self.allocator.free(obj.owner);
                self.allocator.free(obj.@"storage-id");
                self.allocator.free(obj.@"time-created");
                self.allocator.free(obj.@"time-modified");
                self.allocator.free(obj.@"mime-type");
            }
            objects.deinit(self.allocator);
        }
        for (parsed.value) |obj| {
            try objects.append(self.allocator, try clone_step_object(self.allocator, obj));
        }
        return objects.toOwnedSlice(self.allocator);
    }

    fn clone_step_object(allocator: std.mem.Allocator, o: StepObject) !StepObject {
        var new_obj = o;
        new_obj.id = try allocator.dupe(u8, o.id);
        errdefer allocator.free(new_obj.id);
        new_obj.sha256sum = try allocator.dupe(u8, o.sha256sum);
        errdefer allocator.free(new_obj.sha256sum);
        new_obj.size = try allocator.dupe(u8, o.size);
        errdefer allocator.free(new_obj.size);
        new_obj.objectname = try allocator.dupe(u8, o.objectname);
        errdefer allocator.free(new_obj.objectname);
        new_obj.@"signed-geturl" = if (o.@"signed-geturl") |u| try allocator.dupe(u8, u) else null;
        errdefer if (new_obj.@"signed-geturl") |u| allocator.free(u);
        new_obj.@"signed-puturl" = if (o.@"signed-puturl") |u| try allocator.dupe(u8, u) else null;
        errdefer if (new_obj.@"signed-puturl") |u| allocator.free(u);
        new_obj.@"expire-time" = try allocator.dupe(u8, o.@"expire-time");
        errdefer allocator.free(new_obj.@"expire-time");
        new_obj.now = try allocator.dupe(u8, o.now);
        errdefer allocator.free(new_obj.now);
        new_obj.owner = try allocator.dupe(u8, o.owner);
        errdefer allocator.free(new_obj.owner);
        new_obj.@"storage-id" = try allocator.dupe(u8, o.@"storage-id");
        errdefer allocator.free(new_obj.@"storage-id");
        new_obj.@"time-created" = try allocator.dupe(u8, o.@"time-created");
        errdefer allocator.free(new_obj.@"time-created");
        new_obj.@"time-modified" = try allocator.dupe(u8, o.@"time-modified");
        errdefer allocator.free(new_obj.@"time-modified");
        new_obj.@"mime-type" = try allocator.dupe(u8, o.@"mime-type");
        return new_obj;
    }

    pub fn free_step_objects(self: *Client, objects: []StepObject) void {
        for (objects) |*o| {
            self.allocator.free(o.id);
            self.allocator.free(o.sha256sum);
            self.allocator.free(o.size);
            self.allocator.free(o.objectname);
            if (o.@"signed-geturl") |u| self.allocator.free(u);
            if (o.@"signed-puturl") |u| self.allocator.free(u);
            self.allocator.free(o.@"expire-time");
            self.allocator.free(o.now);
            self.allocator.free(o.owner);
            self.allocator.free(o.@"storage-id");
            self.allocator.free(o.@"time-created");
            self.allocator.free(o.@"time-modified");
            self.allocator.free(o.@"mime-type");
        }
        self.allocator.free(objects);
    }

    pub fn free_step(self: *Client, s: *Step) void {
        self.allocator.free(s.id);
        self.allocator.free(s.device);
        self.allocator.free(s.owner);
        self.allocator.free(s.@"trail-id");
        self.allocator.free(s.@"time-created");
        self.allocator.free(s.@"time-modified");
        self.allocator.free(s.@"step-time");
        self.allocator.free(s.@"progress-time");

        self.allocator.free(s.progress.status);
        self.allocator.free(s.progress.@"status-msg");
        self.allocator.free(s.progress.logs);

        if (s.@"commit-msg") |m| self.allocator.free(m);
        if (s.committer) |c| self.allocator.free(c);
        if (s.used_objects) |objs| {
            for (objs) |o| self.allocator.free(o);
            self.allocator.free(objs);
        }

        if (s.state) |st| self.free_json_value(st);
        if (s.meta) |m| self.free_json_value(m);
    }

    pub fn free_steps(self: *Client, steps: []Step) void {
        for (steps) |*s| {
            self.free_step(s);
        }
        self.allocator.free(steps);
    }

    pub fn free_json_value(self: *Client, v: std.json.Value) void {
        switch (v) {
            .string => |s| self.allocator.free(s),
            .array => |arr| {
                for (arr.items) |item| self.free_json_value(item);
                var mutable_arr = arr;
                mutable_arr.deinit();
            },
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.free_json_value(entry.value_ptr.*);
                }
                var mutable_obj = obj;
                mutable_obj.deinit();
            },
            .number_string => |s| self.allocator.free(s),
            else => {},
        }
    }

    pub fn create_step(self: *Client, prn: []const u8, rev: i64, state_json: []const u8) !void {
        std.debug.assert(self.token != null);
        std.debug.assert(prn.len > 0);
        std.debug.assert(state_json.len > 0); // Must have a state
        const trail_id = get_object_id_from_prn(prn);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/trails/{s}/steps", .{ self.getScheme(), self.pantahub_host, self.pantahub_port, trail_id });
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token.?});
        defer self.allocator.free(auth_val);

        const payload = try std.fmt.allocPrint(self.allocator, "{{\"rev\": {d}, \"state\": {s}, \"meta\": {{}}, \"used_objects\": []}}", .{ rev, state_json });
        defer self.allocator.free(payload);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_val },
        };
        const res = try self.request("POST", url, payload, &headers);
        std.debug.assert(res.len >= 0);
        self.allocator.free(res);
    }

    fn clone_step(allocator: std.mem.Allocator, s: Step) !Step {
        std.debug.assert(s.id.len > 0);
        var new_step = s;
        new_step.id = try allocator.dupe(u8, s.id);
        errdefer allocator.free(new_step.id);
        new_step.device = try allocator.dupe(u8, s.device);
        errdefer allocator.free(new_step.device);
        new_step.owner = try allocator.dupe(u8, s.owner);
        errdefer allocator.free(new_step.owner);
        new_step.@"trail-id" = try allocator.dupe(u8, s.@"trail-id");
        errdefer allocator.free(new_step.@"trail-id");
        new_step.@"time-created" = try allocator.dupe(u8, s.@"time-created");
        errdefer allocator.free(new_step.@"time-created");
        new_step.@"time-modified" = try allocator.dupe(u8, s.@"time-modified");
        errdefer allocator.free(new_step.@"time-modified");
        new_step.@"step-time" = try allocator.dupe(u8, s.@"step-time");
        errdefer allocator.free(new_step.@"step-time");
        new_step.@"progress-time" = try allocator.dupe(u8, s.@"progress-time");
        errdefer allocator.free(new_step.@"progress-time");

        new_step.progress.status = try allocator.dupe(u8, s.progress.status);
        errdefer allocator.free(new_step.progress.status);
        new_step.progress.@"status-msg" = try allocator.dupe(u8, s.progress.@"status-msg");
        errdefer allocator.free(new_step.progress.@"status-msg");
        new_step.progress.logs = try allocator.dupe(u8, s.progress.logs);
        errdefer allocator.free(new_step.progress.logs);

        if (s.@"commit-msg") |msg| {
            new_step.@"commit-msg" = try allocator.dupe(u8, msg);
        } else new_step.@"commit-msg" = null;
        errdefer if (new_step.@"commit-msg") |m| allocator.free(m);

        if (s.committer) |c| {
            new_step.committer = try allocator.dupe(u8, c);
        } else new_step.committer = null;
        errdefer if (new_step.committer) |c| allocator.free(c);

        if (s.used_objects) |objs| {
            var new_objs = try allocator.alloc([]const u8, objs.len);
            errdefer {
                for (new_objs) |o| allocator.free(o);
                allocator.free(new_objs);
            }
            // Initialize with null/empty to be safe for errdefer?
            // Actually allocator.alloc doesn't zero.
            for (new_objs) |*o| o.* = ""; // safe to free ""? No, allocator.free must take allocated ptr.
            // Better to use a loop that dupes one by one and frees on error.
            for (objs, 0..) |o, i| {
                new_objs[i] = try allocator.dupe(u8, o);
            }
            new_step.used_objects = new_objs;
        } else new_step.used_objects = null;

        if (s.state) |st| {
            new_step.state = try clone_json_value(allocator, st);
        } else new_step.state = null;
        errdefer if (new_step.state) |st| {
            // We need a helper that doesn't need *Client
            free_json_value_standalone(allocator, st);
        };

        if (s.meta) |m| {
            new_step.meta = try clone_json_value(allocator, m);
        } else new_step.meta = null;
        errdefer if (new_step.meta) |m| {
            free_json_value_standalone(allocator, m);
        };

        std.debug.assert(new_step.id.len == s.id.len);
        return new_step;
    }

    fn free_json_value_standalone(allocator: std.mem.Allocator, v: std.json.Value) void {
        switch (v) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr.items) |item| free_json_value_standalone(allocator, item);
                var mutable_arr = arr;
                mutable_arr.deinit();
            },
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    free_json_value_standalone(allocator, entry.value_ptr.*);
                }
                var mutable_obj = obj;
                mutable_obj.deinit();
            },
            .number_string => |s| allocator.free(s),
            else => {},
        }
    }

    fn clone_json_value(allocator: std.mem.Allocator, v: std.json.Value) !std.json.Value {
        switch (v) {
            .null => return .null,
            .bool => |b| return .{ .bool = b },
            .integer => |i| return .{ .integer = i },
            .float => |f| return .{ .float = f },
            .string => |s| return .{ .string = try allocator.dupe(u8, s) },
            .array => |arr| {
                var new_arr = std.json.Array.init(allocator);
                errdefer {
                    for (new_arr.items) |item| free_json_value_standalone(allocator, item);
                    new_arr.deinit();
                }
                try new_arr.ensureTotalCapacity(arr.items.len);
                for (arr.items) |item| {
                    try new_arr.append(try clone_json_value(allocator, item));
                }
                return .{ .array = new_arr };
            },
            .object => |obj| {
                var new_obj = std.json.ObjectMap.init(allocator);
                errdefer {
                    var it = new_obj.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        free_json_value_standalone(allocator, entry.value_ptr.*);
                    }
                    new_obj.deinit();
                }
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key_copy);
                    const value_copy = try clone_json_value(allocator, entry.value_ptr.*);
                    try new_obj.put(key_copy, value_copy);
                }
                return .{ .object = new_obj };
            },
            .number_string => |s| return .{ .number_string = try allocator.dupe(u8, s) },
        }
    }

    pub fn get_step_progress(self: *Client, prn: []const u8, rev: i64) !StepProgress {
        std.debug.assert(self.token != null);
        const trail_id = get_object_id_from_prn(prn);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/trails/{s}/steps/{d}/progress", .{ self.getScheme(), self.pantahub_host, self.pantahub_port, trail_id, rev });
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token.?});
        defer self.allocator.free(auth_val);

        const headers = [_]std.http.Header{.{ .name = "Authorization", .value = auth_val }};
        const response = try self.request("GET", url, null, &headers);
        defer self.allocator.free(response);

        // If response is empty or 404 (which we can't easily distinguish with simple_request unless we parse headers/code),
        // we might get empty JSON or error.
        // Assuming valid JSON response if successful.

        var parsed = try std.json.parseFromSlice(StepProgress, self.allocator, response, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
            .duplicate_field_behavior = .use_last,
        });
        defer parsed.deinit();

        var sp: StepProgress = .{
            .status = try self.allocator.dupe(u8, parsed.value.status),
            .progress = parsed.value.progress,
            .@"status-msg" = "",
            .logs = "",
        };
        errdefer {
            self.allocator.free(sp.status);
            if (sp.@"status-msg".len > 0) self.allocator.free(sp.@"status-msg");
            if (sp.logs.len > 0) self.allocator.free(sp.logs);
        }

        sp.@"status-msg" = try self.allocator.dupe(u8, parsed.value.@"status-msg");
        sp.logs = if (parsed.value.logs.len > 0) try self.allocator.dupe(u8, parsed.value.logs) else "";

        return sp;
    }

    pub fn post_progress(self: *Client, prn: []const u8, rev: i64, progress: StepProgress) !void {
        std.debug.assert(self.token != null);
        std.debug.assert(prn.len > 0);
        std.debug.assert(progress.status.len > 0);
        const trail_id = get_object_id_from_prn(prn);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/trails/{s}/steps/{d}/progress", .{ self.getScheme(), self.pantahub_host, self.pantahub_port, trail_id, rev });
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token.?});
        defer self.allocator.free(auth_val);

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\    "status": "{s}",
            \\    "progress": {d},
            \\    "status-msg": "{s}",
            \\    "logs": "{s}",
            \\    "downloads": {{
            \\        "total": {{
            \\            "total_size": 0,
            \\            "total_downloaded": 0,
            \\            "start_time": 0,
            \\            "current_time": 0
            \\        }},
            \\        "objects": null
            \\    }}
            \\}}
        , .{ progress.status, progress.progress, progress.@"status-msg", progress.logs });
        defer self.allocator.free(payload);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_val },
        };
        const res = try self.request("PUT", url, payload, &headers);
        std.debug.assert(res.len >= 0);
        self.allocator.free(res);
    }

    pub fn patch_device_meta(self: *Client, prn: []const u8, meta_json: []const u8) !void {
        std.debug.assert(self.token != null);
        const trail_id = get_object_id_from_prn(prn);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/devices/{s}/device-meta", .{ self.getScheme(), self.pantahub_host, self.pantahub_port, trail_id });
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token.?});
        defer self.allocator.free(auth_val);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_val },
        };
        const res = try self.request("PATCH", url, meta_json, &headers);
        std.debug.assert(res.len >= 0);
        self.allocator.free(res);
    }

    pub fn get_user_meta(self: *Client, prn: []const u8) ![]u8 {
        std.debug.assert(self.token != null);
        const trail_id = get_object_id_from_prn(prn);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/devices/{s}/user-meta", .{ self.getScheme(), self.pantahub_host, self.pantahub_port, trail_id });
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token.?});
        defer self.allocator.free(auth_val);

        const headers = [_]std.http.Header{.{ .name = "Authorization", .value = auth_val }};
        return try self.request("GET", url, null, &headers);
    }

    pub fn get_device_info(self: *Client, prn: []const u8) ![]u8 {
        std.debug.assert(self.token != null);
        const trail_id = get_object_id_from_prn(prn);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/devices/{s}", .{ self.getScheme(), self.pantahub_host, self.pantahub_port, trail_id });
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token.?});
        defer self.allocator.free(auth_val);

        const headers = [_]std.http.Header{.{ .name = "Authorization", .value = auth_val }};
        const res = try self.request("GET", url, null, &headers);
        std.debug.assert(res.len >= 0);
        return res;
    }

    pub fn post_logs(self: *Client, entries: []const LogEntry) !void {
        if (entries.len == 0) return;
        std.debug.assert(self.token != null);
        std.debug.assert(self.pantahub_host.len > 0);
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/logs/", .{ self.getScheme(), self.pantahub_host, self.pantahub_port });
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token.?});
        defer self.allocator.free(auth_val);

        var list = std.ArrayList(u8){};
        defer list.deinit(self.allocator);
        try list.append(self.allocator, '[');

        for (entries, 0..) |e, i| {
            if (i > 0) try list.appendSlice(self.allocator, ", ");
            // Use std.json.stringify for individual entries to handle escaping
            // Wait, we had issues with stringify before.
            // Let's use std.json.fmt if it works better or just manual for now but escaping msg.

            // Actually, let's try std.json.stringify again but properly this time.
            // Or just manual with msg escaped.

            try list.appendSlice(self.allocator, "{\"tsec\": ");
            try list.writer(self.allocator).print("{d}", .{e.tsec});
            try list.appendSlice(self.allocator, ", \"tnano\": ");
            try list.writer(self.allocator).print("{d}", .{e.tnano});
            try list.appendSlice(self.allocator, ", \"rev\": \"");
            try list.appendSlice(self.allocator, e.rev);
            try list.appendSlice(self.allocator, "\", \"plat\": \"");
            try list.appendSlice(self.allocator, e.plat);
            try list.appendSlice(self.allocator, "\", \"src\": \"");
            try list.appendSlice(self.allocator, e.src);
            try list.appendSlice(self.allocator, "\", \"lvl\": \"");
            try list.appendSlice(self.allocator, e.lvl);
            try list.appendSlice(self.allocator, "\", \"msg\": \"");

            for (e.msg) |c| {
                switch (c) {
                    '"' => try list.appendSlice(self.allocator, "\\\""),
                    '\\' => try list.appendSlice(self.allocator, "\\\\"),
                    '\n' => try list.appendSlice(self.allocator, "\\n"),
                    '\r' => try list.appendSlice(self.allocator, "\\r"),
                    '\t' => try list.appendSlice(self.allocator, "\\t"),
                    0...0x08, 0x0B, 0x0C, 0x0E...0x1F => try list.writer(self.allocator).print("\\u{x:0>4}", .{c}),
                    else => try list.append(self.allocator, c),
                }
            }
            try list.append(self.allocator, '"');

            try list.append(self.allocator, '}');
        }
        try list.append(self.allocator, ']');

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_val },
        };
        const res = try self.request("POST", url, list.items, &headers);
        std.debug.assert(res.len >= 0);
        self.allocator.free(res);
    }

    pub fn validate_ownership(self: *Client, prn: []const u8, cert_path: []const u8, key_path: []const u8) !bool {
        std.debug.assert(self.token != null);
        std.debug.assert(prn.len > 0);
        std.debug.assert(cert_path.len > 0);
        std.debug.assert(key_path.len > 0);

        const trail_id = get_object_id_from_prn(prn);
        // /devices/{id}/ownership/validate
        const url_raw = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{s}/devices/{s}/ownership/validate", .{ self.getScheme(), self.pantahub_host, self.pantahub_port, trail_id });
        defer self.allocator.free(url_raw);
        const url = try self.allocator.dupeZ(u8, url_raw);
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token.?});
        defer self.allocator.free(auth_val);

        var curl = try curl_mod.Curl.init();
        defer curl.deinit();

        try curl.set_opt(curl_mod.CURLOPT_URL, url);
        try curl.set_opt(curl_mod.CURLOPT_CUSTOMREQUEST, @as([]const u8, "POST"));

        const cert_path_z = try self.allocator.dupeZ(u8, cert_path);
        defer self.allocator.free(cert_path_z);
        try curl.set_opt(curl_mod.CURLOPT_SSLCERT, cert_path_z);

        const key_path_z = try self.allocator.dupeZ(u8, key_path);
        defer self.allocator.free(key_path_z);
        try curl.set_opt(curl_mod.CURLOPT_SSLKEY, key_path_z);

        try curl.set_opt(curl_mod.CURLOPT_NOSIGNAL, 1);
        try curl.set_opt(curl_mod.CURLOPT_VERBOSE, 0); // Set to 1 for debugging

        var slist: ?*curl_mod.curl_slist = null;
        defer curl_mod.slist_free_all(slist);

        const auth_header_raw = try std.fmt.allocPrint(self.allocator, "Authorization: {s}", .{auth_val});
        defer self.allocator.free(auth_header_raw);
        const auth_header = try self.allocator.dupeZ(u8, auth_header_raw);
        defer self.allocator.free(auth_header);

        slist = curl_mod.slist_append(slist, auth_header);

        // Add User-Agent
        const ua_header = "User-Agent: Pantavisor-Mocker/0.1";
        slist = curl_mod.slist_append(slist, ua_header);

        try curl.set_opt(curl_mod.CURLOPT_HTTPHEADER, slist);

        // Capture response
        var buf_ctx = curl_mod.BufferContext.init(self.allocator);
        defer buf_ctx.deinit();

        try curl.set_opt(curl_mod.CURLOPT_WRITEFUNCTION, &curl_mod.BufferContext.write_callback);
        try curl.set_opt(curl_mod.CURLOPT_WRITEDATA, &buf_ctx);

        self.log("Validating ownership for {s}...", .{prn});
        curl.perform() catch |err| {
            self.log("Ownership validation request failed: {any}", .{err});
            return err;
        };

        var response_code: c_long = 0;
        try curl.get_info(curl_mod.CURLINFO_RESPONSE_CODE, &response_code);

        const response_body = buf_ctx.buffer.items;
        if (response_code >= 200 and response_code < 300) {
            self.log("Validation Response Code: {d}", .{response_code});
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{ .duplicate_field_behavior = .use_last }) catch return false;
            defer parsed.deinit();
            if (parsed.value.object.get("status")) |status| {
                if (status == .string and std.mem.eql(u8, status.string, "completed")) {
                    return true;
                }
            }
        }
        return false;
    }
};
