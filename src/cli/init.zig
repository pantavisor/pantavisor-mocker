const std = @import("std");
const constants = @import("../core/constants.zig");
const local_store = @import("../core/local_store.zig");
const ownership = @import("../core/ownership.zig");
const device_config = @import("device_config.zig");

pub const InitCmd = struct {
    token: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: ?[]const u8 = null,
    storage: []const u8 = constants.DEFAULT_STORAGE_PATH,
    config: ?[]const u8 = null,
    cert: ?[]const u8 = null,
    key: ?[]const u8 = null,

    pub const meta = .{
        .description = "Setup the \"mock device\" (initialize storage and register).",
        .args = .{
            .token = .{ .short = 't', .help = "Factory autotoken for registration." },
            .host = .{ .help = "Set Pantahub API host." },
            .port = .{ .help = "Set Pantahub API port." },
            .storage = .{ .short = 's', .help = "Path to the storage directory." },
            .config = .{ .short = 'c', .help = "Device config JSON (endpoint, token, device-meta, automation, intervals, ownership); flags override its values." },
            .cert = .{ .help = "TLS client certificate (PEM) for ownership validation; copied to <storage>/ownership/cert.pem. Requires --key." },
            .key = .{ .help = "TLS client private key (PEM) for ownership validation; copied to <storage>/ownership/key.pem. Requires --cert." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        const flags = ownership.Config{ .cert = self.cert, .key = self.key };
        const has_flag_pair = flags.validate("init") catch return error.InvalidArguments;

        if (self.config) |config_path| {
            try device_config.apply(allocator, self.storage, config_path, .{
                .token = self.token,
                .host = self.host,
                .port = self.port,
            });
            std.debug.print("Storage initialized at {s} from {s}\n", .{ self.storage, config_path });
        } else {
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

        // Flags win over the config file's "ownership" block (applied above).
        if (has_flag_pair) {
            try ownership.install(allocator, self.storage, self.cert.?, self.key.?);
            std.debug.print("TLS ownership cert/key installed at {s}/ownership/\n", .{self.storage});
        }
    }
};
