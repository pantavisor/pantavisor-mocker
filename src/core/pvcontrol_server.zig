const std = @import("std");
pub const http_parser = @import("http_parser.zig");
const local_store = @import("local_store.zig");
const config = @import("config.zig");
const constants = @import("constants.zig");
const logger = @import("logger.zig");
const validation = @import("validation.zig");

const ContainerInfo = struct {
    name: []const u8,
    group: []const u8,
    status: []const u8,
    status_goal: []const u8,
    restart_policy: []const u8,
    roles: []const []const u8,
};

const GroupInfo = struct {
    name: []const u8,
    status_goal: []const u8,
    restart_policy: []const u8,
    status: []const u8,
};

const ObjectInfo = struct {
    sha256: []const u8,
    size: []const u8,
};

const StepProgress = struct {
    status: []const u8,
    @"status-msg": []const u8,
    progress: i64,
    data: []const u8,
};

const StepInfo = struct {
    name: []const u8,
    date: []const u8,
    commitmsg: []const u8,
    progress: StepProgress,
};

const ConfigEntry = struct {
    key: []const u8,
    value: []const u8,
    modified: []const u8,
};

pub const PvControlContext = struct {
    allocator: std.mem.Allocator,
    storage_path: []const u8,
    quit_flag: *std.atomic.Value(bool),
    is_debug: bool,
    logger: ?*logger.Logger = null,
};

