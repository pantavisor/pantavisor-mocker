const std = @import("std");
const messages = @import("messages.zig");
const ipc = @import("ipc.zig");
const mocker_mod = @import("mocker.zig");

pub const BackgroundJobSubsystem = struct {
    allocator: std.mem.Allocator,
    mocker: *mocker_mod.Mocker,
    ipc_client: ipc.IpcClient,
    quit_flag: *std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8, mocker: *mocker_mod.Mocker) !BackgroundJobSubsystem {
        const ipc_client = try ipc.IpcClient.init(allocator, socket_path, .background_job);
        return BackgroundJobSubsystem{
            .allocator = allocator,
            .mocker = mocker,
            .ipc_client = ipc_client,
            .quit_flag = &mocker.quit_flag,
        };
    }

    pub fn deinit(self: *BackgroundJobSubsystem) void {
        self.ipc_client.deinit();
    }

    pub fn run(self: *BackgroundJobSubsystem) !void {
        // This will run the existing mocker background task
        // but it will now have access to ipc_client via mocker.ipc_client
        self.mocker.ipc_client = self.ipc_client;
        try self.mocker.runBackground(null);
    }
};
