const std = @import("std");

pub const DEVICE_JSON_NAME = "device.json";

/// Write a single-device config template (device.json) — the individual-device
/// counterpart of `swarm init`. The result is consumed by `init -c` / `start -c`.
pub const ConfigCmd = struct {
    output: []const u8 = DEVICE_JSON_NAME,
    token: ?[]const u8 = null,
    host: []const u8 = "api.pantahub.com",
    port: []const u8 = "443",
    force: bool = false,

    pub const meta = .{
        .description = "Create a device.json config template for one mock device (used by init -c / start -c).",
        .args = .{
            .output = .{ .short = 'o', .help = "Output file (default: device.json)." },
            .token = .{ .short = 't', .help = "Pantahub autojoin token to write into the config." },
            .host = .{ .help = "Pantahub API host (default: api.pantahub.com)." },
            .port = .{ .help = "Pantahub API port (default: 443)." },
            .force = .{ .short = 'f', .help = "Overwrite an existing output file." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        std.debug.assert(self.output.len > 0);

        if (!self.force) {
            if (std.fs.cwd().access(self.output, .{})) |_| {
                std.debug.print("Error: {s} already exists. Use --force to overwrite it.\n", .{self.output});
                return error.AlreadyExists;
            } else |_| {}
        }

        if (std.fs.path.dirname(self.output)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                std.debug.print("Error: could not create directory '{s}': {}\n", .{ dir, err });
                return err;
            };
        }

        const content = try render(allocator, self);
        defer allocator.free(content);

        std.fs.cwd().writeFile(.{ .sub_path = self.output, .data = content }) catch |err| {
            std.debug.print("Error: could not write {s}: {}\n", .{ self.output, err });
            return err;
        };

        std.debug.print("Created {s}\n", .{self.output});
        if (self.token == null) {
            std.debug.print("Edit {s} (set pantahub.autojoin_token; add device-meta as needed), then run:\n", .{self.output});
        } else {
            std.debug.print("Start the device with:\n", .{});
        }
        std.debug.print("  pantavisor-mocker start -s <storage-dir> -c {s}\n", .{self.output});
    }

    fn render(allocator: std.mem.Allocator, self: @This()) ![]u8 {
        const token = self.token orelse "YOUR_AUTOJOIN_TOKEN_HERE";
        return std.fmt.allocPrint(allocator,
            \\{{
            \\  "pantahub": {{
            \\    "host": {f},
            \\    "port": {f},
            \\    "autojoin_token": {f}
            \\  }},
            \\  "device-meta": {{}},
            \\  "automation": {{
            \\    "enabled": true,
            \\    "invitation": {{ "accept": 100, "skip": 0, "later": 0 }},
            \\    "update": {{ "done": 100, "updated": 0, "error": 0, "wontgo": 0 }}
            \\  }},
            \\  "intervals": {{ "devmeta": 10, "usrmeta": 10 }}
            \\}}
            \\
        , .{
            std.json.fmt(self.host, .{}),
            std.json.fmt(self.port, .{}),
            std.json.fmt(token, .{}),
        });
    }
};

test "config template is a valid device config" {
    const device_config = @import("device_config.zig");
    const allocator = std.testing.allocator;

    const content = try ConfigCmd.render(allocator, .{ .token = "TOK\"1", .host = "h.example.com", .port = "8443" });
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(device_config.DeviceJsonSchema, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("TOK\"1", parsed.value.pantahub.autojoin_token.?);
    try std.testing.expectEqualStrings("h.example.com", parsed.value.pantahub.host.?);
    try std.testing.expectEqualStrings("8443", parsed.value.pantahub.port.?.string);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.@"device-meta".?.object.count());
    try std.testing.expect(parsed.value.automation.?.object.get("enabled").?.bool);
    try std.testing.expectEqual(@as(?u32, 10), parsed.value.intervals.devmeta);
    try std.testing.expectEqual(@as(?u32, 10), parsed.value.intervals.usrmeta);
}
