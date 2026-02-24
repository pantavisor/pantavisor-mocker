const std = @import("std");
const c = @cImport({
    @cInclude("signal.h");
    @cInclude("sys/signalfd.h");
    @cInclude("unistd.h");
});

var g_session_names: []const []const u8 = &.{};
var g_cleanup_done = std.atomic.Value(bool).init(false);

fn killAllSessions(allocator: std.mem.Allocator) void {
    if (g_cleanup_done.load(.acquire)) return;
    g_cleanup_done.store(true, .release);

    std.log.info("Stopping all mocker sessions...", .{});
    for (g_session_names) |name| {
        var child = std.process.Child.init(&.{ "tmux", "kill-session", "-t", name }, allocator);
        _ = child.spawnAndWait() catch continue;
        std.log.info("Killed tmux session: {s}", .{name});
    }
}

pub const SwarmSimulateCmd = struct {
    dir: []const u8 = ".",
    auto: bool = false,

    pub const meta = .{
        .description = "Launch tmux-based simulation for all generated mockers.",
        .args = .{
            .dir = .{ .short = 'd', .help = "Workspace directory." },
            .auto = .{ .short = 'a', .help = "Enable automation mode for all simulated devices (auto-respond based on mocker.json config)." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        var sessions = std.ArrayList(Session){};
        defer {
            for (sessions.items) |s| {
                allocator.free(s.name);
                allocator.free(s.path);
            }
            sessions.deinit(allocator);
        }

        var root_dir = std.fs.cwd().openDir(self.dir, .{ .iterate = true }) catch |err| {
            std.debug.print("Error opening directory '{s}': {}\n", .{ self.dir, err });
            return;
        };
        defer root_dir.close();

        var walker = root_dir.walk(allocator) catch |err| {
            std.debug.print("Error walking directory '{s}': {}\n", .{ self.dir, err });
            return;
        };
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, entry.basename, "mocker.json")) continue;
            if (std.mem.indexOf(u8, entry.path, "storage/") != null) continue;

            const config_dir = std.fs.path.dirname(entry.path) orelse continue;
            const model_dir_rel = std.fs.path.dirname(config_dir) orelse continue;

            var full_path_buf: [4096]u8 = undefined;
            const model_dir_full = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ self.dir, model_dir_rel }) catch continue;

            const model_name = std.fs.path.basename(model_dir_rel);
            const parent_dir_rel = std.fs.path.dirname(model_dir_rel) orelse model_dir_rel;
            const parent_name = std.fs.path.basename(parent_dir_rel);

            var session_name_buf: [256]u8 = undefined;
            const session_name = if (std.mem.eql(u8, parent_name, model_name))
                try std.fmt.bufPrint(&session_name_buf, "{s}", .{model_name})
            else
                try std.fmt.bufPrint(&session_name_buf, "{s}_{s}", .{ parent_name, model_name });

            var sanitized: [256]u8 = undefined;
            const slen = @min(session_name.len, sanitized.len);
            for (0..slen) |j| {
                const ch = session_name[j];
                sanitized[j] = if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') ch else '_';
            }

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

        if (sessions.items.len == 0) {
            std.debug.print("No mockers found to simulate.\n", .{});
            return;
        }

        var name_ptrs = try allocator.alloc([]const u8, sessions.items.len);
        defer allocator.free(name_ptrs);
        for (sessions.items, 0..) |s, i| {
            name_ptrs[i] = s.name;
        }
        g_session_names = name_ptrs;
        g_cleanup_done.store(false, .release);

        var mask: c.sigset_t = undefined;
        _ = c.sigemptyset(&mask);
        _ = c.sigaddset(&mask, c.SIGINT);
        _ = c.sigaddset(&mask, c.SIGTERM);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &mask, null);

        const signal_fd = c.signalfd(-1, &mask, c.SFD_CLOEXEC);
        if (signal_fd == -1) {
            std.debug.print("Error creating signalfd\n", .{});
            return;
        }
        defer _ = c.close(signal_fd);

        const exe_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(exe_path);

        for (sessions.items) |session| {
            std.debug.print("Starting simulation for: {s} (tmux: {s}){s}\n", .{
                session.path,
                session.name,
                if (self.auto) " [AUTO]" else "",
            });

            var cmd_buf: [8192]u8 = undefined;
            const cmd = if (self.auto)
                std.fmt.bufPrint(&cmd_buf, "\"{s}\" start -s \"{s}\" --auto", .{ exe_path, session.path }) catch continue
            else
                std.fmt.bufPrint(&cmd_buf, "\"{s}\" start -s \"{s}\"", .{ exe_path, session.path }) catch continue;

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

        std.debug.print("\nStarted {d} simulation(s){s}.\n", .{
            sessions.items.len,
            if (self.auto) " in AUTOMATION mode" else "",
        });

        const stdin_file = std.fs.File.stdin();

        while (true) {
            std.debug.print("\n==========================================\n", .{});
            std.debug.print("   Pantavisor Mocker Simulation Manager   \n", .{});
            std.debug.print("==========================================\n", .{});
            std.debug.print("#   | Tmux Session                        | Path\n", .{});
            std.debug.print("----|------------------------------------|---------------------------------\n", .{});

            for (sessions.items, 0..) |session, idx| {
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
            const choice = readLine(stdin_file, signal_fd, &input_buf) catch |err| {
                if (err == error.SignalReceived) {
                    std.log.info("Signal received, cleaning up...", .{});
                    break;
                }
                break;
            } orelse break;

            if (std.mem.eql(u8, choice, "q") or std.mem.eql(u8, choice, "Q")) {
                break;
            }

            var target_session: ?[]const u8 = null;
            if (std.fmt.parseInt(usize, choice, 10)) |idx| {
                if (idx < sessions.items.len) {
                    target_session = sessions.items[idx].name;
                }
            } else |_| {
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

        killAllSessions(allocator);
    }

    fn readLine(file: std.fs.File, signal_fd: c_int, buf: []u8) !?[]const u8 {
        var pos: usize = 0;
        while (pos < buf.len) {
            var fds = [2]std.posix.pollfd{
                .{
                    .fd = file.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
                .{
                    .fd = signal_fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            };

            const ready = std.posix.poll(&fds, -1) catch |err| {
                if (err == error.Interrupted) continue;
                return err;
            };

            if (ready == 0) continue;

            if (fds[1].revents != 0) {
                return error.SignalReceived;
            }

            const n = try file.read(buf[pos .. pos + 1]);
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
