const std = @import("std");
const local_store = @import("../storage/local_store.zig");
const logger = @import("../ui/logger.zig");
const client_mod = @import("../net/client.zig");
const config_mod = @import("../core/config.zig");
const constants = @import("../core/constants.zig");
const business_logic = @import("../core/business_logic.zig");

/// SHA256 cache entry: stores the hash and the file modification time
const Sha256CacheEntry = struct {
    hash: []const u8,
    mtime: i128,
};

/// SHA256 hash cache to avoid recomputing hashes for unchanged files
const Sha256Cache = struct {
    allocator: std.mem.Allocator,
    cache: std.StringHashMap(Sha256CacheEntry),

    fn init(allocator: std.mem.Allocator) Sha256Cache {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap(Sha256CacheEntry).init(allocator),
        };
    }

    fn deinit(self: *Sha256Cache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.hash);
        }
        self.cache.deinit();
    }

    fn get_or_compute(self: *Sha256Cache, path: []const u8) ![]const u8 {
        // Get file modification time
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const stat = try file.stat();
        const mtime = stat.mtime;

        // Check if cached entry exists and is still valid
        if (self.cache.getEntry(path)) |entry| {
            if (entry.value_ptr.mtime == mtime) {
                return entry.value_ptr.hash;
            } else {
                // File has been modified, remove stale entry
                if (self.cache.fetchRemove(path)) |kv| {
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value.hash);
                }
            }
        }

        // Compute hash and cache it
        const hash = try compute_sha256(self.allocator, path);
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        errdefer self.allocator.free(hash);

        try self.cache.put(path_copy, .{
            .hash = hash,
            .mtime = mtime,
        });

        return hash;
    }
};

