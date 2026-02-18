const std = @import("std");
const local_store = @import("../core/local_store.zig");
const swarm_workspace = @import("swarm_workspace.zig");

pub const GenerateDevicesCmd = struct {
    count: u32 = 0,
    dir: []const u8 = "devices",
    workspace: []const u8 = ".",
    host: []const u8 = "api.pantahub.com",
    port: []const u8 = "443",

    pub const meta = .{
        .description = "Generate generic simulated devices.",
        .args = .{
            .count = .{ .short = 'n', .help = "Number of devices to generate." },
            .dir = .{ .short = 'd', .help = "Output directory." },
            .workspace = .{ .short = 'w', .help = "Workspace directory (contains config files)." },
            .host = .{ .help = "Pantahub API host." },
            .port = .{ .help = "Pantahub API port." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        if (self.count == 0) {
            std.debug.print("Error: --count is required and must be a positive integer.\n", .{});
            return error.MissingArgument;
        }

        var ws = try swarm_workspace.SwarmWorkspace.init(allocator, self.workspace);
        defer ws.deinit();

        std.debug.print("Generating {d} devices...\n", .{self.count});

        for (0..self.count) |i| {
            const device_id = swarm_workspace.generateHexId();
            std.debug.print("  Creating Device [{d}/{d}]: {s}\n", .{ i + 1, self.count, &device_id });

            // Build path: {dir}/{id}/mocker
            var path_buf: [4096]u8 = undefined;
            const storage_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/mocker", .{ self.dir, &device_id });

            // Use LocalStore to scaffold
            var store = try local_store.LocalStore.init(allocator, storage_path, ws.autojoin_token, false);
            defer store.deinit();

            // Set host/port
            try store.save_config_value("PH_CREDS_HOST", self.host);
            try store.save_config_value("PH_CREDS_PORT", self.port);
            try store.save_config_value("PH_FACTORY_AUTOTOK", ws.autojoin_token);

            // Build merged device-meta JSON
            const device_meta = try swarm_workspace.buildMergedDeviceMeta(
                allocator,
                ws.base_json,
                null,
                ws.random_keys.items,
                ws.group_key,
                &device_id,
                &.{},
            );
            defer allocator.free(device_meta);

            // Write mocker.json with device-meta
            var mocker_path_buf: [4096]u8 = undefined;
            const mocker_path = try std.fmt.bufPrint(&mocker_path_buf, "{s}/config/mocker.json", .{storage_path});
            try swarm_workspace.writeMockerJson(allocator, mocker_path, device_meta);
        }

        std.debug.print("Done generating devices.\n", .{});
    }
};

pub const GenerateAppliancesCmd = struct {
    count: u32 = 0,
    dir: []const u8 = "appliances",
    workspace: []const u8 = ".",
    host: []const u8 = "api.pantahub.com",
    port: []const u8 = "443",

    pub const meta = .{
        .description = "Generate appliances per channel with multiple models.",
        .args = .{
            .count = .{ .short = 'n', .help = "Number of appliances per channel." },
            .dir = .{ .short = 'd', .help = "Output directory." },
            .workspace = .{ .short = 'w', .help = "Workspace directory (contains config files)." },
            .host = .{ .help = "Pantahub API host." },
            .port = .{ .help = "Pantahub API port." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        if (self.count == 0) {
            std.debug.print("Error: --count is required and must be a positive integer.\n", .{});
            return error.MissingArgument;
        }

        var ws = try swarm_workspace.SwarmWorkspace.init(allocator, self.workspace);
        defer ws.deinit();

        // Read channels.json
        var channels_parsed = try ws.readChannelsJson();
        defer channels_parsed.deinit();

        if (channels_parsed.value != .object) {
            std.debug.print("Error: channels.json must be a JSON object.\n", .{});
            return error.InvalidArgument;
        }

        // Read models
        var models = try ws.readModels();
        defer {
            for (models.items) |m| allocator.free(m);
            models.deinit(allocator);
        }

        if (models.items.len == 0) {
            std.debug.print("Error: models.txt is empty.\n", .{});
            return error.InvalidArgument;
        }

        // Iterate channels
        var channel_it = channels_parsed.value.object.iterator();
        while (channel_it.next()) |channel_entry| {
            const channel_name = channel_entry.key_ptr.*;
            std.debug.print("Processing Channel: {s}\n", .{channel_name});

            // Sanitize channel name (replace spaces with underscores)
            var sanitized_channel_buf: [256]u8 = undefined;
            const sanitized_channel = sanitizeName(&sanitized_channel_buf, channel_name);

            const channel_overlay: ?std.json.Value = if (channel_entry.value_ptr.* == .object)
                channel_entry.value_ptr.*
            else
                null;

            for (0..self.count) |i| {
                const appliance_id = swarm_workspace.generateHexId();
                std.debug.print("  Creating Appliance [{d}/{d}]: {s}\n", .{ i + 1, self.count, &appliance_id });

                for (models.items) |model| {
                    // Sanitize model name
                    var sanitized_model_buf: [256]u8 = undefined;
                    const sanitized_model = sanitizeName(&sanitized_model_buf, model);

                    // Build path: {dir}/{channel}/{id}/{model}
                    var path_buf: [4096]u8 = undefined;
                    const storage_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}/{s}", .{
                        self.dir,
                        sanitized_channel,
                        &appliance_id,
                        sanitized_model,
                    });

                    // Use LocalStore to scaffold
                    var store = try local_store.LocalStore.init(allocator, storage_path, ws.autojoin_token, false);
                    defer store.deinit();

                    // Set host/port/token
                    try store.save_config_value("PH_CREDS_HOST", self.host);
                    try store.save_config_value("PH_CREDS_PORT", self.port);
                    try store.save_config_value("PH_FACTORY_AUTOTOK", ws.autojoin_token);

                    // Build merged device-meta JSON
                    const extra_pairs = [_][2][]const u8{
                        .{ "pantavisor.dtmodel", model },
                    };
                    const device_meta = try swarm_workspace.buildMergedDeviceMeta(
                        allocator,
                        ws.base_json,
                        channel_overlay,
                        ws.random_keys.items,
                        ws.group_key,
                        &appliance_id,
                        &extra_pairs,
                    );
                    defer allocator.free(device_meta);

                    // Write mocker.json with device-meta
                    var mocker_path_buf: [4096]u8 = undefined;
                    const mocker_path = try std.fmt.bufPrint(&mocker_path_buf, "{s}/config/mocker.json", .{storage_path});
                    try swarm_workspace.writeMockerJson(allocator, mocker_path, device_meta);
                }
            }
        }

        std.debug.print("Done generating appliances.\n", .{});
    }

    fn sanitizeName(buf: []u8, name: []const u8) []const u8 {
        const len = @min(name.len, buf.len);
        for (0..len) |j| {
            buf[j] = if (name[j] == ' ') '_' else name[j];
        }
        return buf[0..len];
    }
};
