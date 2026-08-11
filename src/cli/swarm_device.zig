const std = @import("std");
const constants = @import("../core/constants.zig");
const local_store = @import("../core/local_store.zig");
const swarm_workspace = @import("swarm_workspace.zig");
const start_mod = @import("start.zig");

/// Run a single swarm member as its own process: provision one device from
/// swarm.json (first run only) into a private storage directory, then start
/// the mocker in the foreground with logs on stdout.
///
/// This is the one-device-per-container entrypoint: scale the fleet with
/// container replicas (Docker Compose `replicas`, Kubernetes StatefulSet)
/// instead of tmux sessions, and get per-device logs from the runtime
/// (`docker logs` / `kubectl logs`). The device identity lives in the storage
/// directory, so restarts keep the same registered device as long as the
/// storage persists.
pub const SwarmDeviceCmd = struct {
    config: []const u8 = swarm_workspace.SWARM_JSON_NAME,
    storage: []const u8 = constants.DEFAULT_STORAGE_PATH,
    channel: ?[]const u8 = null,
    model: ?[]const u8 = null,
    auto: bool = false,
    debug: bool = false,
    @"one-shot": bool = false,

    pub const meta = .{
        .description = "Provision (first run) and run one device from swarm.json - one device per container/pod.",
        .args = .{
            .config = .{ .short = 'c', .help = "Path to the swarm config JSON (relative or absolute)." },
            .storage = .{ .short = 's', .help = "Storage directory holding this device's identity and state." },
            .channel = .{ .help = "Channel overlay: a channel name from the config, or 'random'. Omit for a generic device." },
            .model = .{ .help = "Model name (default: picked at random from the config models)." },
            .auto = .{ .short = 'a', .help = "Force automation mode (automation from swarm.json applies anyway)." },
            .debug = .{ .help = "Enable debug logging." },
            .@"one-shot" = .{ .help = "Run a single cycle of the main loop and exit." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        std.debug.assert(self.storage.len > 0);

        var ws = try swarm_workspace.SwarmWorkspace.initWithConfig(allocator, ".", self.config);
        defer ws.deinit();

        if (try isProvisioned(allocator, self.storage)) {
            std.debug.print("Storage {s} already provisioned, keeping device identity.\n", .{self.storage});
        } else {
            try provision(allocator, &ws, self.storage, self.channel, self.model);
        }

        const start_cmd = start_mod.StartCmd{
            .storage = self.storage,
            .@"no-tui" = true,
            .auto = self.auto,
            .debug = self.debug,
            .@"one-shot" = self.@"one-shot",
        };
        try start_cmd.run(allocator);
    }

    /// A storage is provisioned once its mocker.json carries device-meta.
    fn isProvisioned(allocator: std.mem.Allocator, storage_path: []const u8) !bool {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ storage_path, "config", "mocker.json" });
        defer allocator.free(path);
        const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 50) catch return false;
        defer allocator.free(content);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const dm = parsed.value.object.get("device-meta") orelse return false;
        return dm == .object and dm.object.count() > 0;
    }

    fn provision(
        allocator: std.mem.Allocator,
        ws: *const swarm_workspace.SwarmWorkspace,
        storage_path: []const u8,
        channel_arg: ?[]const u8,
        model_arg: ?[]const u8,
    ) !void {
        const model = model_arg orelse blk: {
            if (ws.models.items.len == 0) {
                std.debug.print("Error: no models configured (add 'models' to the config or pass --model).\n", .{});
                return error.InvalidArgument;
            }
            const idx = std.crypto.random.intRangeLessThan(usize, 0, ws.models.items.len);
            break :blk ws.models.items[idx];
        };

        // Resolve the channel overlay (if requested)
        var channels_parsed: ?std.json.Parsed(std.json.Value) = null;
        defer if (channels_parsed) |*p| p.deinit();
        var overlay: ?std.json.Value = null;
        var channel_name: []const u8 = "none";
        if (channel_arg) |requested| {
            channels_parsed = try ws.readChannelsJson();
            const channels = channels_parsed.?.value;
            if (channels != .object or channels.object.count() == 0) {
                std.debug.print("Error: config has no channels to pick from.\n", .{});
                return error.InvalidArgument;
            }
            if (std.mem.eql(u8, requested, "random")) {
                const idx = std.crypto.random.intRangeLessThan(usize, 0, channels.object.count());
                channel_name = channels.object.keys()[idx];
            } else {
                if (channels.object.get(requested) == null) {
                    std.debug.print("Error: channel '{s}' not found in config.\n", .{requested});
                    return error.InvalidArgument;
                }
                channel_name = requested;
            }
            const value = channels.object.get(channel_name).?;
            overlay = if (value == .object) value else null;
        }

        const device_id = swarm_workspace.generateHexId();
        std.debug.print("Provisioning swarm device {s} (model: {s}, channel: {s}) in {s}\n", .{
            &device_id, model, channel_name, storage_path,
        });

        var store = try local_store.LocalStore.init(allocator, storage_path, ws.autojoin_token, true);
        defer store.deinit();
        try store.save_config_value("PH_CREDS_HOST", ws.host orelse "api.pantahub.com");
        try store.save_config_value("PH_CREDS_PORT", ws.port orelse "443");
        try store.save_config_value("PH_FACTORY_AUTOTOK", ws.autojoin_token);

        const extra_pairs = [_][2][]const u8{
            .{ "pantavisor.dtmodel", model },
        };
        const device_meta = try swarm_workspace.buildMergedDeviceMeta(
            allocator,
            ws.base_json,
            overlay,
            ws.random_keys.items,
            ws.group_key,
            &device_id,
            &extra_pairs,
        );
        defer allocator.free(device_meta);

        const mocker_path = try std.fs.path.join(allocator, &[_][]const u8{ storage_path, "config", "mocker.json" });
        defer allocator.free(mocker_path);
        try swarm_workspace.writeMockerJson(allocator, mocker_path, device_meta, ws.automation_json);
    }
};