pub fn run_update_cycle(
    allocator: std.mem.Allocator,
    store: *local_store.LocalStore,
    log: *logger.Logger,
    client: *client_mod.Client,
    cfg: *config_mod.Config,
    ctx_ptr: *const anyopaque,
    ask_user_fn: *const fn (*const anyopaque) client_mod.UpdateStatus,
) !void {
    std.debug.assert(cfg.creds_prn != null);
    log.log("Checking for updates (steps)...", .{});

    const prn = cfg.creds_prn.?;
    try client.login(prn, cfg.creds_secret.?);

    const revs = try store.get_revisions();
    const rev_str_ptr = revs.rev; // Keep pointer to free later
    const try_str_ptr = revs.try_rev;
    defer {
        allocator.free(rev_str_ptr);
        allocator.free(try_str_ptr);
    }

    var stable_rev = try std.fmt.parseInt(i64, revs.rev, 10);
    var try_rev = try std.fmt.parseInt(i64, revs.try_rev, 10);

    // Initialize SHA256 cache
    var sha_cache = Sha256Cache.init(allocator);
    defer sha_cache.deinit();

    while (true) {
        var next_rev: i64 = 0;
        var is_recovery = false;

        if (try_rev > stable_rev) {
            next_rev = try_rev;
            is_recovery = true;
        } else {
            next_rev = stable_rev + 1;
        }

        if (client.get_step(prn, next_rev)) |step| {
            var s_ptr = step;
            defer client.free_step(&s_ptr);

            // Parse status using the enum helper
            const status_str = s_ptr.progress.status;
            const status_enum = client_mod.UpdateStatus.parse(status_str);

            const is_term = if (status_enum) |s| s.isTerminal() else false;

            if (is_term) {
                const s = status_str; // Use original string for logging if needed
                const step_rev_str = try std.fmt.allocPrint(allocator, "{d}", .{s_ptr.rev});
                defer allocator.free(step_rev_str);

                const stable_rev_str = try std.fmt.allocPrint(allocator, "{d}", .{stable_rev});
                defer allocator.free(stable_rev_str);

                if (is_recovery) {
                    // Check if success terminal state
                    var is_success = false;
                    if (status_enum) |se| {
                        if (se == .DONE or se == .UPDATED) is_success = true;
                    }

                    if (is_success) {
                        // Commit forward
                        log.log("Recovery: Revision {d} is already {s} on cloud. Committing locally.", .{ try_rev, s });
                        try store.set_revisions(step_rev_str, step_rev_str);
                        stable_rev = try_rev;
                    } else {
                        // Rollback
                        log.log("Recovery: Revision {d} is in terminal failure state {s}. Rolling back to {d}", .{ try_rev, s, stable_rev });
                        try store.set_revisions(stable_rev_str, stable_rev_str);
                        try_rev = stable_rev;
                    }
                } else {
                    // Fast forward (Skipping revision)
                    log.log("Skipping revision {d} (Terminal Status: {s}) - Marking as processed.", .{ s_ptr.rev, s });
                    try store.set_revisions(step_rev_str, step_rev_str);
                    stable_rev = s_ptr.rev;
                    try_rev = s_ptr.rev;
                }
                continue;
            }

            // Processing Active/Pending Step
            const step_rev_str = try std.fmt.allocPrint(allocator, "{d}", .{s_ptr.rev});
            defer allocator.free(step_rev_str);

            const stable_rev_str = try std.fmt.allocPrint(allocator, "{d}", .{stable_rev});
            defer allocator.free(stable_rev_str);

            if (is_recovery) {
                log.log("Recovery: Resuming interrupted revision {d} (Status: {s})", .{ try_rev, status_str });
            } else {
                // New attempt
                log.log("Starting new revision {d} (Previous: {d})", .{ s_ptr.rev, stable_rev });
                try store.set_revisions(stable_rev_str, step_rev_str);
                try_rev = s_ptr.rev;
            }

            if (try process_step(allocator, store, log, client, prn, s_ptr, ctx_ptr, ask_user_fn, &sha_cache)) {
                stable_rev = s_ptr.rev;
                // Loop continues to check for more updates
            } else {
                log.log("Revision {d} failed. Rolling back to {d}.", .{ s_ptr.rev, stable_rev });
                try store.set_revisions(stable_rev_str, stable_rev_str);
                break;
            }
        } else |err| {
            if (is_recovery) {
                const stable_rev_str = try std.fmt.allocPrint(allocator, "{d}", .{stable_rev});
                defer allocator.free(stable_rev_str);

                log.log("Recovery: Pending revision {d} not found in trail (Error: {any}). Rolling back to {d}", .{ try_rev, err, stable_rev });
                try store.set_revisions(stable_rev_str, stable_rev_str);
                try_rev = stable_rev;
                continue;
            } else {
                // Log the actual error for debugging
                log.log("Failed to fetch next revision (rev={d}): {any}", .{ next_rev, err });
                // End of trail or error - this is expected when no more updates are available
                break;
            }
        }
    }
}

fn write_progress_and_log(
    allocator: std.mem.Allocator,
    store: *local_store.LocalStore,
    log: *logger.Logger,
    rev: []const u8,
    progress: client_mod.StepProgress,
) !void {
    var allocating = std.io.Writer.Allocating.init(allocator);
    defer allocating.deinit();

    var stream: std.json.Stringify = .{ .writer = &allocating.writer, .options = .{} };
    try stream.write(progress);

    const json = try allocating.toOwnedSlice();
    defer allocator.free(json);

    log.log("Progress JSON for revision {s}: {s}", .{ rev, json });

    try store.save_revision_progress(rev, json);
}

