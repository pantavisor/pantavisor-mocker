const std = @import("std");
const c = @cImport({
    @cInclude("signal.h");
    @cInclude("sys/signalfd.h");
    @cInclude("unistd.h");
});

var g_session_names: []const []const u8 = &.{};
var g_cleanup_done = std.atomic.Value(bool).init(false);

/// Simulation log file for tracking device start/stop events
const SimulationLog = struct {
    file: ?std.fs.File,
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, workspace_dir: []const u8) Self {
        var path_buf: [4096]u8 = undefined;
        const log_path = std.fmt.bufPrint(&path_buf, "{s}/simulation.log", .{workspace_dir}) catch {
            return .{ .file = null, .allocator = allocator, .workspace_dir = workspace_dir };
        };

        const file = std.fs.cwd().createFile(log_path, .{ .truncate = false }) catch {
            return .{ .file = null, .allocator = allocator, .workspace_dir = workspace_dir };
        };

        // Seek to end to append
        file.seekFromEnd(0) catch {};

        return .{ .file = file, .allocator = allocator, .workspace_dir = workspace_dir };
    }

    pub fn deinit(self: *Self) void {
        if (self.file) |f| {
            f.close();
        }
    }

    fn writeLog(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const f = self.file orelse return;
        var buf: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&buf, fmt, args)) |written| {
            f.writeAll(written) catch |err| {
                std.debug.print("Error writing to simulation.log: {}\n", .{err});
            };
        } else |err| {
            std.debug.print("Error formatting log message: {}\n", .{err});
        }
    }

    fn getTimestamp(self: *Self, ts_buf: *[32]u8) []const u8 {
        _ = self;
        const now = std.time.timestamp();
        const epoch_secs: u64 = @intCast(now);
        const epoch_day = epoch_secs / 86400;
        const day_secs = epoch_secs % 86400;
        const hour = day_secs / 3600;
        const minute = (day_secs % 3600) / 60;
        const second = day_secs % 60;

        // Calculate date from epoch days (simplified, assumes 1970-01-01 epoch)
        var days_remaining = epoch_day;
        var year: u32 = 1970;
        while (true) {
            const days_in_year: u64 = if (isLeapYear(year)) 366 else 365;
            if (days_remaining < days_in_year) break;
            days_remaining -= days_in_year;
            year += 1;
        }
        const month_days = if (isLeapYear(year))
            [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
        else
            [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        var month: u8 = 1;
        for (month_days) |days| {
            if (days_remaining < days) break;
            days_remaining -= days;
            month += 1;
        }
        const day: u8 = @intCast(days_remaining + 1);

        const ts = std.fmt.bufPrint(ts_buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year, month, day, hour, minute, second,
        }) catch return "????-??-?? ??:??:??";
        return ts;
    }

    fn isLeapYear(year: u32) bool {
        return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    }

    pub fn logStart(self: *Self, session_name: []const u8, path: []const u8, auto_mode: bool) void {
        var ts_buf: [32]u8 = undefined;
        const ts = self.getTimestamp(&ts_buf);
        self.writeLog("[{s}] START session=\"{s}\" path=\"{s}\" auto={}\n", .{
            ts, session_name, path, auto_mode,
        });
    }

    pub fn logStop(self: *Self, session_name: []const u8, path: []const u8, reason: []const u8) void {
        var ts_buf: [32]u8 = undefined;
        const ts = self.getTimestamp(&ts_buf);
        self.writeLog("[{s}] STOP  session=\"{s}\" path=\"{s}\" reason=\"{s}\"\n", .{
            ts, session_name, path, reason,
        });
    }

    pub fn logError(self: *Self, session_name: []const u8, message: []const u8) void {
        var ts_buf: [32]u8 = undefined;
        const ts = self.getTimestamp(&ts_buf);
        self.writeLog("[{s}] ERROR session=\"{s}\" message=\"{s}\"\n", .{
            ts, session_name, message,
        });
    }

    pub fn logInfo(self: *Self, message: []const u8) void {
        var ts_buf: [32]u8 = undefined;
        const ts = self.getTimestamp(&ts_buf);
        self.writeLog("[{s}] INFO  {s}\n", .{ ts, message });
    }

    /// Capture last lines from tmux pane to understand why session stopped
    pub fn captureSessionOutput(self: *Self, session_name: []const u8) []const u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "tmux", "capture-pane", "-t", session_name, "-p", "-S", "-50" },
        }) catch {
            return "unable to capture output";
        };
        defer self.allocator.free(result.stderr);

        if (result.stdout.len > 0) {
            // Find the last non-empty lines as reason
            const trimmed = std.mem.trimRight(u8, result.stdout, " \t\n\r");
            if (trimmed.len > 0) {
                // Find last line
                if (std.mem.lastIndexOf(u8, trimmed, "\n")) |idx| {
                    const last_line = std.mem.trim(u8, trimmed[idx + 1 ..], " \t\r");
                    if (last_line.len > 0) {
                        const dupe = self.allocator.dupe(u8, last_line) catch {
                            self.allocator.free(result.stdout);
                            return "memory allocation failed";
                        };
                        self.allocator.free(result.stdout);
                        return dupe;
                    }
                }
            }
            self.allocator.free(result.stdout);
        }
        return "session ended (no output captured)";
    }
};

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
        // Initialize simulation log
        var sim_log = SimulationLog.init(allocator, self.dir);
        defer sim_log.deinit();

        var log_msg_buf: [512]u8 = undefined;
        const start_msg = std.fmt.bufPrint(&log_msg_buf, "Simulation started in workspace: {s}", .{self.dir}) catch "Simulation started";
        sim_log.logInfo(start_msg);

        var sessions = std.ArrayList(Session){};
        defer {
            for (sessions.items) |s| {
                allocator.free(s.name);
                allocator.free(s.path);
            }
            sessions.deinit(allocator);
        }

        // Track previous status for change detection
        var previous_status = std.StringHashMap(bool).init(allocator);
        defer previous_status.deinit();

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
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Failed to launch tmux session: {}", .{err}) catch "Failed to launch";
                sim_log.logError(session.name, err_msg);
                continue;
            };
            allocator.free(result.stdout);
            allocator.free(result.stderr);

            // Log successful start
            sim_log.logStart(session.name, session.path, self.auto);
            previous_status.put(session.name, true) catch {};
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
                const is_running = blk: {
                    const check = std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &.{ "tmux", "has-session", "-t", session.name },
                    }) catch break :blk false;
                    allocator.free(check.stdout);
                    allocator.free(check.stderr);
                    break :blk (check.term.Exited == 0);
                };

                const status = if (is_running) "RUNNING" else "STOPPED";

                // Detect state change: was running, now stopped
                if (previous_status.get(session.name)) |was_running| {
                    if (was_running and !is_running) {
                        // Session just stopped - capture reason and log
                        const reason = sim_log.captureSessionOutput(session.name);
                        defer if (!std.mem.eql(u8, reason, "unable to capture output") and
                            !std.mem.eql(u8, reason, "session ended (no output captured)") and
                            !std.mem.eql(u8, reason, "memory allocation failed"))
                        {
                            allocator.free(@constCast(reason));
                        };
                        sim_log.logStop(session.name, session.path, reason);
                    }
                }
                previous_status.put(session.name, is_running) catch {};

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
                    sim_log.logInfo("Signal received (Ctrl+C) - stopping all sessions");
                    break;
                }
                break;
            } orelse break;

            if (std.mem.eql(u8, choice, "q") or std.mem.eql(u8, choice, "Q")) {
                sim_log.logInfo("User requested quit - stopping all sessions");
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
