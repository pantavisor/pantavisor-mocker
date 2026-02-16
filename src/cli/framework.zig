const std = @import("std");

pub fn execute(allocator: std.mem.Allocator, comptime T: type, args: []const []const u8) !void {
    const cmd = try parse(allocator, T, args);
    try runCommand(allocator, cmd);
}

fn runCommand(allocator: std.mem.Allocator, cmd: anytype) !void {
    const T = @TypeOf(cmd);
    switch (@typeInfo(T)) {
        .@"union" => {
            switch (cmd) {
                inline else => |payload| try runCommand(allocator, payload),
            }
        },
        .@"struct" => {
            if (@hasDecl(T, "run")) {
                try cmd.run(allocator);
            } else {
                // If no run method, maybe just print help or do nothing?
                // Or maybe it's a leaf command without logic yet?
                std.debug.print("Command {s} has no run() method.\n", .{@typeName(T)});
            }
        },
        else => {},
    }
}

pub fn parse(allocator: std.mem.Allocator, comptime T: type, args: []const []const u8) !T {
    // If it's a union, we expect a subcommand
    switch (@typeInfo(T)) {
        .@"union" => |u_info| {
            if (args.len == 0) {
                try printHelp(T, null);
                return error.HelpRequested;
            }
            const cmd_name = args[0];
            const remaining_args = args[1..];

            // Check for help first
            if (std.mem.eql(u8, cmd_name, "-h") or std.mem.eql(u8, cmd_name, "--help")) {
                try printHelp(T, null);
                return error.HelpRequested;
            }

            inline for (u_info.fields) |field| {
                if (std.mem.eql(u8, field.name, cmd_name)) {
                    const sub_result = try parse(allocator, field.type, remaining_args);
                    return @unionInit(T, field.name, sub_result);
                }
            }
            std.debug.print("Error: Unknown command '{s}'\n", .{cmd_name});
            try printHelp(T, null);
            return error.UnknownCommand;
        },
        .@"struct" => |s_info| {
            // It's a command with flags
            var result: T = .{};

            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const arg = args[i];

                if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                    try printHelp(T, null);
                    return error.HelpRequested;
                }

                if (std.mem.startsWith(u8, arg, "-")) {
                    var matched = false;
                    inline for (s_info.fields) |field| {
                        // Check for meta configuration for this field
                        const meta = if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta.args), field.name))
                            @field(T.meta.args, field.name)
                        else
                            struct {}{};

                        const short_char: ?u8 = if (@hasField(@TypeOf(meta), "short")) meta.short else null;

                        // Check match (long or short)
                        const is_long = std.mem.startsWith(u8, arg, "--") and std.mem.eql(u8, arg[2..], field.name);
                        const is_short = if (short_char) |c| (std.mem.startsWith(u8, arg, "-") and arg.len == 2 and arg[1] == c) else false;

                        if (is_long or is_short) {
                            matched = true;
                            // Parse value based on type
                            if (field.type == bool) {
                                @field(result, field.name) = true;
                            } else if (field.type == []const u8 or field.type == ?[]const u8) {
                                if (i + 1 >= args.len) {
                                    std.debug.print("Error: Missing argument for {s}\n", .{arg});
                                    return error.MissingArgument;
                                }
                                @field(result, field.name) = args[i + 1];
                                i += 1;
                            } else if (@typeInfo(field.type) == .int or
                                (@typeInfo(field.type) == .optional and @typeInfo(@typeInfo(field.type).optional.child) == .int))
                            {
                                if (i + 1 >= args.len) {
                                    std.debug.print("Error: Missing argument for {s}\n", .{arg});
                                    return error.MissingArgument;
                                }
                                const IntType = if (@typeInfo(field.type) == .optional)
                                    @typeInfo(field.type).optional.child
                                else
                                    field.type;
                                const parsed = std.fmt.parseInt(IntType, args[i + 1], 10) catch {
                                    std.debug.print("Error: Invalid integer value '{s}' for {s}\n", .{ args[i + 1], arg });
                                    return error.InvalidArgument;
                                };
                                @field(result, field.name) = parsed;
                                i += 1;
                            } else {
                                @compileError("Unsupported field type for CLI parsing: " ++ field.name);
                            }
                        }
                    }
                    if (!matched) {
                        std.debug.print("Error: Unknown argument '{s}'\n", .{arg});
                        return error.InvalidArgument;
                    }
                } else {
                    // Positional arguments?
                    // Not supported in this simplified version yet
                    std.debug.print("Error: Unexpected positional argument '{s}'\n", .{arg});
                    return error.InvalidArgument;
                }
            }
            return result;
        },
        else => @compileError("Root type must be a Union (subcommands) or Struct (flags)"),
    }
}