fn process_step(
    allocator: std.mem.Allocator,
    store: *local_store.LocalStore,
    log: *logger.Logger,
    client: *client_mod.Client,
    prn: []const u8,
    step: client_mod.Step,
    ctx_ptr: *const anyopaque,
    ask_user_fn: *const fn (*const anyopaque) client_mod.UpdateStatus,
    sha_cache: *Sha256Cache,
) !bool {
    std.debug.assert(prn.len > 0);
    log.log("New step found: Revision {d}", .{step.rev});
    const rev_str = try std.fmt.allocPrint(allocator, "{d}", .{step.rev});
    defer allocator.free(rev_str);
    try store.init_revision_dirs(rev_str);

    // 1. QUEUED
    const queued_progress = client_mod.StepProgress{ .status = client_mod.UpdateStatus.QUEUED.toString(), .progress = constants.PROGRESS_QUEUED, .@"status-msg" = "Revision put to queue" };
    try write_progress_and_log(allocator, store, log, rev_str, queued_progress);
    try client.post_progress(prn, step.rev, queued_progress);

    // 2. DOWNLOADING
    const download_progress = client_mod.StepProgress{ .status = client_mod.UpdateStatus.DOWNLOADING.toString(), .progress = constants.PROGRESS_DOWNLOADING, .@"status-msg" = "Downloading the artifacts for the new revision." };
    try write_progress_and_log(allocator, store, log, rev_str, download_progress);
    try client.post_progress(prn, step.rev, download_progress);

    const objects = client.get_step_objects(prn, step.rev) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to fetch object metadata: {any}", .{err});
        defer allocator.free(msg);
        const fail_prog = client_mod.StepProgress{ .status = client_mod.UpdateStatus.WONTGO.toString(), .progress = 0, .@"status-msg" = msg };
        try client.post_progress(prn, step.rev, fail_prog);
        return false;
    };
    defer client.free_step_objects(objects);

    log.log("Objects in revision {d}:", .{step.rev});
    for (objects) |obj| {
        log.log(" - {s} ({s})", .{ obj.objectname, obj.id });
    }

    for (objects) |obj| {
        if (!business_logic.isValidSha256(obj.id)) {
            log.log("Object '{s}' has invalid SHA256 format: {s}", .{ obj.objectname, obj.id });
            continue;
        }
        const dest_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ store.base_path, obj.id });
        defer allocator.free(dest_path);

        // Check if object already exists and has correct SHA256
        var skip_download = false;
        if (std.fs.cwd().access(dest_path, .{})) |_| {
            const existing_sha = sha_cache.get_or_compute(dest_path) catch |err| blk: {
                log.log("Failed to compute SHA256 for existing object {s}: {any}", .{ obj.id, err });
                break :blk null;
            };
            if (existing_sha) |sha| {
                if (business_logic.isValidSha256(obj.id) and std.mem.eql(u8, sha, obj.id)) {
                    log.log("Object '{s}' ({s}) already exists and is valid. Skipping download.", .{ obj.objectname, obj.id });
                    skip_download = true;
                } else if (!business_logic.isValidSha256(obj.id)) {
                    log.log("Object '{s}' has invalid SHA256 format: {s}", .{ obj.objectname, obj.id });
                }
            }
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        if (!skip_download) {
            if (std.fs.path.dirname(dest_path)) |dir| try std.fs.cwd().makePath(dir);

            const download_url = obj.@"signed-geturl" orelse {
                const fail_prog = client_mod.StepProgress{ .status = client_mod.UpdateStatus.WONTGO.toString(), .progress = 0, .@"status-msg" = "Signature validation failed: No signed URL found for object" };
                try write_progress_and_log(allocator, store, log, rev_str, fail_prog);
                try client.post_progress(prn, step.rev, fail_prog);
                return false;
            };

            log.log("Downloading object '{s}' from {s}", .{ obj.objectname, download_url });
            const content = try @import("../net/curl.zig").Curl.simple_request(download_url, "GET", null, null, allocator);
            defer allocator.free(content);

            const file = try std.fs.cwd().createFile(dest_path, .{});
            defer file.close();
            try file.writeAll(content);

            const actual_sha = try sha_cache.get_or_compute(dest_path);

            if (business_logic.isValidSha256(obj.id) and !std.mem.eql(u8, actual_sha, obj.id)) {
                const err_msg = try std.fmt.allocPrint(allocator, "Object validation went wrong: expected {s}, got {s}", .{ obj.id, actual_sha });
                defer allocator.free(err_msg);

                const fail_prog = client_mod.StepProgress{ .status = client_mod.UpdateStatus.ERROR.toString(), .progress = 0, .@"status-msg" = err_msg };
                try write_progress_and_log(allocator, store, log, rev_str, fail_prog);
                try client.post_progress(prn, step.rev, fail_prog);
                return false;
            }
        }
    }

    // 3. INPROGRESS
    const ip_progress = client_mod.StepProgress{ .status = client_mod.UpdateStatus.INPROGRESS.toString(), .progress = constants.PROGRESS_DOWNLOADED, .@"status-msg" = "Update objects downloaded" };
    try write_progress_and_log(allocator, store, log, rev_str, ip_progress);
    try client.post_progress(prn, step.rev, ip_progress);

    // 4. APPLY
    const ip_applied = client_mod.StepProgress{ .status = client_mod.UpdateStatus.INPROGRESS.toString(), .progress = constants.PROGRESS_APPLIED, .@"status-msg" = "Update applied" };
    try client.post_progress(prn, step.rev, ip_applied);

    // 4. TESTING
    const testing_progress = client_mod.StepProgress{ .status = client_mod.UpdateStatus.TESTING.toString(), .progress = constants.PROGRESS_TESTING, .@"status-msg" = "Awaiting to see if update is stable" };
    try write_progress_and_log(allocator, store, log, rev_str, testing_progress);
    try client.post_progress(prn, step.rev, testing_progress);

    log.log("Awaiting user decision for update (TESTING)...", .{});
    const decision = ask_user_fn(ctx_ptr);

    var final_status: client_mod.UpdateStatus = .DONE;
    var success = false;
    var status_msg: []const u8 = "";

    switch (decision) {
        .UPDATED => {
            final_status = .UPDATED;
            status_msg = "Update finished (Immediate)";
            success = true;
        },
        .DONE => {
            // Fake reboot cycle
            const reboot_prog = client_mod.StepProgress{ .status = client_mod.UpdateStatus.INPROGRESS.toString(), .progress = constants.PROGRESS_REBOOTING, .@"status-msg" = "Simulating reboot..." };
            try client.post_progress(prn, step.rev, reboot_prog);
            log.log("Simulating reboot ({d}s wait)...", .{constants.REBOOT_SIMULATION_DURATION_S});
            std.Thread.sleep(constants.REBOOT_SIMULATION_DURATION_S * std.time.ns_per_s);

            final_status = .DONE;
            status_msg = "Update finished, revision set as rollback point";
            success = true;
        },
        .ERROR => {
            final_status = .ERROR;
            status_msg = "User marked update as ERROR";
            success = false;
        },
        .WONTGO => {
            final_status = .WONTGO;
            status_msg = "User rejected update (WONTGO)";
            success = false;
        },
        else => unreachable,
    }

    const final_progress = client_mod.StepProgress{ .status = final_status.toString(), .progress = if (success) 100 else 0, .@"status-msg" = status_msg };
    try write_progress_and_log(allocator, store, log, rev_str, final_progress);
    try client.post_progress(prn, step.rev, final_progress);

    if (success) {
        if (step.state) |st| {
            const state_json = try std.fmt.allocPrint(allocator, "{any}", .{std.json.fmt(st, .{})});
            defer allocator.free(state_json);
            try store.save_revision_state(rev_str, state_json);
        }

        try store.init_log_dir(rev_str);

        if (final_status == .UPDATED) {
            const cur_revs = try store.get_revisions();
            defer allocator.free(cur_revs.rev);
            defer allocator.free(cur_revs.try_rev);
            // UPDATED: Keep old stable (rev), update running (try_rev)
            try store.set_revisions(cur_revs.rev, rev_str);
        } else {
            // DONE: Commit as new stable
            try store.set_revision(rev_str);
        }

        const new_path = try store.get_log_path(rev_str);
        defer allocator.free(new_path);
        try log.switch_log_file(new_path);
        return true;
    } else {
        return false;
    }
}

fn compute_sha256(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    std.debug.assert(path.len > 0);
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    const digest = hasher.finalResult();
    const hex_array = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex_array);
}
