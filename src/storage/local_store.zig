const std = @import("std");

pub const Revisions = struct {
    rev: []u8,
    try_rev: []u8,
};

pub const LocalStore = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,
    lock_file: ?std.fs.File = null,

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8, init_token: ?[]const u8, is_exclusive: bool) !LocalStore {
        std.debug.assert(base_path.len > 0);

        const subdirs = [_][]const u8{ "config", "device-meta", "logs", "objects", "trails", "user-meta" };
        for (subdirs) |subdir| {
            const path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, subdir });
            defer allocator.free(path);
            try std.fs.cwd().makePath(path);
        }

        const lock_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "config", "mocker.lock" });
        defer allocator.free(lock_path);

        var lock_file: ?std.fs.File = null;
        if (is_exclusive) {
            const file = try std.fs.cwd().createFile(lock_path, .{ .truncate = false });
            std.posix.flock(file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) catch |err| {
                file.close();
                if (err == error.WouldBlock) return error.AlreadyRunning;
                return err;
            };
            lock_file = file;
        }

        const config_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "config", "pantahub.config" });
        defer allocator.free(config_path);

        std.fs.cwd().access(config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                var default_config = std.ArrayList(u8){};
                defer default_config.deinit(allocator);

                try default_config.writer(allocator).print(
                    \\PH_CREDS_HOST=api.pantahub.com
                    \\PH_CREDS_PORT=443
                    \\PH_METADATA_DEVMETA_INTERVAL=10
                    \\PH_METADATA_USRMETA_INTERVAL=10
                    \\
                , .{});

                if (init_token) |tok| {
                    try default_config.writer(allocator).print("PH_FACTORY_AUTOTOK={s}\n", .{tok});
                }

                const file = try std.fs.cwd().createFile(config_path, .{});
                defer file.close();
                try file.writeAll(default_config.items);
            } else return err;
        };

        const mocker_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "config", "mocker.json" });
        defer allocator.free(mocker_path);

        std.fs.cwd().access(mocker_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                const file = try std.fs.cwd().createFile(mocker_path, .{});
                defer file.close();
                try file.writeAll("{}");
            } else return err;
        };

        const rev_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "revision-info.json" });
        defer allocator.free(rev_path);

        std.fs.cwd().access(rev_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                const file = try std.fs.cwd().createFile(rev_path, .{});
                defer file.close();
                try file.writeAll("{\"rev\":\"0\",\"try_rev\":\"0\"}");
            } else return err;
        };

        return LocalStore{
            .allocator = allocator,
            .base_path = try allocator.dupe(u8, base_path),
            .lock_file = lock_file,
        };
    }

    fn validate_revision(rev: []const u8) !void {
        if (rev.len == 0) return error.InvalidRevision;
        for (rev) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') {
                return error.InvalidRevision;
            }
        }
        if (std.mem.indexOf(u8, rev, "..") != null) return error.InvalidRevision;
    }

    pub fn get_log_offset(self: *LocalStore, rev: []const u8) !u64 {
        try validate_revision(rev);
        const path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "logs", rev, "pantavisor", ".offset" });
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return 0;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 64);
        defer self.allocator.free(content);
        return std.fmt.parseInt(u64, std.mem.trim(u8, content, " \n\r\t"), 10) catch 0;
    }

    pub fn set_log_offset(self: *LocalStore, rev: []const u8, offset: u64) !void {
        try validate_revision(rev);
        const path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "logs", rev, "pantavisor", ".offset" });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var buf: [64]u8 = undefined;
        var w = file.writer(&buf);
        try w.interface.print("{d}", .{offset});
    }

    pub fn deinit(self: *LocalStore) void {
        if (self.lock_file) |f| f.close();
        std.debug.assert(self.base_path.len > 0);
        self.allocator.free(self.base_path);
    }

    pub fn read_config(self: LocalStore, allocator: std.mem.Allocator) ![]u8 {
        std.debug.assert(self.base_path.len > 0);
        const path = try std.fs.path.join(allocator, &[_][]const u8{ self.base_path, "config", "pantahub.config" });
        defer allocator.free(path);
        std.debug.assert(path.len > 0);

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return try allocator.dupe(u8, "");
            return err;
        };
        defer file.close();

        return file.readToEndAlloc(allocator, 1024 * 10);
    }

    pub fn read_mocker_json(self: LocalStore, allocator: std.mem.Allocator, log: anytype) ![]u8 {
        std.debug.assert(self.base_path.len > 0);
        const path = try std.fs.path.join(allocator, &[_][]const u8{ self.base_path, "config", "mocker.json" });
        defer allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return try allocator.dupe(u8, "");
            return err;
        };
        defer file.close();

        log.log("Reading mocker.json from {s}", .{path});
        return file.readToEndAlloc(allocator, 1024 * 50);
    }

    pub fn save_config_value(self: LocalStore, key: []const u8, value: []const u8) !void {
        std.debug.assert(key.len > 0);
        std.debug.assert(value.len > 0);
        const config_content = try self.read_config(self.allocator);
        defer self.allocator.free(config_content);

        var out_buf = std.ArrayList(u8){};
        defer out_buf.deinit(self.allocator);

        var key_found = false;
        var it = std.mem.splitScalar(u8, config_content, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == '=') {
                try out_buf.writer(self.allocator).print("{s}={s}\n", .{ key, value });
                key_found = true;
            } else {
                try out_buf.writer(self.allocator).print("{s}\n", .{line});
            }
        }

        if (!key_found) {
            try out_buf.writer(self.allocator).print("{s}={s}\n", .{ key, value });
        }

        const path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "config", "pantahub.config" });
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        try file.writeAll(out_buf.items);
    }

    pub fn init_log_dir(self: *LocalStore, rev: []const u8) !void {
        std.debug.assert(self.base_path.len > 0);
        try validate_revision(rev);
        const path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "logs", rev, "pantavisor" });
        defer self.allocator.free(path);
        try std.fs.cwd().makePath(path);
    }

    pub fn get_log_path(self: *LocalStore, rev: []const u8) ![]u8 {
        std.debug.assert(self.base_path.len > 0);
        try validate_revision(rev);
        return std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "logs", rev, "pantavisor", "pantavisor.log" });
    }

    pub fn init_revision_dirs(self: *LocalStore, rev: []const u8) !void {
        try validate_revision(rev);
        const paths = [_][]const u8{ ".pv", ".pvr" };
        for (paths) |p| {
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "trails", rev, p });
            defer self.allocator.free(full_path);
            try std.fs.cwd().makePath(full_path);
        }
    }

    pub fn save_revision_progress(self: *LocalStore, rev: []const u8, progress_json: []const u8) !void {
        try validate_revision(rev);
        std.debug.assert(progress_json.len > 0);
        const path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "trails", rev, ".pv", "progress" });
        defer self.allocator.free(path);
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(progress_json);
    }

    pub fn save_revision_state(self: *LocalStore, rev: []const u8, state_json: []const u8) !void {
        try validate_revision(rev);
        std.debug.assert(state_json.len > 0);
        const path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "trails", rev, ".pvr", "json" });
        defer self.allocator.free(path);
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(state_json);
    }

    pub fn get_revisions(self: *LocalStore) !Revisions {
        const path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "revision-info.json" });
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // Fallback to old location or default
                const def = Revisions{ .rev = try self.allocator.dupe(u8, "0"), .try_rev = try self.allocator.dupe(u8, "0") };
                try self.set_revisions(def.rev, def.try_rev);
                return def;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024);
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(struct { rev: []const u8, try_rev: []const u8 }, self.allocator, content, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const rev = try self.allocator.dupe(u8, parsed.value.rev);
        errdefer self.allocator.free(rev);
        const try_rev = try self.allocator.dupe(u8, parsed.value.try_rev);

        return Revisions{
            .rev = rev,
            .try_rev = try_rev,
        };
    }

    pub fn set_revisions(self: *LocalStore, rev: []const u8, try_rev: []const u8) !void {
        try validate_revision(rev);
        try validate_revision(try_rev);
        std.debug.assert(rev.len > 0);
        std.debug.assert(try_rev.len > 0);

        const path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "revision-info.json" });
        defer self.allocator.free(path);

        const revs_to_save = struct { rev: []const u8, try_rev: []const u8 }{ .rev = rev, .try_rev = try_rev };

        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator);

        try buf.writer(self.allocator).print("{f}", .{std.json.fmt(revs_to_save, .{})});

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(buf.items);

        try self.update_current_symlinks(try_rev);
    }

    pub fn get_revision(self: *LocalStore) ![]u8 {
        const revs = try self.get_revisions();
        self.allocator.free(revs.rev);
        return revs.try_rev;
    }

    pub fn set_revision(self: *LocalStore, new_rev: []const u8) !void {
        try self.set_revisions(new_rev, new_rev);
    }

    pub fn update_current_symlinks(self: *LocalStore, rev: []const u8) !void {
        try validate_revision(rev);
        const targets = [_][]const u8{ "trails", "logs" };
        for (targets) |target_dir| {
            const link_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, target_dir, "current" });
            defer self.allocator.free(link_path);

            // Remove existing link if it exists
            std.fs.cwd().deleteFile(link_path) catch |err| {
                if (err != error.FileNotFound) return err;
            };

            try std.fs.cwd().symLink(rev, link_path, .{});
        }
    }
};

