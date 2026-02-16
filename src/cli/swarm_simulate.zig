const std = @import("std");

// Module-level state for signal handler cleanup
var g_session_names: []const []const u8 = &.{};
var g_cleanup_done: bool = false;

fn killAllSessions() void {
    if (g_cleanup_done) return;
    g_cleanup_done = true;

    std.debug.print("\nStopping all mocker sessions...\n", .{});
    for (g_session_names) |name| {
        // Use low-level fork+exec since we may be in a signal context
        var child = std.process.Child.init(&.{ "tmux", "kill-session", "-t", name }, std.heap.page_allocator);
        _ = child.spawnAndWait() catch continue;
        std.debug.print("Killed tmux session: {s}\n", .{name});
    }
}

fn sigintHandler(_: c_int) callconv(.c) void {
    killAllSessions();
    std.posix.exit(0);
}

pub const SwarmSimulateCmd = struct {
    dir: []const u8 = ".",

    pub const meta = .{
        .description = "Launch tmux-based simulation for all generated mockers.",
        .args = .{
            .dir = .{ .short = 'd', .help = "Workspace directory." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        // Find all mocker.json files in appliances/ and devices/
        var sessions = std.ArrayList(Session){};
        defer {
            for (sessions.items) |s| {
                allocator.free(s.name);
                allocator.free(s.path);
            }
            sessions.deinit(allocator);
        }

        // Scan appliances and devices directories
        const scan_dirs = [_][]const u8{ "appliances", "devices" };
        for (scan_dirs) |sub_dir| {
            var path_buf: [4096]u8 = undefined;
            const scan_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.dir, sub_dir }) catch continue;

            var dir = std.fs.cwd().openDir(scan_path, .{ .iterate = true }) catch continue;
            defer dir.close();

            var walker = dir.walk(allocator) catch continue;
            defer walker.deinit();

            while (walker.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.eql(u8, entry.basename, "mocker.json")) continue;
                // Skip storage subdirs
                if (std.mem.indexOf(u8, entry.path, "storage/") != null) continue;

                // entry.path is relative to scan_path, e.g. "channel/id/model/config/mocker.json"
                // We need the model dir (two levels up from mocker.json)
                const config_dir = std.fs.path.dirname(entry.path) orelse continue;
                const model_dir_rel = std.fs.path.dirname(config_dir) orelse continue;

                // Full path relative to workspace
                var full_path_buf: [4096]u8 = undefined;
                const model_dir_full = std.fmt.bufPrint(&full_path_buf, "{s}/{s}/{s}", .{ self.dir, sub_dir, model_dir_rel }) catch continue;

                // Build session name from path components
                const model_name = std.fs.path.basename(model_dir_rel);
                const parent_dir_rel = std.fs.path.dirname(model_dir_rel) orelse model_dir_rel;
                const parent_name = std.fs.path.basename(parent_dir_rel);

                var session_name_buf: [256]u8 = undefined;
                const session_name = std.fmt.bufPrint(&session_name_buf, "{s}_{s}", .{ parent_name, model_name }) catch continue;

                // Sanitize session name (replace spaces with underscores)
                var sanitized: [256]u8 = undefined;
                const slen = @min(session_name.len, sanitized.len);
                for (0..slen) |j| {
                    sanitized[j] = if (session_name[j] == ' ') '_' else session_name[j];
                }

                // Check for duplicate session names
                var is_dup = false;
                for (sessions.items) |existing| {
                    if (std.mem.eql(u8, existing.name, sanitized[0..slen])) {
                        is_dup = true;
                        break;
                    }
                }

                var final_name: []const u8 = undefined;
                if (is_dup) {
                    var dedup_buf: [280]u8 = undefined;
                    var rand_bytes: [2]u8 = undefined;
                    std.crypto.random.bytes(&rand_bytes);
                    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
                    const dedup_name = std.fmt.bufPrint(&dedup_buf, "{s}_{s}", .{ sanitized[0..slen], &hex }) catch continue;
                    final_name = allocator.dupe(u8, dedup_name) catch continue;
                } else {
                    final_name = allocator.dupe(u8, sanitized[0..slen]) catch continue;
                }

                const path_dupe = allocator.dupe(u8, model_dir_full) catch {
                    allocator.free(final_name);
                    continue;
                };

                sessions.append(allocator, .{
                    .name = final_name,
                    .path = path_dupe,
                }) catch {
                    allocator.free(final_name);
                    allocator.free(path_dupe);
                    continue;
                };
            }
        }

        if (sessions.items.len == 0) {
            std.debug.print("No mockers found to simulate.\n", .{});
            return;
        }

        // Build a names-only slice for the signal handler
        var name_ptrs = try allocator.alloc([]const u8, sessions.items.len);
        defer allocator.free(name_ptrs);
        for (sessions.items, 0..) |s, i| {
            name_ptrs[i] = s.name;
        }
        g_session_names = name_ptrs;
        g_cleanup_done = false;

        // Install SIGINT and SIGTERM handlers
        var sa: std.posix.Sigaction = .{
            .handler = .{ .handler = sigintHandler },
            .mask = @splat(0),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

        // Launch tmux sessions
        for (sessions.items) |session| {
            std.debug.print("Starting simulation for: {s} (tmux: {s})\n", .{ session.path, session.name });

            var cmd_buf: [8192]u8 = undefined;
            const cmd = std.fmt.bufPrint(&cmd_buf, "pantavisor-mocker start -s \"{s}\"", .{session.path}) catch continue;

            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "tmux", "new-session", "-d", "-s", session.name, "-n", "mocker", cmd },
            }) catch |err| {
                std.debug.print("  Error launching tmux session '{s}': {}\n", .{ session.name, err });
                continue;
            };
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        std.debug.print("\nStarted {d} simulation(s).\n", .{sessions.items.len});

        // Interactive menu loop
        const stdin_file = std.fs.File.stdin();

        while (true) {
            // Show menu
            std.debug.print("\n==========================================\n", .{});
            std.debug.print("   Pantavisor Mocker Simulation Manager   \n", .{});
            std.debug.print("==========================================\n", .{});
            std.debug.print("#   | Tmux Session                        | Path\n", .{});
            std.debug.print("----|------------------------------------|---------------------------------\n", .{});

            for (sessions.items, 0..) |session, idx| {
                // Check if session is still running
                const status = blk: {
                    const check = std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &.{ "tmux", "has-session", "-t", session.name },
                    }) catch break :blk "STOPPED";
                    allocator.free(check.stdout);
                    allocator.free(check.stderr);
                    if (check.term.Exited == 0) break :blk "RUNNING";
                    break :blk "STOPPED";
                };

                std.debug.print("{d:<3} | {s:<34} | [{s:<7}] {s}\n", .{ idx, session.name, status, session.path });
            }

            std.debug.print("------------------------------------------\n", .{});
            std.debug.print("Enter index number or session name to attach.\n", .{});
            std.debug.print("q to Quit (terminates all)\n", .{});
            std.debug.print("==========================================\n", .{});
            std.debug.print("Select > ", .{});

            var input_buf: [256]u8 = undefined;
            const choice = readLine(stdin_file, &input_buf) orelse break;

            if (std.mem.eql(u8, choice, "q") or std.mem.eql(u8, choice, "Q")) {
                break;
            }

            // Try to match by index
            var target_session: ?[]const u8 = null;
            if (std.fmt.parseInt(usize, choice, 10)) |idx| {
                if (idx < sessions.items.len) {
                    target_session = sessions.items[idx].name;
                }
            } else |_| {
                // Try to match by name
                for (sessions.items) |session| {
                    if (std.mem.eql(u8, session.name, choice)) {
                        target_session = session.name;
                        break;
                    }
                }
            }

            if (target_session) |name| {
                std.debug.print("Attaching to session: {s}\n", .{name});
                std.debug.print("Press Ctrl+B then D to detach and return to menu.\n", .{});
                std.Thread.sleep(2 * std.time.ns_per_s);

                // Use inherited stdio so tmux can take over the terminal
                var child = std.process.Child.init(&.{ "tmux", "attach-session", "-t", name }, allocator);
                _ = child.spawnAndWait() catch |err| {
                    std.debug.print("Error attaching to session: {}\n", .{err});
                    continue;
                };
            } else {
                std.debug.print("Invalid selection: '{s}'\n", .{choice});
                std.Thread.sleep(2 * std.time.ns_per_s);
            }
        }

        // Normal exit cleanup (q or EOF)
        killAllSessions();
    }

    fn readLine(file: std.fs.File, buf: []u8) ?[]const u8 {
        var pos: usize = 0;
        while (pos < buf.len) {
            const n = file.read(buf[pos .. pos + 1]) catch return null;
            if (n == 0) return null;
            if (buf[pos] == '\n') {
                return std.mem.trim(u8, buf[0..pos], " \t\r");
            }
            pos += 1;
        }
        return std.mem.trim(u8, buf[0..pos], " \t\r");
    }

    const Session = struct {
        name: []const u8,
        path: []const u8,
    };
};
