const std = @import("std");
pub const curl_mod = @import("net/curl.zig");
pub const cli_app = @import("cli/app.zig");

// Backwards compatibility exports for tests
pub const core_mocker = @import("core/mocker.zig");
pub const local_store = @import("core/local_store.zig");
pub const constants = @import("core/constants.zig");
pub const tui_renderer = @import("ui/tui_renderer.zig");
pub const stdinout_renderer = @import("ui/stdinout_renderer.zig");
pub const logger_subsystem = @import("core/logger_subsystem.zig");
pub const router_mod = @import("core/router.zig");

// Backwards compatibility for tests
pub const config = @import("core/config.zig");
pub const logger = @import("core/logger.zig");
pub const update_flow = @import("flows/update_flow.zig");
pub const client_mod = @import("net/client.zig");
pub const meta_mod = @import("core/meta.zig");
pub const log_pusher = @import("net/log_pusher.zig");
pub const invitation = @import("flows/invitation.zig");
pub const tui = @import("ui/tui.zig");
pub const business_logic = @import("core/business_logic.zig");
pub const validation = @import("core/validation.zig");

test {
    _ = @import("cli/app.zig");
}

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
        cli_app.printHelp(args[0]);
        return;
    }

    // Skip executable name for framework
    const effective_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    cli_app.framework.execute(allocator, cli_app.Cli, effective_args) catch |err| {
        if (err == error.HelpRequested) return;
        // Errors are printed in parse
        if (err == error.UnknownCommand or err == error.MissingArgument or err == error.InvalidArgument or err == error.NoCommandProvided) {
            // help is already printed by framework on unknown command
            return;
        }
        return err;
    };
}

