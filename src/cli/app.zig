const std = @import("std");
pub const framework = @import("framework.zig");
const init_mod = @import("init.zig");
const start_mod = @import("start.zig");
const swarm_mod = @import("swarm.zig");

// --- Command Definitions ---

pub const InitCmd = init_mod.InitCmd;
pub const StartCmd = start_mod.StartCmd;
pub const SwarmCmd = swarm_mod.SwarmCmd;

pub const Cli = union(enum) {
    init: InitCmd,
    start: StartCmd,
    swarm: SwarmCmd,

    pub const meta = .{
        .description = "Pantavisor Mocker - Device simulation tool",
    };
};

// --- API ---

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Cli {
    // Skip executable name
    const effective_args = if (args.len > 1) args[1..] else &[_][]const u8{};
    return framework.parse(allocator, Cli, effective_args);
}

pub fn printHelp(exe_name: []const u8) void {
    _ = exe_name;
    // Framework handles help printing based on types
    framework.printHelp(Cli, null) catch {};
}

// --- Tests ---

test {
    _ = @import("framework.zig");
}

test "parse init" {
    const args = &[_][]const u8{ "exe", "init", "-t", "abc", "--host", "p.com" };
    const result = try parse(std.testing.allocator, args);
    try std.testing.expect(result == .init);
    try std.testing.expectEqualStrings("abc", result.init.token.?);
    try std.testing.expectEqualStrings("p.com", result.init.host.?);
}

test "parse start" {
    const args = &[_][]const u8{ "exe", "start", "--debug", "--one-shot" };
    const result = try parse(std.testing.allocator, args);
    try std.testing.expect(result == .start);
    try std.testing.expect(result.start.debug);
    try std.testing.expect(result.start.@"one-shot");
}

test "parse help request" {
    const args = &[_][]const u8{ "exe", "init", "--help" };
    try std.testing.expectError(error.HelpRequested, parse(std.testing.allocator, args));
}

test "parse missing arg" {
    const args = &[_][]const u8{ "exe", "init", "--token" };
    try std.testing.expectError(error.MissingArgument, parse(std.testing.allocator, args));
}

test "parse no-tui flag" {
    const args = &[_][]const u8{ "exe", "start", "--no-tui" };
    const result = try parse(std.testing.allocator, args);
    try std.testing.expect(result == .start);
    try std.testing.expect(result.start.@"no-tui");
}
