const std = @import("std");

pub const SwarmCleanCmd = struct {
    target: []const u8 = "all",
    dir: []const u8 = ".",

    pub const meta = .{
        .description = "Remove generated appliances and/or devices.",
        .args = .{
            .target = .{ .short = 't', .help = "What to clean: appliances, devices, or all." },
            .dir = .{ .short = 'd', .help = "Workspace directory." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        _ = allocator;
        const clean_appliances = std.mem.eql(u8, self.target, "appliances") or std.mem.eql(u8, self.target, "all");
        const clean_devices = std.mem.eql(u8, self.target, "devices") or std.mem.eql(u8, self.target, "all");

        if (!clean_appliances and !clean_devices) {
            std.debug.print("Error: --target must be 'appliances', 'devices', or 'all'.\n", .{});
            return error.InvalidArgument;
        }

        if (clean_appliances) {
            std.debug.print("Removing all generated appliances...\n", .{});
            deleteSubdirs(self.dir, "appliances");
        }

        if (clean_devices) {
            std.debug.print("Removing all generated devices...\n", .{});
            deleteSubdirs(self.dir, "devices");
        }

        std.debug.print("Done.\n", .{});
    }

    fn deleteSubdirs(base_dir: []const u8, sub_name: []const u8) void {
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, sub_name }) catch return;

        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
        defer dir.close();

        // Collect entries first, then delete
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) {
                dir.deleteTree(entry.name) catch |err| {
                    std.debug.print("  Warning: Could not remove {s}/{s}: {}\n", .{ sub_name, entry.name, err });
                };
            }
        }
    }
};
