const std = @import("std");
const client = @import("../net/client.zig");
const local_store = @import("../storage/local_store.zig");
const logger = @import("../ui/logger.zig");
const config = @import("config.zig");
const sys_info = @import("../system/sys_info.zig");
const ipc = @import("ipc.zig");
const messages = @import("messages.zig");

pub const Meta = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Meta {
        return Meta{ .allocator = allocator };
    }

    pub fn deinit(self: *Meta) void {
        _ = self;
    }

    fn allocStringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
        return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    }

    fn sendProgress(self: *Meta, client_opt: ?*ipc.IpcClient, percentage: u8, details: []const u8) void {
        if (client_opt) |c| {
            var map = std.StringArrayHashMap(std.json.Value).init(self.allocator);
            defer map.deinit();
            map.put("percentage", .{ .integer = percentage }) catch {};
            map.put("details", .{ .string = details }) catch {};
            c.sendMessage(.renderer, .sync_progress, .{ .object = map }) catch {};
        }
    }

    pub fn update_local(self: *Meta, store: *local_store.LocalStore, cfg: *config.Config, extra_overrides: ?std.StringArrayHashMap(std.json.Value)) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // 1. Load existing meta.json
        var meta_map = std.StringArrayHashMap(std.json.Value).init(aa);
        const meta_path = try std.fs.path.join(aa, &[_][]const u8{ store.base_path, "device-meta", "meta.json" });

        if (std.fs.cwd().openFile(meta_path, .{})) |file| {
            defer file.close();
            const content = try file.readToEndAlloc(aa, 1024 * 100);
            if (std.json.parseFromSlice(std.json.Value, aa, content, .{ .duplicate_field_behavior = .use_last })) |parsed| {
                if (parsed.value == .object) {
                    var it = parsed.value.object.iterator();
                    while (it.next()) |entry| {
                        try meta_map.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }
            } else |_| {}
        } else |_| {}

        // 2. Generate System Info
        const uname = try sys_info.get_uname(aa);
        const storage = try sys_info.get_storage(store.base_path);
        const info = try sys_info.get_sysinfo();
        const time = sys_info.get_time();
        const model = try sys_info.get_dtmodel(aa);
        const arch = try sys_info.get_arch(aa);
        const interfaces_json_str = try sys_info.get_interfaces(aa);

        // Convert interfaces JSON string to Value
        const interfaces_val = try std.json.parseFromSlice(std.json.Value, aa, interfaces_json_str, .{});

        const rev = try store.get_revision(); // Always fresh from disk
        defer store.allocator.free(rev);
        const ph_addr = try std.fmt.allocPrint(aa, "{s}:{s}", .{ cfg.pantahub_host.?, cfg.pantahub_port orelse "443" });

        try meta_map.put("interfaces", interfaces_val.value);
        try meta_map.put("pantahub.address", std.json.Value{ .string = ph_addr });
        try meta_map.put("pantahub.claimed", std.json.Value{ .string = "1" });
        try meta_map.put("pantahub.online", std.json.Value{ .string = "1" });
        try meta_map.put("pantahub.state", std.json.Value{ .string = "idle" });
        try meta_map.put("pantavisor.arch", std.json.Value{ .string = arch });
        try meta_map.put("pantavisor.dtmodel", std.json.Value{ .string = model });
        try meta_map.put("pantavisor.mode", std.json.Value{ .string = "remote" });
        try meta_map.put("pantavisor.revision", std.json.Value{ .string = rev });
        try meta_map.put("pantavisor.status", std.json.Value{ .string = "READY" });
        try meta_map.put("pantavisor.version", std.json.Value{ .string = "019-302-g091a41d-240731" });

        // Convert structs to Values via stringify+parse
        const storage_str = try allocStringify(aa, storage);
        const storage_val = try std.json.parseFromSlice(std.json.Value, aa, storage_str, .{});
        try meta_map.put("storage", storage_val.value);

        const uname_str = try allocStringify(aa, uname);
        const uname_val = try std.json.parseFromSlice(std.json.Value, aa, uname_str, .{});
        try meta_map.put("pantavisor.uname", uname_val.value);

        const info_str = try allocStringify(aa, info);
        const info_val = try std.json.parseFromSlice(std.json.Value, aa, info_str, .{});
        try meta_map.put("sysinfo", info_val.value);

        const time_str = try allocStringify(aa, time);
        const time_val = try std.json.parseFromSlice(std.json.Value, aa, time_str, .{});
        try meta_map.put("time", time_val.value);

        // 3. Merge Mocker Overrides
        if (cfg.mocker_meta) |mm| {
            if (mm == .object) {
                var it = mm.object.iterator();
                while (it.next()) |entry| {
                    try meta_map.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }

        // 4. Merge Extra Overrides (e.g. from check_tls_ownership)
        if (extra_overrides) |extras| {
            var it = extras.iterator();
            while (it.next()) |entry| {
                try meta_map.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        // 5. Write to file
        const file = try std.fs.cwd().createFile(meta_path, .{});
        defer file.close();

        var list = std.ArrayList(u8){};
        defer list.deinit(aa);
        try list.writer(aa).print("{f}", .{std.json.fmt(std.json.Value{ .object = meta_map }, .{ .whitespace = .indent_4 })});
        try file.writeAll(list.items);
    }

    pub fn sync(self: *Meta, cli: *client.Client, store: *local_store.LocalStore, log: *logger.Logger, cfg: *config.Config, ipc_client: ?*ipc.IpcClient) !void {
        _ = cli;
        _ = log;
        self.sendProgress(ipc_client, 10, "Updating local metadata...");
        try self.update_local(store, cfg, null);
        self.sendProgress(ipc_client, 20, "Local metadata updated");
    }

    pub fn push(self: *Meta, cli: *client.Client, store: *local_store.LocalStore, log: *logger.Logger, cfg: *config.Config, ipc_client: ?*ipc.IpcClient) !void {
        if (cli.token == null) {
            log.log("Skipping meta push: Not logged in.", .{});
            return;
        }
        if (cfg.creds_prn == null or cfg.creds_secret == null) {
            log.log("Skipping meta push: No credentials.", .{});
            return;
        }
        const prn = cfg.creds_prn.?;
        std.debug.assert(prn.len > 0);

        log.log("Pushing metadata to cloud...", .{});
        self.sendProgress(ipc_client, 30, "Pushing device-meta...");
        try self.sync_device_meta(cli, store, log, prn, ipc_client);
        
        self.sendProgress(ipc_client, 60, "Fetching user-meta...");
        try self.sync_user_meta(cli, store, log, prn, ipc_client);
        
        self.sendProgress(ipc_client, 100, "Sync complete");
    }

    fn sync_device_meta(self: *Meta, cli: *client.Client, store: *local_store.LocalStore, log: *logger.Logger, prn: []const u8, ipc_client: ?*ipc.IpcClient) !void {
        std.debug.assert(prn.len > 0);
        const meta_path = try std.fs.path.join(self.allocator, &[_][]const u8{ store.base_path, "device-meta", "meta.json" });
        defer self.allocator.free(meta_path);

        const file = std.fs.cwd().openFile(meta_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                log.log("Local device-meta meta.json not found. Skipping uplink.", .{});
                return;
            }
            return err;
        };
        defer file.close();

        const meta_content = try file.readToEndAlloc(self.allocator, 1024 * 100);
        defer self.allocator.free(meta_content);
        std.debug.assert(meta_content.len > 0);

        log.log("Uploading device-meta to cloud...", .{});
        self.sendProgress(ipc_client, 40, "Uploading device-meta...");
        try cli.patch_device_meta(prn, meta_content);
        log.log("Device-meta uploaded successfully.", .{});
        self.sendProgress(ipc_client, 50, "Device-meta uploaded");
    }

    fn sync_user_meta(self: *Meta, cli: *client.Client, store: *local_store.LocalStore, log: *logger.Logger, prn: []const u8, ipc_client: ?*ipc.IpcClient) !void {
        std.debug.assert(prn.len > 0);
        log.log("Fetching user-meta from cloud...", .{});
        self.sendProgress(ipc_client, 70, "Downloading user-meta...");
        const cloud_meta = cli.get_user_meta(prn) catch |err| {
            log.log("Failed to fetch user-meta: {any}", .{err});
            return;
        };
        defer self.allocator.free(cloud_meta);

        const meta_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ store.base_path, "user-meta" });
        defer self.allocator.free(meta_dir);
        try std.fs.cwd().makePath(meta_dir);

        const meta_path = try std.fs.path.join(self.allocator, &[_][]const u8{ meta_dir, "meta.json" });
        defer self.allocator.free(meta_path);

        var changed = true;
        if (std.fs.cwd().openFile(meta_path, .{})) |file| {
            defer file.close();
            const local_meta = try file.readToEndAlloc(self.allocator, 1024 * 100);
            defer self.allocator.free(local_meta);
            if (std.mem.eql(u8, local_meta, cloud_meta)) changed = false;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        if (changed) {
            log.log("User-meta changed. Updating local storage.", .{});
            self.sendProgress(ipc_client, 80, "Applying user-meta...");
            const file = try std.fs.cwd().createFile(meta_path, .{});
            defer file.close();
            try file.writeAll(cloud_meta);
            log.log("User-meta updated successfully.", .{});
        } else {
            log.log("User-meta unchanged.", .{});
            self.sendProgress(ipc_client, 90, "User-meta unchanged");
        }
        std.debug.assert(meta_path.len > 0);
    }
};
