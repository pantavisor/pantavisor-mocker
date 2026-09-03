const std = @import("std");
const local_store = @import("local_store.zig");
const business_logic = @import("business_logic.zig");

/// Garbage collector: reclaims storage occupied by superseded revisions.
///
/// Keep set (everything else in trails/ and logs/ is deleted):
///   - revision 0 (factory revision)
///   - the stable revision (rollback point while an update is in flight)
///   - try_rev (the current/running revision)
///
/// Objects are content-addressed and shared across revisions, so each
/// revision records the objects it needs in a manifest (trails/<rev>/.pvr/objects,
/// one sha256 per line, written by the update flow and pvcontrol uploads).
/// The GC protects the union of the kept revisions' manifests and deletes
/// any other file in objects/.
pub const GcConfig = struct {
    /// How often the GC runs, in seconds. 0 disables the GC.
    interval_s: u64 = 3600,
    /// Delete a revision's log dir when its log file hasn't been written to
    /// for this long (seconds). 0 keeps logs until their revision is removed.
    logs_max_age_s: u64 = 604800,
};

/// Per-mocker GC bookkeeping (in-memory only; a restart just re-runs the GC,
/// which is idempotent).
pub const GcState = struct {
    last_run_ms: i64 = 0,
};

pub const GcResult = struct {
    revisions_removed: usize = 0,
    log_dirs_removed: usize = 0,
    objects_removed: usize = 0,
};

/// Event-loop entry point: runs the GC at most once per configured interval
/// and swallows errors, so the GC can never take the mocker down.
pub fn maybeRun(allocator: std.mem.Allocator, store: *local_store.LocalStore, cfg: GcConfig, state: *GcState) void {
    if (cfg.interval_s == 0) return;
    const interval_ms = std.math.cast(i64, cfg.interval_s *| std.time.ms_per_s) orelse return;

    const now_ms = std.time.milliTimestamp();
    if (!business_logic.hasIntervalElapsed(state.last_run_ms, now_ms, interval_ms)) return;
    state.last_run_ms = now_ms;

    const result = run(allocator, store, cfg) catch return;
    if (result.revisions_removed + result.log_dirs_removed + result.objects_removed > 0) {
        std.debug.print("GC: removed {d} old revisions, {d} stale log dirs, {d} objects\n", .{
            result.revisions_removed, result.log_dirs_removed, result.objects_removed,
        });
    }
}

pub fn run(allocator: std.mem.Allocator, store: *local_store.LocalStore, cfg: GcConfig) !GcResult {
    var result = GcResult{};

    const revs = try store.get_revisions();
    defer allocator.free(revs.rev);
    defer allocator.free(revs.try_rev);

    const keep_rev = std.fmt.parseInt(u64, revs.rev, 10) catch 0;
    const keep_try = std.fmt.parseInt(u64, revs.try_rev, 10) catch keep_rev;

    try removeOldRevisions(allocator, store, keep_rev, keep_try, &result);
    if (cfg.logs_max_age_s > 0) try removeAgedLogs(allocator, store, keep_try, cfg.logs_max_age_s, &result);
    try removeOrphanObjects(allocator, store, keep_rev, keep_try, &result);
    return result;
}

fn parseRevNum(name: []const u8) ?u64 {
    if (name.len == 0) return null;
    return std.fmt.parseInt(u64, name, 10) catch null;
}

/// Collect directory names first and delete afterwards: mutating a directory
/// while iterating it is undefined behavior.
fn collectRevDirs(allocator: std.mem.Allocator, base: []const u8, subdir: []const u8, names: *std.ArrayList([]u8)) !void {
    const dir_path = try std.fs.path.join(allocator, &[_][]const u8{ base, subdir });
    defer allocator.free(dir_path);

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .sym_link) continue; // "current"
        if (parseRevNum(entry.name) == null) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
}

fn removeOldRevisions(allocator: std.mem.Allocator, store: *local_store.LocalStore, keep_rev: u64, keep_try: u64, result: *GcResult) !void {
    var revs_to_remove = std.ArrayList([]u8){};
    defer {
        for (revs_to_remove.items) |n| allocator.free(n);
        revs_to_remove.deinit(allocator);
    }
    try collectRevDirs(allocator, store.base_path, "trails", &revs_to_remove);

    for (revs_to_remove.items) |name| {
        const num = parseRevNum(name).?;
        if (num == 0 or num == keep_rev or num == keep_try) continue;

        if (try deleteTree(allocator, store.base_path, "trails", name)) {
            result.revisions_removed += 1;
        }
        // The revision's logs are unreachable once the revision is gone.
        if (deleteTree(allocator, store.base_path, "logs", name) catch false) {
            result.log_dirs_removed += 1;
        }
    }
}

