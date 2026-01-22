const std = @import("std");
const constants = @import("../core/constants.zig");
const core_mocker = @import("../core/mocker.zig");
const router_mod = @import("../core/router.zig");
const logger_subsystem = @import("../core/logger_subsystem.zig");
const tui_renderer = @import("../ui/tui_renderer.zig");
const stdinout_renderer = @import("../ui/stdinout_renderer.zig");
const ipc = @import("../core/ipc.zig");

pub const StartCmd = struct {
    storage: []const u8 = constants.DEFAULT_STORAGE_PATH,
    @"one-shot": bool = false,
    debug: bool = false,
    @"no-tui": bool = false,

    pub const meta = .{
        .description = "Start the main mocker process.",
        .args = .{
            .storage = .{ .short = 's', .help = "Path to the storage directory." },
            .@"one-shot" = .{ .help = "Run a single cycle of the main loop and exit." },
            .debug = .{ .help = "Enable debug logging." },
            .@"no-tui" = .{ .help = "Disable TUI mode." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        var mocker = core_mocker.Mocker.init(allocator, self.storage, self.@"one-shot", self.debug);
        defer mocker.deinit();

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
        {
            const dummy = std.net.connectUnixSocket(socket_path_str) catch null;
            if (dummy) |c| c.close();
        }
        router_thread.join();

        bg_thread.join();
        log_sub.deinit();
        log_thread.join();
    }
};

fn mocker_run_wrapper(mocker: *core_mocker.Mocker) void {
    mocker.runBackground() catch {};
}
