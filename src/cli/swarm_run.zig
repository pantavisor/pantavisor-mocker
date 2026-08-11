const std = @import("std");
const swarm_workspace = @import("swarm_workspace.zig");
const swarm_generate = @import("swarm_generate.zig");
const swarm_simulate = @import("swarm_simulate.zig");

/// One-shot orchestrator driven entirely by swarm.json: generates the fleet
/// (if not generated yet) and launches the simulation. Designed so a
/// Kubernetes pod (or a local shell) can go from a single config file to a
/// running swarm with one command:
///
///   pantavisor-mocker swarm run -d /workspace --headless
pub const SwarmRunCmd = struct {
    dir: []const u8 = ".",
    config: ?[]const u8 = null,
    auto: bool = false,
    headless: bool = false,

    pub const meta = .{
        .description = "Generate (if needed) and simulate a swarm from swarm.json.",
        .args = .{
            .dir = .{ .short = 'd', .help = "Workspace directory (contains swarm.json)." },
            .config = .{ .short = 'c', .help = "Config file to use instead of swarm.json (relative to workspace, or absolute)." },
            .auto = .{ .short = 'a', .help = "Force automation mode for all devices (overrides simulate.auto)." },
            .headless = .{ .help = "Run without the interactive menu (overrides simulate.headless)." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        std.debug.assert(self.dir.len > 0);

        // Load workspace config only to read counts and simulate options; the
        // generate commands re-load it themselves.
        const opts = blk: {
            var ws = try swarm_workspace.SwarmWorkspace.initWithConfig(allocator, self.dir, self.config);
            defer ws.deinit();
            break :blk RunOptions{
                .generate = ws.generate,
                .auto = self.auto or ws.simulate.auto,
                .headless = self.headless or ws.simulate.headless,
            };
        };

        const appliances_dir = try std.fs.path.join(allocator, &[_][]const u8{ self.dir, "appliances" });
        defer allocator.free(appliances_dir);
        const devices_dir = try std.fs.path.join(allocator, &[_][]const u8{ self.dir, "devices" });
        defer allocator.free(devices_dir);

        try generateIfNeeded(allocator, self.dir, self.config, appliances_dir, devices_dir, opts.generate);

        const sim = swarm_simulate.SwarmSimulateCmd{
            .dir = self.dir,
            .auto = opts.auto,
            .headless = opts.headless,
        };
        try sim.run(allocator);
    }

    fn generateIfNeeded(
        allocator: std.mem.Allocator,
        workspace_dir: []const u8,
        config: ?[]const u8,
        appliances_dir: []const u8,
        devices_dir: []const u8,
        generate: swarm_workspace.GenerateConfig,
    ) !void {
        if (generate.appliances > 0) {
            if (dirHasEntries(appliances_dir)) {
                std.debug.print("Appliances already generated in {s}, skipping generation.\n", .{appliances_dir});
            } else {
                const cmd = swarm_generate.GenerateAppliancesCmd{
                    .count = generate.appliances,
                    .dir = appliances_dir,
                    .workspace = workspace_dir,
                    .config = config,
                };
                try cmd.run(allocator);
            }
        }

        if (generate.devices > 0) {
            if (dirHasEntries(devices_dir)) {
                std.debug.print("Devices already generated in {s}, skipping generation.\n", .{devices_dir});
            } else {
                const cmd = swarm_generate.GenerateDevicesCmd{
                    .count = generate.devices,
                    .dir = devices_dir,
                    .workspace = workspace_dir,
                    .config = config,
                };
                try cmd.run(allocator);
            }
        }

        if (generate.appliances == 0 and generate.devices == 0) {
            std.debug.print("No generate counts configured in swarm.json; simulating existing mockers only.\n", .{});
        }
    }

    fn dirHasEntries(dir_path: []const u8) bool {
        std.debug.assert(dir_path.len > 0);
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return false;
        defer dir.close();
        var it = dir.iterate();
        const entry = it.next() catch return false;
        return entry != null;
    }

    const RunOptions = struct {
        generate: swarm_workspace.GenerateConfig,
        auto: bool,
        headless: bool,
    };
};
