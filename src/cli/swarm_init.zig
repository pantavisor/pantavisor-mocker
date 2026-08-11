const std = @import("std");
const swarm_workspace = @import("swarm_workspace.zig");

pub const SwarmInitCmd = struct {
    dir: []const u8 = ".",
    config: ?[]const u8 = null,

    pub const meta = .{
        .description = "Create a swarm workspace with a swarm.json config template.",
        .args = .{
            .dir = .{ .short = 'd', .help = "Target directory for the workspace." },
            .config = .{ .short = 'c', .help = "Name for the config template (default: swarm.json)." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        _ = allocator;
        const target_dir = self.dir;

        // Create target directory if not "."
        if (!std.mem.eql(u8, target_dir, ".")) {
            std.fs.cwd().makePath(target_dir) catch |err| {
                std.debug.print("Error: Could not create directory '{s}': {}\n", .{ target_dir, err });
                return err;
            };
        }

        std.debug.print("Initializing swarm workspace in: {s}\n", .{target_dir});

        const config_name = self.config orelse swarm_workspace.SWARM_JSON_NAME;
        const created = writeTemplateFile(target_dir, config_name, SWARM_JSON);

        // Create subdirectories
        createSubDir(target_dir, "appliances");
        createSubDir(target_dir, "devices");

        if (created == 0) {
            std.debug.print("  {s} already exists. Nothing to create.\n", .{config_name});
        } else {
            std.debug.print("\nWorkspace ready.\n", .{});
            std.debug.print("Edit {s} (set pantahub.host and pantahub.autojoin_token), then run:\n", .{config_name});
            if (self.config != null) {
                std.debug.print("  pantavisor-mocker swarm run -d {s} -c {s}\n", .{ target_dir, config_name });
            } else {
                std.debug.print("  pantavisor-mocker swarm run -d {s}\n", .{target_dir});
            }
            std.debug.print("Or step by step:\n", .{});
            std.debug.print("  pantavisor-mocker swarm generate-appliances --count <N>\n", .{});
            std.debug.print("  pantavisor-mocker swarm generate-devices --count <N>\n", .{});
            std.debug.print("  pantavisor-mocker swarm simulate\n", .{});
        }
    }

    fn writeTemplateFile(dir: []const u8, name: []const u8, content: []const u8) u32 {
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return 0;

        // Check if file already exists
        if (std.fs.cwd().access(path, .{})) |_| {
            return 0;
        } else |_| {}

        const file = std.fs.cwd().createFile(path, .{}) catch |err| {
            std.debug.print("  Error creating {s}: {}\n", .{ name, err });
            return 0;
        };
        defer file.close();
        file.writeAll(content) catch |err| {
            std.debug.print("  Error writing {s}: {}\n", .{ name, err });
            return 0;
        };
        std.debug.print("  Created {s}\n", .{name});
        return 1;
    }

    fn createSubDir(dir: []const u8, name: []const u8) void {
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return;
        std.fs.cwd().makePath(path) catch {};
    }

    const SWARM_JSON =
        \\{
        \\  "pantahub": {
        \\    "host": "api.pantahub.com",
        \\    "port": "443",
        \\    "autojoin_token": "YOUR_AUTOJOIN_TOKEN_HERE"
        \\  },
        \\  "group_key": "pantavisor.appliance.serialnumber",
        \\  "random_keys": [
        \\    "pantavisor.device.serialnumber"
        \\  ],
        \\  "base": {
        \\    "pantavisor.arch": "aarch64/64/EL",
        \\    "pantavisor.uname.kernel.name": "Linux",
        \\    "pantavisor.uname.machine": "aarch64"
        \\  },
        \\  "channels": {
        \\    "FRIDGE0001": {
        \\      "pantavisor.appliance.serialnumber": "FRIDGE0001"
        \\    }
        \\  },
        \\  "models": [
        \\    "OrangePi 3 LTS",
        \\    "Raspberry Pi 3 Model B Plus Rev 1.4"
        \\  ],
        \\  "generate": {
        \\    "appliances": 1,
        \\    "devices": 0
        \\  },
        \\  "automation": {
        \\    "enabled": true,
        \\    "invitation": {
        \\      "accept": 100,
        \\      "skip": 0,
        \\      "later": 0
        \\    },
        \\    "update": {
        \\      "done": 100,
        \\      "updated": 0,
        \\      "error": 0,
        \\      "wontgo": 0
        \\    }
        \\  },
        \\  "simulate": {
        \\    "auto": true,
        \\    "headless": false
        \\  }
        \\}
        \\
    ;
};