pub const PvControlServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    context: PvControlContext,
    server_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, storage_path: []const u8, quit_flag: *std.atomic.Value(bool), is_debug: bool, log: ?*logger.Logger) !PvControlServer {
        const socket_path = try std.fs.path.join(allocator, &[_][]const u8{ storage_path, "pantavisor", "pv-ctrl" });
        errdefer allocator.free(socket_path);

        return PvControlServer{
            .allocator = allocator,
            .socket_path = socket_path,
            .context = .{
                .allocator = allocator,
                .storage_path = try allocator.dupe(u8, storage_path),
                .quit_flag = quit_flag,
                .is_debug = is_debug,
                .logger = log,
            },
        };
    }

    pub fn deinit(self: *PvControlServer) void {
        self.context.quit_flag.store(true, .release);
        // Wake up server from accept()
        const dummy_conn = std.net.connectUnixSocket(self.socket_path) catch null;
        if (dummy_conn) |c| c.close();

        if (self.server_thread) |t| {
            t.join();
            self.server_thread = null;
        }
        std.fs.cwd().deleteFile(self.socket_path) catch {};
        self.allocator.free(self.socket_path);
        self.allocator.free(self.context.storage_path);
    }

    pub fn start(self: *PvControlServer) !void {
        self.server_thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *PvControlServer) !void {
        std.fs.cwd().deleteFile(self.socket_path) catch {};

        // Ensure directory exists
        if (std.fs.path.dirname(self.socket_path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        const address = try std.net.Address.initUnix(self.socket_path);
        var server = try address.listen(.{ .reuse_address = true });
        defer server.deinit();

        while (!self.context.quit_flag.load(.acquire)) {
            const conn = server.accept() catch {
                continue;
            };

            const thread = try std.Thread.spawn(.{}, handleConnectionWrapper, .{ self, conn.stream });
            thread.detach();
        }
    }

    fn handleConnectionWrapper(self: *PvControlServer, stream: std.net.Stream) void {
        handleConnection(self, stream) catch |err| {
            std.log.err("PvControl connection handler error: {}", .{err});
        };
    }

    fn handleConnection(self: *PvControlServer, stream: std.net.Stream) !void {
        defer stream.close();

        // Read headers first
        var buf: [65536]u8 = undefined;
        var total_read: usize = 0;
        var headers_end: ?usize = null;

        // Read until we find the end of headers (\r\n\r\n)
        while (total_read < buf.len) {
            const n = try stream.read(buf[total_read..]);
            if (n == 0) return; // Connection closed
            total_read += n;

            // Check for end of headers
            if (total_read >= 4) {
                const data = buf[0..total_read];
                if (std.mem.indexOf(u8, data, "\r\n\r\n")) |end| {
                    headers_end = end + 4;
                    break;
                }
            }
        }

        if (headers_end == null) return; // Headers too large or malformed

        // Parse Content-Length if present
        var content_length: ?usize = null;
        const headers_data = buf[0..headers_end.?];
        if (std.mem.indexOf(u8, headers_data, "Content-Length:")) |cl_start| {
            const after_cl = headers_data[cl_start + 15 ..];
            if (std.mem.indexOf(u8, after_cl, "\r\n")) |cl_end| {
                const cl_str = std.mem.trim(u8, after_cl[0..cl_end], " \t");
                content_length = std.fmt.parseInt(usize, cl_str, 10) catch null;
            }
        }

        // Read body if Content-Length is specified
        if (content_length) |cl| {
            const body_start = headers_end.?;
            if (cl > buf.len - body_start) return; // Body too large
            var body_received = total_read - body_start;

            while (body_received < cl) {
                const n = try stream.read(buf[total_read..]);
                if (n == 0) return; // Connection closed before full body
                total_read += n;
                body_received += n;
            }
        }

        var request = http_parser.parseRequest(self.allocator, buf[0..total_read]) catch {
            var resp = http_parser.HttpResponse{
                .status_code = 400,
                .status_text = "Bad Request",
                .content_type = "text/plain",
                .body = try self.allocator.dupe(u8, "Malformed HTTP request"),
            };
            defer resp.deinit(self.allocator);
            const bytes = try resp.serialize(self.allocator);
            defer self.allocator.free(bytes);
            _ = try stream.write(bytes);
            return;
        };
        defer request.deinit(self.allocator);

        const response = try self.dispatch(request);
        var res = response;
        defer res.deinit(self.allocator);
        const response_bytes = try res.serialize(self.allocator);
        defer self.allocator.free(response_bytes);
        _ = try stream.write(response_bytes);
    }

    fn dispatch(self: *PvControlServer, req: http_parser.HttpRequest) !http_parser.HttpResponse {
        if (std.mem.eql(u8, req.path, "/containers") and req.method == .GET) {
            return self.handleGetContainers();
        } else if (std.mem.eql(u8, req.path, "/groups") and req.method == .GET) {
            return self.handleGetGroups();
        } else if (std.mem.eql(u8, req.path, "/signal") and req.method == .POST) {
            return self.handleSignal(req);
        } else if (std.mem.eql(u8, req.path, "/commands") and req.method == .POST) {
            return self.handleCommands(req);
        } else if (std.mem.startsWith(u8, req.path, "/device-meta")) {
            return self.handleDeviceMeta(req);
        } else if (std.mem.startsWith(u8, req.path, "/user-meta")) {
            return self.handleUserMeta(req);
        } else if (std.mem.eql(u8, req.path, "/buildinfo") and req.method == .GET) {
            return self.handleBuildInfo();
        } else if (std.mem.startsWith(u8, req.path, "/objects")) {
            return self.handleObjects(req);
        } else if (std.mem.startsWith(u8, req.path, "/steps")) {
            return self.handleSteps(req);
        } else if (std.mem.eql(u8, req.path, "/config") and req.method == .GET) {
            return self.handleGetConfig();
        } else if (std.mem.eql(u8, req.path, "/config2") and req.method == .GET) {
            return self.handleGetConfig2();
        }

        return http_parser.HttpResponse{
            .status_code = 404,
            .status_text = "Not Found",
            .content_type = "text/plain",
            .body = try self.allocator.dupe(u8, "Not Found"),
        };
    }

    fn handleGetContainers(self: *PvControlServer) !http_parser.HttpResponse {
        const state = self.readStateJson() catch |err| {
            if (self.context.logger) |l| l.log("Error reading state.json: {any}", .{err});
            return jsonResponse(self.allocator, 200, "[]");
        };
        defer self.allocator.free(state);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, state, .{});
        defer parsed.deinit();

        var list = std.ArrayList(ContainerInfo){};
        defer {
            for (list.items) |item| {
                self.allocator.free(item.name);
                self.allocator.free(item.group);
                self.allocator.free(item.status);
                self.allocator.free(item.status_goal);
                self.allocator.free(item.restart_policy);
                for (item.roles) |role| self.allocator.free(role);
                self.allocator.free(item.roles);
            }
            list.deinit(self.allocator);
        }

        if (parsed.value == .object) {
            if (parsed.value.object.get("config")) |config_val| {
                if (config_val == .object) {
                    if (config_val.object.get("components")) |components_val| {
                        if (components_val == .object) {
                            var it = components_val.object.iterator();
                            while (it.next()) |entry| {
                                var item = ContainerInfo{
                                    .name = try self.allocator.dupe(u8, entry.key_ptr.*),
                                    .group = try self.allocator.dupe(u8, "root"),
                                    .status = try self.allocator.dupe(u8, "STARTED"),
                                    .status_goal = try self.allocator.dupe(u8, "STARTED"),
                                    .restart_policy = try self.allocator.dupe(u8, "system"),
                                    .roles = &[_][]const u8{},
                                };

                                if (entry.value_ptr.* == .object) {
                                    const comp_obj = entry.value_ptr.*.object;
                                    if (comp_obj.get("group")) |g| {
                                        if (g == .string) {
                                            self.allocator.free(item.group);
                                            item.group = try self.allocator.dupe(u8, g.string);
                                        }
                                    }
                                    if (comp_obj.get("restart_policy")) |rp| {
                                        if (rp == .string) {
                                            self.allocator.free(item.restart_policy);
                                            item.restart_policy = try self.allocator.dupe(u8, rp.string);
                                        }
                                    }
                                    if (comp_obj.get("roles")) |r| {
                                        if (r == .array) {
                                            var roles = std.ArrayList([]const u8){};
                                            for (r.array.items) |role_val| {
                                                if (role_val == .string) {
                                                    try roles.append(self.allocator, try self.allocator.dupe(u8, role_val.string));
                                                }
                                            }
                                            item.roles = try roles.toOwnedSlice(self.allocator);
                                        }
                                    }
                                }
                                try list.append(self.allocator, item);
                            }
                        }
                    }
                }
            }
        }

        var out = std.ArrayList(u8){};
        defer out.deinit(self.allocator);
        try out.writer(self.allocator).print("{f}", .{std.json.fmt(list.items, .{})});
        return jsonResponse(self.allocator, 200, out.items);
    }

    fn handleGetGroups(self: *PvControlServer) !http_parser.HttpResponse {
        const state = self.readStateJson() catch |err| {
            if (self.context.logger) |l| l.log("Error reading state.json: {any}", .{err});
            return jsonResponse(self.allocator, 200, "[]");
        };
        defer self.allocator.free(state);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, state, .{});
        defer parsed.deinit();

        var groups_map = std.StringArrayHashMap(void).init(self.allocator);
        defer groups_map.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("config")) |config_val| {
                if (config_val == .object) {
                    if (config_val.object.get("components")) |components_val| {
                        if (components_val == .object) {
                            var it = components_val.object.iterator();
                            while (it.next()) |entry| {
                                if (entry.value_ptr.* == .object) {
                                    if (entry.value_ptr.*.object.get("group")) |group_val| {
                                        if (group_val == .string) {
                                            try groups_map.put(group_val.string, {});
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        var list = std.ArrayList(GroupInfo){};
        defer {
            for (list.items) |item| {
                self.allocator.free(item.name);
                self.allocator.free(item.status_goal);
                self.allocator.free(item.restart_policy);
                self.allocator.free(item.status);
            }
            list.deinit(self.allocator);
        }

        var it = groups_map.iterator();
        while (it.next()) |entry| {
            try list.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, entry.key_ptr.*),
                .status_goal = try self.allocator.dupe(u8, "MOUNTED"),
                .restart_policy = try self.allocator.dupe(u8, "system"),
                .status = try self.allocator.dupe(u8, "READY"),
            });
        }

        var out = std.ArrayList(u8){};
        defer out.deinit(self.allocator);
        try out.writer(self.allocator).print("{f}", .{std.json.fmt(list.items, .{})});
        return jsonResponse(self.allocator, 200, out.items);
    }

    fn readStateJson(self: *PvControlServer) ![]u8 {
        var store = try local_store.LocalStore.init(self.allocator, self.context.storage_path, null, false);
        defer store.deinit();

        const revs = try store.get_revisions();
        defer self.allocator.free(revs.rev);
        defer self.allocator.free(revs.try_rev);

        const state_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.context.storage_path, "trails", revs.try_rev, ".pvr", "json" });
        defer self.allocator.free(state_path);

        const file = try std.fs.cwd().openFile(state_path, .{});
        defer file.close();

        return try file.readToEndAlloc(self.allocator, 1024 * 1024);
    }

    fn handleSignal(self: *PvControlServer, req: http_parser.HttpRequest) !http_parser.HttpResponse {
        if (req.body) |body| {
            if (self.context.logger) |l| l.log("PVCONTROL SIGNAL RECEIVED: {s}", .{body});
        }
        return jsonResponse(self.allocator, 200, "");
    }

    fn handleCommands(self: *PvControlServer, req: http_parser.HttpRequest) !http_parser.HttpResponse {
        if (req.body) |body| {
            if (self.context.logger) |l| l.log("PVCONTROL COMMAND RECEIVED: {s}", .{body});

            if (std.mem.containsAtLeast(u8, body, 1, "REBOOT_DEVICE") or std.mem.containsAtLeast(u8, body, 1, "POWEROFF_DEVICE")) {
                if (self.context.logger) |l| l.log("REBOOT/POWEROFF requested via pvcontrol. Signaling quit.", .{});
                self.context.quit_flag.store(true, .release);
            }
        }
        return jsonResponse(self.allocator, 200, "");
    }

    fn handleDeviceMeta(self: *PvControlServer, req: http_parser.HttpRequest) !http_parser.HttpResponse {
        const key = if (req.path.len > "/device-meta/".len) req.path["/device-meta/".len..] else "";
        if (key.len > 0) {
            validation.validate_file_path(key) catch {
                return http_parser.HttpResponse{
                    .status_code = 400,
                    .status_text = "Bad Request",
                    .content_type = "text/plain",
                    .body = try self.allocator.dupe(u8, "Invalid key"),
                };
            };
        }
        const meta_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ self.context.storage_path, "device-meta" });
        defer self.allocator.free(meta_dir);

        if (req.method == .GET) {
            if (key.len == 0) {
                // List all
                var dir = try std.fs.cwd().openDir(meta_dir, .{ .iterate = true });
                defer dir.close();
                var it = dir.iterate();
                var map = std.StringArrayHashMap(std.json.Value).init(self.allocator);
                defer {
                    var it_map = map.iterator();
                    while (it_map.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.allocator.free(entry.value_ptr.*.string);
                    }
                    map.deinit();
                }

                while (try it.next()) |entry| {
                    if (entry.kind == .file) {
                        const content = try dir.readFileAlloc(self.allocator, entry.name, 1024);
                        defer self.allocator.free(content);
                        try map.put(try self.allocator.dupe(u8, entry.name), .{ .string = try self.allocator.dupe(u8, content) });
                    }
                }

                var out = std.ArrayList(u8){};
                defer out.deinit(self.allocator);
                try out.writer(self.allocator).print("{f}", .{std.json.fmt(std.json.Value{ .object = map }, .{})});
                return jsonResponse(self.allocator, 200, out.items);
            }
        } else if (req.method == .PUT) {
            if (key.len > 0 and req.body != null) {
                const path = try std.fs.path.join(self.allocator, &[_][]const u8{ meta_dir, key });
                defer self.allocator.free(path);
                try std.fs.cwd().writeFile(.{ .sub_path = path, .data = req.body.? });
                return jsonResponse(self.allocator, 200, "{\"status\":\"ok\"}");
            }
        } else if (req.method == .DELETE) {
            if (key.len > 0) {
                const path = try std.fs.path.join(self.allocator, &[_][]const u8{ meta_dir, key });
                defer self.allocator.free(path);
                std.fs.cwd().deleteFile(path) catch {};
                return jsonResponse(self.allocator, 200, "{\"status\":\"ok\"}");
            }
        }

        return http_parser.HttpResponse{ .status_code = 400, .status_text = "Bad Request", .content_type = "text/plain", .body = try self.allocator.dupe(u8, "Bad Request") };
    }

    fn handleUserMeta(self: *PvControlServer, req: http_parser.HttpRequest) !http_parser.HttpResponse {
        const key = if (req.path.len > "/user-meta/".len) req.path["/user-meta/".len..] else "";
        if (key.len > 0) {
            validation.validate_file_path(key) catch {
                return http_parser.HttpResponse{
                    .status_code = 400,
                    .status_text = "Bad Request",
                    .content_type = "text/plain",
                    .body = try self.allocator.dupe(u8, "Invalid key"),
                };
            };
        }
        const meta_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ self.context.storage_path, "user-meta" });
        defer self.allocator.free(meta_dir);

        if (req.method == .GET) {
            if (key.len == 0) {
                // List all
                var dir = try std.fs.cwd().openDir(meta_dir, .{ .iterate = true });
                defer dir.close();
                var it = dir.iterate();
                var map = std.StringArrayHashMap(std.json.Value).init(self.allocator);
                defer {
                    var it_map = map.iterator();
                    while (it_map.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.allocator.free(entry.value_ptr.*.string);
                    }
                    map.deinit();
                }

                while (try it.next()) |entry| {
                    if (entry.kind == .file) {
                        const content = try dir.readFileAlloc(self.allocator, entry.name, 1024);
                        defer self.allocator.free(content);
                        try map.put(try self.allocator.dupe(u8, entry.name), .{ .string = try self.allocator.dupe(u8, content) });
                    }
                }

                var out = std.ArrayList(u8){};
                defer out.deinit(self.allocator);
                try out.writer(self.allocator).print("{f}", .{std.json.fmt(std.json.Value{ .object = map }, .{})});
                return jsonResponse(self.allocator, 200, out.items);
            }
        } else if (req.method == .PUT) {
            if (key.len > 0 and req.body != null) {
                const path = try std.fs.path.join(self.allocator, &[_][]const u8{ meta_dir, key });
                defer self.allocator.free(path);
                try std.fs.cwd().writeFile(.{ .sub_path = path, .data = req.body.? });
                return jsonResponse(self.allocator, 200, "{\"status\":\"ok\"}");
            }
        } else if (req.method == .DELETE) {
            if (key.len > 0) {
                const path = try std.fs.path.join(self.allocator, &[_][]const u8{ meta_dir, key });
                defer self.allocator.free(path);
                std.fs.cwd().deleteFile(path) catch {};
                return jsonResponse(self.allocator, 200, "{\"status\":\"ok\"}");
            }
        }

        return http_parser.HttpResponse{ .status_code = 400, .status_text = "Bad Request", .content_type = "text/plain", .body = try self.allocator.dupe(u8, "Bad Request") };
    }

    fn handleBuildInfo(self: *PvControlServer) !http_parser.HttpResponse {
        return jsonResponse(self.allocator, 200, "");
    }

    fn handleObjects(self: *PvControlServer, req: http_parser.HttpRequest) !http_parser.HttpResponse {
        const sha = if (req.path.len > "/objects/".len) req.path["/objects/".len..] else "";
        if (sha.len > 0) {
            validation.validate_sha256(sha) catch {
                return http_parser.HttpResponse{
                    .status_code = 400,
                    .status_text = "Bad Request",
                    .content_type = "text/plain",
                    .body = try self.allocator.dupe(u8, "Invalid SHA256"),
                };
            };
        }
        const objects_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ self.context.storage_path, "objects" });
        defer self.allocator.free(objects_dir);

        if (req.method == .GET) {
            if (sha.len == 0) {
                // List all
                var dir = try std.fs.cwd().openDir(objects_dir, .{ .iterate = true });
                defer dir.close();
                var it = dir.iterate();
                var list = std.ArrayList(ObjectInfo){};
                defer {
                    for (list.items) |item| {
                        self.allocator.free(item.sha256);
                        self.allocator.free(item.size);
                    }
                    list.deinit(self.allocator);
                }

                while (try it.next()) |entry| {
                    if (entry.kind == .file) {
                        const stat = dir.statFile(entry.name) catch continue;
                        var size_buf: [32]u8 = undefined;
                        const size_str = try std.fmt.bufPrint(&size_buf, "{d}", .{stat.size});
                        try list.append(self.allocator, .{
                            .sha256 = try self.allocator.dupe(u8, entry.name),
                            .size = try self.allocator.dupe(u8, size_str),
                        });
                    }
                }

                var out = std.ArrayList(u8){};
                defer out.deinit(self.allocator);
                try out.writer(self.allocator).print("{f}", .{std.json.fmt(list.items, .{})});
                return jsonResponse(self.allocator, 200, out.items);
            } else {
                // Get object
                const path = try std.fs.path.join(self.allocator, &[_][]const u8{ objects_dir, sha });
                defer self.allocator.free(path);
                const content = try std.fs.cwd().readFileAlloc(self.allocator, path, 100 * 1024 * 1024);
                // Note: potential memory issue for huge objects, but mocker should be fine.
                return http_parser.HttpResponse{
                    .status_code = 200,
                    .status_text = "OK",
                    .content_type = "application/octet-stream",
                    .body = content,
                };
            }
        } else if (req.method == .PUT) {
            if (sha.len > 0 and req.body != null) {
                // Verify SHA256
                var hash: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(req.body.?, &hash, .{});
                const hex = std.fmt.bytesToHex(hash, .lower);

                if (!std.mem.eql(u8, sha, &hex)) {
                    return http_parser.HttpResponse{ .status_code = 400, .status_text = "Bad Request", .content_type = "text/plain", .body = try self.allocator.dupe(u8, "SHA256 mismatch") };
                }

                const path = try std.fs.path.join(self.allocator, &[_][]const u8{ objects_dir, sha });
                defer self.allocator.free(path);
                try std.fs.cwd().writeFile(.{ .sub_path = path, .data = req.body.? });
                return jsonResponse(self.allocator, 200, "{\"status\":\"ok\"}");
            }
        }

        return http_parser.HttpResponse{ .status_code = 400, .status_text = "Bad Request", .content_type = "text/plain", .body = try self.allocator.dupe(u8, "Bad Request") };
    }

    fn handleSteps(self: *PvControlServer, req: http_parser.HttpRequest) !http_parser.HttpResponse {
        const parts = if (req.path.len > "/steps/".len) req.path["/steps/".len..] else "";
        const trails_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ self.context.storage_path, "trails" });
        defer self.allocator.free(trails_dir);

        if (req.method == .GET) {
            if (parts.len == 0) {
                // List steps
                var dir = try std.fs.cwd().openDir(trails_dir, .{ .iterate = true });
                defer dir.close();
                var it = dir.iterate();
                var list = std.ArrayList(StepInfo){};
                defer {
                    for (list.items) |item| {
                        self.allocator.free(item.name);
                        self.allocator.free(item.date);
                        self.allocator.free(item.commitmsg);
                        self.allocator.free(item.progress.status);
                        self.allocator.free(item.progress.@"status-msg");
                        self.allocator.free(item.progress.data);
                    }
                    list.deinit(self.allocator);
                }

                while (try it.next()) |entry| {
                    if (entry.kind == .directory) {
                        var step = StepInfo{
                            .name = try self.allocator.dupe(u8, entry.name),
                            .date = try self.allocator.dupe(u8, "2026-02-17T00:00:00Z"),
                            .commitmsg = try self.allocator.dupe(u8, ""),
                            .progress = .{
                                .status = try self.allocator.dupe(u8, "DONE"),
                                .@"status-msg" = try self.allocator.dupe(u8, "finished"),
                                .progress = 100,
                                .data = try self.allocator.dupe(u8, "0"),
                            },
                        };

                        // Try to read progress
                        const progress_path = try std.fs.path.join(self.allocator, &[_][]const u8{ trails_dir, entry.name, ".pv", "progress" });
                        defer self.allocator.free(progress_path);

                        if (std.fs.cwd().readFileAlloc(self.allocator, progress_path, 1024 * 1024)) |content| {
                            defer self.allocator.free(content);
                            if (std.json.parseFromSlice(std.json.Value, self.allocator, content, .{})) |parsed_progress| {
                                defer parsed_progress.deinit();
                                if (parsed_progress.value == .object) {
                                    const obj = parsed_progress.value.object;
                                    if (obj.get("status")) |s| {
                                        if (s == .string) {
                                            self.allocator.free(step.progress.status);
                                            step.progress.status = try self.allocator.dupe(u8, s.string);
                                        }
                                    }
                                    if (obj.get("status-msg")) |sm| {
                                        if (sm == .string) {
                                            self.allocator.free(step.progress.@"status-msg");
                                            step.progress.@"status-msg" = try self.allocator.dupe(u8, sm.string);
                                        }
                                    }
                                    if (obj.get("progress")) |p| {
                                        if (p == .integer) {
                                            step.progress.progress = p.integer;
                                        }
                                    }
                                    if (obj.get("data")) |d| {
                                        if (d == .string) {
                                            self.allocator.free(step.progress.data);
                                            step.progress.data = try self.allocator.dupe(u8, d.string);
                                        }
                                    }
                                }
                            } else |_| {}
                        } else |_| {}

                        try list.append(self.allocator, step);
                    }
                }

                var out = std.ArrayList(u8){};
                defer out.deinit(self.allocator);
                try out.writer(self.allocator).print("{f}", .{std.json.fmt(list.items, .{})});
                return jsonResponse(self.allocator, 200, out.items);
            } else if (std.mem.endsWith(u8, parts, "/progress")) {
                const rev = parts[0 .. parts.len - "/progress".len];
                const path = try std.fs.path.join(self.allocator, &[_][]const u8{ trails_dir, rev, ".pv", "progress" });
                defer self.allocator.free(path);
                const content = std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024) catch {
                    return jsonResponse(self.allocator, 200, "{}");
                };
                defer self.allocator.free(content);
                return jsonResponse(self.allocator, 200, content);
            } else {
                // Get step json
                const path = try std.fs.path.join(self.allocator, &[_][]const u8{ trails_dir, parts, ".pvr", "json" });
                defer self.allocator.free(path);
                const content = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024);
                defer self.allocator.free(content);
                return jsonResponse(self.allocator, 200, content);
            }
        } else if (req.method == .PUT) {
            if (parts.len > 0 and req.body != null) {
                if (std.mem.endsWith(u8, parts, "/commitmsg")) {
                    // Just return ok for now
                    return jsonResponse(self.allocator, 200, "{\"status\":\"ok\"}");
                } else {
                    const path_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ trails_dir, parts, ".pvr" });
                    defer self.allocator.free(path_dir);
                    try std.fs.cwd().makePath(path_dir);
                    const path = try std.fs.path.join(self.allocator, &[_][]const u8{ path_dir, "json" });
                    defer self.allocator.free(path);
                    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = req.body.? });
                    return jsonResponse(self.allocator, 200, "{\"status\":\"ok\"}");
                }
            }
        }

        return http_parser.HttpResponse{ .status_code = 400, .status_text = "Bad Request", .content_type = "text/plain", .body = try self.allocator.dupe(u8, "Bad Request") };
    }

    fn handleGetConfig(self: *PvControlServer) !http_parser.HttpResponse {
        var store = try local_store.LocalStore.init(self.allocator, self.context.storage_path, null, false);
        defer store.deinit();
        const content = try store.read_config(self.allocator);
        return http_parser.HttpResponse{
            .status_code = 200,
            .status_text = "OK",
            .content_type = "text/plain",
            .body = content,
        };
    }

    fn handleGetConfig2(self: *PvControlServer) !http_parser.HttpResponse {
        var store = try local_store.LocalStore.init(self.allocator, self.context.storage_path, null, false);
        defer store.deinit();
        const content = try store.read_config(self.allocator);
        defer self.allocator.free(content);

        var list = std.ArrayList(ConfigEntry){};
        defer {
            for (list.items) |item| {
                self.allocator.free(item.key);
                self.allocator.free(item.value);
                self.allocator.free(item.modified);
            }
            list.deinit(self.allocator);
        }

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.indexOf(u8, line, "=")) |idx| {
                try list.append(self.allocator, .{
                    .key = try self.allocator.dupe(u8, line[0..idx]),
                    .value = try self.allocator.dupe(u8, line[idx + 1 ..]),
                    .modified = try self.allocator.dupe(u8, "mocker"),
                });
            }
        }

        var out = std.ArrayList(u8){};
        defer out.deinit(self.allocator);
        try out.writer(self.allocator).print("{f}", .{std.json.fmt(list.items, .{})});
        return jsonResponse(self.allocator, 200, out.items);
    }
};

fn jsonResponse(allocator: std.mem.Allocator, status: u16, body: []const u8) !http_parser.HttpResponse {
    return http_parser.HttpResponse{
        .status_code = status,
        .status_text = if (status == 200) "OK" else "Error",
        .content_type = "application/json",
        .body = try allocator.dupe(u8, body),
    };
}