test "swarm device provisioning" {
    const allocator = std.testing.allocator;
    const test_dir = "swarm_device_test";
    std.fs.cwd().makePath(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const swarm_json =
        \\{
        \\  "pantahub": { "host": "api.example.com", "port": "443", "autojoin_token": "TOK" },
        \\  "group_key": "grp.key",
        \\  "base": { "pantavisor.arch": "aarch64/64/EL" },
        \\  "channels": { "CH1": { "policy": "green" } },
        \\  "models": ["Model A"],
        \\  "automation": { "enabled": true }
        \\}
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/swarm.json", .data = swarm_json });

    var ws = try swarm_workspace.SwarmWorkspace.initWithConfig(allocator, test_dir, "swarm.json");
    defer ws.deinit();

    const storage = test_dir ++ "/storage";
    try std.testing.expect(!try SwarmDeviceCmd.isProvisioned(allocator, storage));
    try SwarmDeviceCmd.provision(allocator, &ws, storage, "CH1", null);
    try std.testing.expect(try SwarmDeviceCmd.isProvisioned(allocator, storage));

    const config = try std.fs.cwd().readFileAlloc(allocator, storage ++ "/config/pantahub.config", 1024 * 10);
    defer allocator.free(config);
    try std.testing.expect(std.mem.indexOf(u8, config, "PH_CREDS_HOST=api.example.com\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "PH_FACTORY_AUTOTOK=TOK\n") != null);

    const mocker = try std.fs.cwd().readFileAlloc(allocator, storage ++ "/config/mocker.json", 1024 * 50);
    defer allocator.free(mocker);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, mocker, .{});
    defer parsed.deinit();
    const dm = parsed.value.object.get("device-meta").?.object;
    try std.testing.expectEqualStrings("green", dm.get("policy").?.string);
    try std.testing.expectEqualStrings("Model A", dm.get("pantavisor.dtmodel").?.string);
    try std.testing.expect(dm.get("grp.key") != null);
    try std.testing.expect(parsed.value.object.get("automation").?.object.get("enabled").?.bool);
}
