const std = @import("std");
const constants = @import("../core/constants.zig");
const local_store = @import("../core/local_store.zig");

pub const InitCmd = struct {
    token: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: ?[]const u8 = null,
    storage: []const u8 = constants.DEFAULT_STORAGE_PATH,

    pub const meta = .{
        .description = "Setup the \"mock device\" (initialize storage and register).",
        .args = .{
            .token = .{ .short = 't', .help = "Factory autotoken for registration." },
            .host = .{ .help = "Set Pantahub API host." },
            .port = .{ .help = "Set Pantahub API port." },
            .storage = .{ .short = 's', .help = "Path to the storage directory." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        var store = try local_store.LocalStore.init(allocator, self.storage, self.token, true);
        defer store.deinit();

        if (self.host) |host| {
            try store.save_config_value("PH_CREDS_HOST", host);
        }
        if (self.port) |port| {
            try store.save_config_value("PH_CREDS_PORT", port);
        }

        std.debug.print("Storage initialized at {s}\n", .{self.storage});
    }
};