fn removeAgedLogs(allocator: std.mem.Allocator, store: *local_store.LocalStore, keep_try: u64, max_age_s: u64, result: *GcResult) !void {
    var revs_with_logs = std.ArrayList([]u8){};
    defer {
        for (revs_with_logs.items) |n| allocator.free(n);
        revs_with_logs.deinit(allocator);
    }
    try collectRevDirs(allocator, store.base_path, "logs", &revs_with_logs);

    const cutoff_ns = std.time.nanoTimestamp() - @as(i128, @intCast(max_age_s)) * std.time.ns_per_s;
    for (revs_with_logs.items) |name| {
        const num = parseRevNum(name).?;
        if (num == keep_try) continue; // current revision's log is being written to

        const log_file_path = try std.fs.path.join(allocator, &[_][]const u8{ store.base_path, "logs", name, "pantavisor", "pantavisor.log" });
        defer allocator.free(log_file_path);

        const file = std.fs.cwd().openFile(log_file_path, .{}) catch continue;
        defer file.close();
        if ((try file.stat()).mtime >= cutoff_ns) continue;

        if (try deleteTree(allocator, store.base_path, "logs", name)) {
            result.log_dirs_removed += 1;
        }
    }
}

fn removeOrphanObjects(allocator: std.mem.Allocator, store: *local_store.LocalStore, keep_rev: u64, keep_try: u64, result: *GcResult) !void {
    var protected = std.StringHashMap(void).init(allocator);
    defer {
        var kit = protected.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        protected.deinit();
    }

    // Union of the kept revisions' object manifests.
    var have_manifest = false;
    for ([_]u64{ 0, keep_rev, keep_try }) |rev| {
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/trails/{d}/.pvr/objects", .{ store.base_path, rev });
        defer allocator.free(manifest_path);

        const content = std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024) catch continue;
        defer allocator.free(content);
        have_manifest = true;

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            const sha = std.mem.trim(u8, line, " \r\t");
            if (sha.len == 0) continue;
            if (protected.contains(sha)) continue; // don't dupe a key that's already in the set
            try protected.put(try allocator.dupe(u8, sha), {});
        }
    }

    // # ponytail: storages updated before manifests existed keep every object
    // until their next successful update writes one — never mass-delete on a
    // manifest-less storage.
    if (!have_manifest) return;

    const objects_path = try std.fs.path.join(allocator, &[_][]const u8{ store.base_path, "objects" });
    defer allocator.free(objects_path);

    var dir = try std.fs.cwd().openDir(objects_path, .{ .iterate = true });
    defer dir.close();

    var victims = std.ArrayList([]u8){};
    defer {
        for (victims.items) |n| allocator.free(n);
        victims.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue; // .upload-* temp files
        if (protected.contains(entry.name)) continue;
        try victims.append(allocator, try allocator.dupe(u8, entry.name));
    }

    for (victims.items) |name| {
        dir.deleteFile(name) catch continue;
        result.objects_removed += 1;
    }
}

/// Deletes `base/subdir/name`, returning whether the path existed.
/// `fs.deleteTree` is a no-op on missing paths, so callers use the result
/// to keep removal counts honest.
fn deleteTree(allocator: std.mem.Allocator, base: []const u8, subdir: []const u8, name: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ base, subdir, name });
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch return false;
    try std.fs.cwd().deleteTree(path);
    return true;
}

/// Record which objects a revision consists of (one sha256 per line), so the
/// GC can free objects only referenced by deleted revisions. Shared objects
/// are simply listed in several manifests.
pub fn writeObjectsManifest(allocator: std.mem.Allocator, store: *local_store.LocalStore, rev: []const u8, object_ids: []const []const u8) !void {
    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ store.base_path, "trails", rev, ".pvr", "objects" });
    defer allocator.free(manifest_path);

    const file = try std.fs.cwd().createFile(manifest_path, .{});
    defer file.close();
    for (object_ids) |id| {
        try file.writeAll(id);
        try file.writeAll("\n");
    }
}