pub fn printHelp(comptime T: type, active_command: ?[]const u8) !void {
    _ = active_command;
    switch (@typeInfo(T)) {
        .@"union" => |u_info| {
            const desc = if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), "description")) T.meta.description else "Pantavisor Mocker CLI";
            std.debug.print("{s}\n\nUsage: <command> [options]\n\nCommands:\n", .{desc});

            inline for (u_info.fields) |field| {
                const cmd_desc = if (@hasDecl(field.type, "meta") and @hasField(@TypeOf(field.type.meta), "description"))
                    field.type.meta.description
                else
                    "";
                std.debug.print("  {s:<20} {s}\n", .{ field.name, cmd_desc });
            }
        },
        .@"struct" => |s_info| {
            const desc = if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), "description")) T.meta.description else "Command";
            std.debug.print("{s}\n\nOptions:\n", .{desc});

            inline for (s_info.fields) |field| {
                const meta = if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta.args), field.name))
                    @field(T.meta.args, field.name)
                else
                    struct {}{};

                const short_char: ?u8 = if (@hasField(@TypeOf(meta), "short")) meta.short else null;
                const help_text = if (@hasField(@TypeOf(meta), "help")) meta.help else "";

                if (short_char) |c| {
                    std.debug.print("  -{c}, --{s:<14} {s}\n", .{ c, field.name, help_text });
                } else {
                    std.debug.print("      --{s:<14} {s}\n", .{ field.name, help_text });
                }
            }
        },
        else => {},
    }
    std.debug.print("\n", .{});
}

test "framework struct parsing" {
    std.debug.print("RUNNING FRAMEWORK TESTS\n", .{});
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
    const res1 = try parse(std.testing.allocator, TestStruct, args1);
    try std.testing.expect(res1.foo);
    try std.testing.expectEqualStrings("baz", res1.bar);

    const args2 = &[_][]const u8{"-f"};
    const res2 = try parse(std.testing.allocator, TestStruct, args2);
    try std.testing.expect(res2.foo);
    try std.testing.expectEqualStrings("default", res2.bar);
}

test "framework union parsing" {
    const Sub = struct {
        val: []const u8 = "",
    };
    const TestUnion = union(enum) {
        sub: Sub,
    };

    const args = &[_][]const u8{ "sub", "--val", "hello" };
    const res = try parse(std.testing.allocator, TestUnion, args);
    try std.testing.expect(res == .sub);
    try std.testing.expectEqualStrings("hello", res.sub.val);
}

test "framework error handling" {
    const TestStruct = struct {
        val: []const u8 = "",
    };

    const args_missing = &[_][]const u8{"--val"};
    try std.testing.expectError(error.MissingArgument, parse(std.testing.allocator, TestStruct, args_missing));

    const args_invalid = &[_][]const u8{"--unknown"};
    try std.testing.expectError(error.InvalidArgument, parse(std.testing.allocator, TestStruct, args_invalid));
}

test "framework execute" {
    // This test is hard to write without context passing support in `execute`.
    // I'll skip adding a complex test for `execute` in framework for now,
    // relying on the fact that `parse` works and `runCommand` just calls the method.
}
