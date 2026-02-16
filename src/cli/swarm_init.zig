const std = @import("std");

pub const SwarmInitCmd = struct {
    dir: []const u8 = ".",

    pub const meta = .{
        .description = "Create a swarm workspace with config file templates.",
        .args = .{
            .dir = .{ .short = 'd', .help = "Target directory for the workspace." },
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

        var created: u32 = 0;

        created += writeTemplateFile(target_dir, "autojointoken.txt", "YOUR_AUTOJOIN_TOKEN_HERE\n");
        created += writeTemplateFile(target_dir, "group_key.txt", "pantavisor.appliance.serialnumber\n");
        created += writeTemplateFile(target_dir, "base.json", BASE_JSON);
        created += writeTemplateFile(target_dir, "channels.json", CHANNELS_JSON);
        created += writeTemplateFile(target_dir, "models.txt", MODELS_TXT);
        created += writeTemplateFile(target_dir, "to_random_keys.txt", RANDOM_KEYS_TXT);

        // Create subdirectories
        createSubDir(target_dir, "appliances");
        createSubDir(target_dir, "devices");

        if (created == 0) {
            std.debug.print("  All config files already exist. Nothing to create.\n", .{});
        } else {
            std.debug.print("\nWorkspace ready ({d} files created).\n", .{created});
            std.debug.print("Edit the config files as needed, then run:\n", .{});
            std.debug.print("  pantavisor-mocker swarm generate-appliances --count <N>\n", .{});
            std.debug.print("  pantavisor-mocker swarm generate-devices --count <N>\n", .{});
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

    const BASE_JSON =
        "{\n" ++
        "\t\"pantavisor.arch\": \"aarch64/64/EL\",\n" ++
        "\t\"pantavisor.uname.kernel.name\": \"Linux\",\n" ++
        "\t\"pantavisor.uname.machine\": \"aarch64\"\n" ++
        "}\n";

    const CHANNELS_JSON =
        "{\n" ++
        "\t\"FRIDGE0001\": {\n" ++
        "\t\t\"pantavisor.appliance.serialnumber\": \"FRIDGE0001\"\n" ++
        "\t}" ++
        "}\n";

    const MODELS_TXT =
        "OrangePi 3 LTS\n" ++
        "Raspberry Pi 3 Model B Plus Rev 1.4\n";

    const RANDOM_KEYS_TXT = "pantavisor.device.serialnumber\n";
};
