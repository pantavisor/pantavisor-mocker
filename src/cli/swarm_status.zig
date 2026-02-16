const std = @import("std");

pub const SwarmStatusCmd = struct {
    dir: []const u8 = ".",

    pub const meta = .{
        .description = "Show swarm workspace status.",
        .args = .{
            .dir = .{ .short = 'd', .help = "Workspace directory." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        const appliance_count = countMockerJsonFiles(allocator, self.dir, "appliances");
        const device_count = countMockerJsonFiles(allocator, self.dir, "devices");

        std.debug.print("swarm workspace status\n", .{});
        std.debug.print("========================\n", .{});
        std.debug.print("Appliance mockers: {d}\n", .{appliance_count});
        std.debug.print("Device mockers:    {d}\n", .{device_count});
        std.debug.print("\n", .{});

        std.debug.print("Config files:\n", .{});
        const config_files = [_][]const u8{
            "autojointoken.txt",
            "group_key.txt",
            "base.json",
            "channels.json",
            "models.txt",
            "to_random_keys.txt",
        };
        for (config_files) |name| {
            var path_buf: [4096]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.dir, name }) catch continue;
            if (std.fs.cwd().access(path, .{})) |_| {
                std.debug.print("  [OK] {s}\n", .{name});
            } else |_| {
                std.debug.print("  [--] {s} (missing)\n", .{name});
            }
        }
    }

    fn countMockerJsonFiles(allocator: std.mem.Allocator, base_dir: []const u8, sub_dir: []const u8) u32 {
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, sub_dir }) catch return 0;

        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return 0;
        defer dir.close();

        return countMockerJsonRecursive(allocator, dir);
    }

    fn countMockerJsonRecursive(allocator: std.mem.Allocator, dir: std.fs.Dir) u32 {
        _ = allocator;
        var count: u32 = 0;
        var walker = dir.walk(std.heap.page_allocator) catch return 0;
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, entry.basename, "mocker.json")) continue;
            // Skip storage subdirs
            const p = entry.path;
            if (std.mem.indexOf(u8, p, "storage/") != null) continue;
            count += 1;
        }
        return count;
    }
};