test "local_store revision" {
    const allocator = std.testing.allocator;
    const test_base = "storage_test_revision";
    std.fs.cwd().makePath(test_base ++ "/device-meta") catch {};
    defer std.fs.cwd().deleteTree(test_base) catch {};

    // Create initial revision file
    const revs = Revisions{ .rev = try allocator.dupe(u8, "0"), .try_rev = try allocator.dupe(u8, "0") };
    defer allocator.free(revs.rev);
    defer allocator.free(revs.try_rev);

    var json_buf = std.ArrayList(u8).init(allocator);
    defer json_buf.deinit();
    try json_buf.writer(allocator).print("{f}", .{std.json.fmt(revs, .{})});
    try std.fs.cwd().writeFile(.{ .sub_path = test_base ++ "/revision-info.json", .data = json_buf.items });

    var store = try LocalStore.init(allocator, test_base, null, false);
    defer store.deinit();

    // Verify initial read
    const rev1 = try store.get_revision();
    defer allocator.free(rev1);
    try std.testing.expectEqualStrings("0", rev1);

    // Set new revision
    try store.set_revision("42");

    // Verify read back
    const rev2 = try store.get_revision();
    defer allocator.free(rev2);
    try std.testing.expectEqualStrings("42", rev2);

    // Verify symlinks
    const targets = [_][]const u8{ "trails", "logs" };
    for (targets) |target_dir| {
        const link_path = try std.fs.path.join(allocator, &[_][]const u8{ test_base, target_dir, "current" });
        defer allocator.free(link_path);

        var buf: [1024]u8 = undefined;
        const target = try std.fs.cwd().readLink(link_path, &buf);
        try std.testing.expectEqualStrings("42", target);
    }
}
