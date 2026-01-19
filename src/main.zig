const std = @import("std");
pub const core_mocker = @import("core/mocker.zig");
pub const local_store = @import("storage/local_store.zig");
pub const curl_mod = @import("net/curl.zig");
pub const constants = @import("core/constants.zig");
pub const tui_renderer = @import("ui/tui_renderer.zig");
pub const stdinout_renderer = @import("ui/stdinout_renderer.zig");
pub const logger_subsystem = @import("ui/logger_subsystem.zig");
pub const router_mod = @import("core/router.zig");
const ipc = @import("core/ipc.zig");

// Backwards compatibility for tests
pub const config = @import("core/config.zig");
pub const logger = @import("ui/logger.zig");
pub const update_flow = @import("flows/update_flow.zig");
pub const client_mod = @import("net/client.zig");
pub const meta_mod = @import("core/meta.zig");
pub const log_pusher = @import("net/log_pusher.zig");
pub const invitation = @import("flows/invitation.zig");
pub const tui = @import("ui/tui.zig");
pub const business_logic = @import("core/business_logic.zig");
pub const validation = @import("core/validation.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) @panic("Memory leak detected");
    }
    const allocator = gpa.allocator();

    // Initialize Curl Global
    try curl_mod.Curl.global_init();
    defer curl_mod.Curl.global_cleanup();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print_help(args[0]);
        return;
    }

    try app_main(allocator, args);
}

fn app_main(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var storage_path: []const u8 = constants.DEFAULT_STORAGE_PATH;
    var is_init = false;
    var is_start = false;
    var is_one_shot = false;
    var is_debug = false;
    var use_tui = true;
    var init_token: ?[]const u8 = null;
    var ph_host: ?[]const u8 = null;
    var ph_port: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "init")) {
            is_init = true;
        } else if (std.mem.eql(u8, args[i], "start")) {
            is_start = true;
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            print_help(args[0]);
            return;
        } else if (std.mem.eql(u8, args[i], "-s") or std.mem.eql(u8, args[i], "--storage")) {
            if (i + 1 < args.len) {
                storage_path = args[i + 1];
                i += 1;
            } else {
                std.debug.print("Error: Missing argument for {s}\n", .{args[i]});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "--token")) {
            if (i + 1 < args.len) {
                init_token = args[i + 1];
                i += 1;
            } else {
                std.debug.print("Error: Missing argument for {s}\n", .{args[i]});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, args[i], "--host")) {
            if (i + 1 < args.len) {
                ph_host = args[i + 1];
                i += 1;
            } else {
                std.debug.print("Error: Missing argument for {s}\n", .{args[i]});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, args[i], "--port")) {
            if (i + 1 < args.len) {
                ph_port = args[i + 1];
                i += 1;
            } else {
                std.debug.print("Error: Missing argument for {s}\n", .{args[i]});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, args[i], "--one-shot")) {
            is_one_shot = true;
        } else if (std.mem.eql(u8, args[i], "--debug")) {
            is_debug = true;
        } else if (std.mem.eql(u8, args[i], "--no-tui")) {
            use_tui = false;
        } else {
            std.debug.print("Error: Unknown argument: {s}\n", .{args[i]});
            print_help(args[0]);
            return error.InvalidArgs;
        }
    }

    if (is_init) {
        var store = try local_store.LocalStore.init(allocator, storage_path, init_token, true);
        defer store.deinit();

        if (ph_host) |host| {
            try store.save_config_value("PH_CREDS_HOST", host);
        }
        if (ph_port) |port| {
            try store.save_config_value("PH_CREDS_PORT", port);
        }

        std.debug.print("Storage initialized at {s}\n", .{storage_path});
        return;
    }

    if (!is_start) {
        print_help(args[0]);
        return;
    }

    var mocker = core_mocker.Mocker.init(allocator, storage_path, is_one_shot, is_debug);
    defer mocker.deinit();

    const socket_path_str = try std.fs.path.join(allocator, &[_][]const u8{ storage_path, "mocker.sock" });
    defer allocator.free(socket_path_str);

    // 1. Initialize and Start Router (FOUNDATION)
    var router = try router_mod.Router.init(allocator, socket_path_str, &mocker.quit_flag);
    defer router.deinit();
    const router_thread = try std.Thread.spawn(.{}, router_mod.Router.run, .{&router});

    // Wait a bit for router to bind
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // 2. Start logger subsystem (Depends on Router)
    var log_sub = try logger_subsystem.LoggerSubsystem.init(allocator, socket_path_str, storage_path, &mocker.quit_flag);
    const log_thread = try std.Thread.spawn(.{}, logger_subsystem.LoggerSubsystem.run, .{&log_sub});

    // 3. Start background task (Mocker) in separate thread (Depends on Router)
    // It will connect to router and wait for 'subsystem_start' signal which comes after Renderer/Logger are READY
    const bg_thread = try std.Thread.spawn(.{}, mocker_run_wrapper, .{&mocker});

    // Internal watchdog for one-shot mode
    var watchdog_thread: ?std.Thread = null;
    if (is_one_shot) {
        const watchdog = struct {
            fn run(q: *std.atomic.Value(bool), socket_path: []const u8, alloc: std.mem.Allocator) void {
                var wd_i: usize = 0;
                while (wd_i < 100) : (wd_i += 1) {
                    if (q.load(.acquire)) return;
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                }

                if (!q.load(.acquire)) {
                    // Try to send stop message to renderer
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

    // 4. Start Renderer (Depends on Router)
    if (use_tui) {
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

fn mocker_run_wrapper(mocker: *core_mocker.Mocker) void {
    mocker.runBackground() catch {};
}

const help_text =
    "Usage: {s} [command] [options]\n" ++
    "\n" ++
    "Commands:\n" ++
    "  init                 Setup the \"mock device\" (initialize storage and register).\n" ++
    "  start                Start the main mocker process.\n" ++
    "\n" ++
    "Options:\n" ++
    "  -h, --help           Show this help message and exit.\n" ++
    "  -s, --storage PATH   Path to the storage directory (default: \"storage\").\n" ++
    "  -t, --token TOKEN    Factory autotoken for registration (used with init).\n" ++
    "  --host HOST          Set Pantahub API host (used with init).\n" ++
    "  --port PORT          Set Pantahub API port (used with init).\n" ++
    "  --one-shot           Run a single cycle of the main loop and exit (useful for testing).\n" ++
    "  --debug              Enable debug logging.\n" ++
    "  --no-tui             Disable TUI mode.\n";

fn print_help(exe_name: []const u8) void {
    std.debug.print(help_text, .{exe_name});
}