/// Tag an object to a revision after the fact (pvcontrol uploads land outside
/// the update flow). Best-effort for callers: append failure only makes the
/// object a GC candidate, nothing else depends on the manifest.
pub fn appendObjectToManifest(allocator: std.mem.Allocator, store: *local_store.LocalStore, rev: []const u8, sha: []const u8) !void {
    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ store.base_path, "trails", rev, ".pvr", "objects" });
    defer allocator.free(manifest_path);

    const file = try std.fs.cwd().createFile(manifest_path, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(sha);
    try file.writeAll("\n");
}

test "gc keeps 0/stable/try revisions, their objects and current logs" {
    const allocator = std.testing.allocator;
    const base = "gc_test_storage";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};

    var store = try local_store.LocalStore.init(allocator, base, null, false);
    defer store.deinit();
    try store.set_revision("9");

    // Trails and logs for revisions 0..9.
    for (0..10) |i| {
        const pvr = try std.fmt.allocPrint(allocator, "{s}/trails/{d}/.pvr", .{ base, i });
        defer allocator.free(pvr);
        try std.fs.cwd().makePath(pvr);
        const logdir = try std.fmt.allocPrint(allocator, "{s}/logs/{d}/pantavisor", .{ base, i });
        defer allocator.free(logdir);
        try std.fs.cwd().makePath(logdir);
        const logfile = try std.fmt.allocPrint(allocator, "{s}/pantavisor.log", .{logdir});
        defer allocator.free(logfile);
        try std.fs.cwd().writeFile(.{ .sub_path = logfile, .data = "log\n" });
    }

    // rev 8 needs shaA+shaB, rev 9 needs shaB+shaC; shaD belongs to a deleted revision.
    const sha = "aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff0000000011111111";
    try std.fs.cwd().writeFile(.{ .sub_path = base ++ "/trails/8/.pvr/objects", .data = sha ++ "A\n" ++ sha ++ "B\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = base ++ "/trails/9/.pvr/objects", .data = sha ++ "B\n" ++ sha ++ "C\n" });
    for ([_]u8{ 'A', 'B', 'C', 'D' }) |c| {
        const obj_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}{c}", .{ base, sha, c });
        defer allocator.free(obj_path);
        try std.fs.cwd().writeFile(.{ .sub_path = obj_path, .data = "x" });
    }

    // Age out logs/0 (kept revision, stale log) while logs/9 stays current.
    const old_log = try std.fs.cwd().openFile(base ++ "/logs/0/pantavisor/pantavisor.log", .{ .mode = .read_write });
    try old_log.updateTimes(0, 0); // epoch = ancient
    old_log.close();

    const result = try run(allocator, &store, .{ .interval_s = 1, .logs_max_age_s = 1 });

    // Revisions 1..8 removed; 0 and 9 kept.
    try std.testing.expectEqual(@as(usize, 8), result.revisions_removed);
    try std.testing.expect(std.fs.cwd().access(base ++ "/trails/0/.pvr", .{}) != error.FileNotFound);
    try std.testing.expect(std.fs.cwd().access(base ++ "/trails/9/.pvr", .{}) != error.FileNotFound);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(base ++ "/trails/8/.pvr", .{}));

    // Orphan objects removed, shared and kept-revision objects survive.
    try std.testing.expectEqual(@as(usize, 2), result.objects_removed);
    try std.testing.expect(std.fs.cwd().access(base ++ "/objects/" ++ sha ++ "B", .{}) != error.FileNotFound);
    try std.testing.expect(std.fs.cwd().access(base ++ "/objects/" ++ sha ++ "C", .{}) != error.FileNotFound);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(base ++ "/objects/" ++ sha ++ "A", .{}));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(base ++ "/objects/" ++ sha ++ "D", .{}));

    // Logs: 8 removed with their revisions + logs/0 aged out; current kept.
    try std.testing.expectEqual(@as(usize, 9), result.log_dirs_removed);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(base ++ "/logs/0", .{}));
    try std.testing.expect(std.fs.cwd().access(base ++ "/logs/9/pantavisor/pantavisor.log", .{}) != error.FileNotFound);

    // Legacy safety: with no manifests anywhere, objects are never mass-deleted.
    try std.fs.cwd().deleteTree(base ++ "/trails/9/.pvr/objects");
    try std.fs.cwd().writeFile(.{ .sub_path = base ++ "/objects/orphan", .data = "x" });
    const result2 = try run(allocator, &store, .{ .interval_s = 1, .logs_max_age_s = 1 });
    try std.testing.expectEqual(@as(usize, 0), result2.objects_removed);
    try std.testing.expect(std.fs.cwd().access(base ++ "/objects/orphan", .{}) != error.FileNotFound);
}
