const std = @import("std");
const constants = @import("../core/constants.zig");
const core_mocker = @import("../core/mocker.zig");
const router_mod = @import("../core/router.zig");
const logger_subsystem = @import("../core/logger_subsystem.zig");
const tui_renderer = @import("../ui/tui_renderer.zig");
const stdinout_renderer = @import("../ui/stdinout_renderer.zig");
const ipc = @import("../core/ipc.zig");
const c = @cImport({
    @cInclude("signal.h");
    @cInclude("sys/signalfd.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
});

const SignalWatcher = struct {
    thread: std.Thread,
    quit_flag: *std.atomic.Value(bool),

    fn init(quit_flag: *std.atomic.Value(bool)) !SignalWatcher {
        // Block signals so the listener thread can catch them with signalfd
        var mask: c.sigset_t = undefined;
        _ = c.sigemptyset(&mask);
        _ = c.sigaddset(&mask, c.SIGINT);
        _ = c.sigaddset(&mask, c.SIGTERM);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &mask, null);

        const thread = try std.Thread.spawn(.{}, run, .{quit_flag});
        return .{ .thread = thread, .quit_flag = quit_flag };
    }

    fn run(quit_flag: *std.atomic.Value(bool)) void {
        var mask: c.sigset_t = undefined;
        _ = c.sigemptyset(&mask);
        _ = c.sigaddset(&mask, c.SIGINT);
        _ = c.sigaddset(&mask, c.SIGTERM);

        const fd = c.signalfd(-1, &mask, c.SFD_CLOEXEC);
        if (fd == -1) {
            std.debug.print("SignalWatcher: failed to create signalfd\n", .{});
            return;
        }
        defer _ = c.close(fd);

        while (!quit_flag.load(.acquire)) {
            var fds = [1]c.struct_pollfd{.{
                .fd = fd,
                .events = c.POLLIN,
                .revents = 0,
            }};
            // Poll with timeout to allow checking quit_flag
            const n = c.poll(&fds, 1, 500);
            if (n > 0 and (fds[0].revents & c.POLLIN) != 0) {
                // Signal received
                quit_flag.store(true, .release);
                return;
            }
        }
    }

    fn deinit(self: *SignalWatcher) void {
        self.thread.join();
    }
};

pub const StartCmd = struct {
    storage: []const u8 = constants.DEFAULT_STORAGE_PATH,
    @"one-shot": bool = false,
    debug: bool = false,
    @"no-tui": bool = false,
    auto: bool = false,

    pub const meta = .{
        .description = "Start the main mocker process.",
        .args = .{
            .storage = .{ .short = 's', .help = "Path to the storage directory." },
            .@"one-shot" = .{ .help = "Run a single cycle of the main loop and exit." },
            .debug = .{ .help = "Enable debug logging." },
            .@"no-tui" = .{ .help = "Disable TUI mode." },
            .auto = .{ .short = 'a', .help = "Enable automation mode (auto-respond to invitations/updates based on mocker.json config)." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        var mocker = core_mocker.Mocker.init(allocator, self.storage, self.@"one-shot", self.debug, self.auto);
        defer mocker.deinit();

        // Signal handler for clean shutdown
        var signal_watcher = SignalWatcher.init(&mocker.quit_flag) catch |err| {
            std.debug.print("Failed to initialize SignalWatcher: {}\n", .{err});
            return err;
        };
        defer signal_watcher.deinit();

        const socket_path_str = try std.fs.path.join(allocator, &[_][]const u8{ self.storage, "mocker.sock" });
        defer allocator.free(socket_path_str);

        // 1. Initialize and Start Router (FOUNDATION)
        var router = try router_mod.Router.init(allocator, socket_path_str, &mocker.quit_flag);
        defer router.deinit();
        const router_thread = try std.Thread.spawn(.{}, router_mod.Router.run, .{&router});

        // Wait a bit for router to bind
        std.Thread.sleep(50 * std.time.ns_per_ms);

        // 2. Start logger subsystem (Depends on Router)
        var log_sub = try logger_subsystem.LoggerSubsystem.init(allocator, socket_path_str, self.storage, &mocker.quit_flag);
        const log_thread = try std.Thread.spawn(.{}, logger_subsystem.LoggerSubsystem.run, .{&log_sub});

        // 3. Start background task (Mocker) in separate thread (Depends on Router)
        const bg_thread = try std.Thread.spawn(.{}, mocker_run_wrapper, .{&mocker});

        // Internal watchdog for one-shot mode
        var watchdog_thread: ?std.Thread = null;
        if (self.@"one-shot") {
            const watchdog = struct {
                fn run(q: *std.atomic.Value(bool), socket_path: []const u8, alloc: std.mem.Allocator) void {
                    var wd_i: usize = 0;
                    while (wd_i < 100) : (wd_i += 1) {
                        if (q.load(.acquire)) return;
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                    }

                    if (!q.load(.acquire)) {
                        if (ipc.IpcClient.init(alloc, socket_path, .core)) |mut_client| {
                            var client = mut_client;
                            client.sendMessage(.renderer, .subsystem_stop, null) catch {};
                            client.deinit();
                        } else |_| {}

                        std.Thread.sleep(1 * std.time.ns_per_s);
                        q.store(true, .release);
                    }
                }
            }.run;
            watchdog_thread = try std.Thread.spawn(.{}, watchdog, .{ &mocker.quit_flag, socket_path_str, allocator });
        }
        defer if (watchdog_thread) |t| t.join();

        // 4. Start Renderer
        if (!self.@"no-tui") {
            var renderer = try tui_renderer.TuiRenderer.init(allocator, &mocker.quit_flag);
            errdefer renderer.deinit();
            // Retry connection loop
            var connected = false;
            var attempts: usize = 0;
            while (!connected and attempts < 50) : (attempts += 1) {
                renderer.connect(socket_path_str) catch |err| {
                    if (err == error.FileNotFound or err == error.ConnectionRefused) {
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                        continue;
                    }
                    return err;
                };
                connected = true;
            }
            if (!connected) return error.ConnectionFailed;

            try renderer.run();
            renderer.deinit();
        } else {
            var renderer = try stdinout_renderer.StdInOutRenderer.init(allocator, &mocker.quit_flag);
            errdefer renderer.deinit();
            // Retry connection loop
            var connected = false;
            var attempts: usize = 0;
            while (!connected and attempts < 50) : (attempts += 1) {
                renderer.connect(socket_path_str) catch |err| {
                    if (err == error.FileNotFound or err == error.ConnectionRefused) {
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                        continue;
                    }
                    return err;
                };
                connected = true;
            }
            if (!connected) return error.ConnectionFailed;

            while (!mocker.quit_flag.load(.acquire)) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
            renderer.deinit();
        }

        // Cleanup phase
        mocker.quit_flag.store(true, .release);

        // Wake up Router from accept()
        router.requestShutdown();
        router_thread.join();

        bg_thread.join();
        log_sub.deinit();
        log_thread.join();
    }
};

fn mocker_run_wrapper(mocker: *core_mocker.Mocker) void {
    mocker.runBackground() catch |err| {
        std.debug.print("Background task failed: {any}\n", .{err});
        mocker.quit_flag.store(true, .release);
    };
}
