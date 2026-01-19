const std = @import("std");
const app = @import("app");

test "cli framework - struct parsing" {
    const TestStruct = struct {
        foo: bool = false,
        bar: []const u8 = "default",
        pub const meta = .{
            .args = .{
                .foo = .{ .short = 'f' },
            },
        };
    };

    const args1 = &[_][]const u8{ "--foo", "--bar", "baz" };
    // We can't use framework.parse directly because it's in another module and not pub?
    // Let's check if it's pub. Yes, it is.
    const res1 = try app.cli_args.framework.parse(std.testing.allocator, TestStruct, args1);
    try std.testing.expect(res1.foo);
    try std.testing.expectEqualStrings("baz", res1.bar);
}

test "cli framework - union parsing" {
    const Sub = struct {
        val: []const u8 = "",
    };
    const TestUnion = union(enum) {
        sub: Sub,
    };

    const args = &[_][]const u8{ "sub", "--val", "hello" };
    const res = try app.cli_args.framework.parse(std.testing.allocator, TestUnion, args);
    try std.testing.expect(res == .sub);
    try std.testing.expectEqualStrings("hello", res.sub.val);
}

test "cli args - init parsing" {
    const args = &[_][]const u8{ "exe", "init", "-t", "abc", "--host", "p.com" };
    const result = try app.cli_args.parse(std.testing.allocator, args);
    try std.testing.expect(result == .init);
    try std.testing.expectEqualStrings("abc", result.init.token.?);
    try std.testing.expectEqualStrings("p.com", result.init.host.?);
}

test "cli args - start parsing" {
    const args = &[_][]const u8{ "exe", "start", "--debug", "--one-shot" };
    const result = try app.cli_args.parse(std.testing.allocator, args);
    try std.testing.expect(result == .start);
    try std.testing.expect(result.start.debug);
    try std.testing.expect(result.start.@"one-shot");
}

test "cli args - help request" {
    const args = &[_][]const u8{ "exe", "init", "--help" };
    try std.testing.expectError(error.HelpRequested, app.cli_args.parse(std.testing.allocator, args));
}
