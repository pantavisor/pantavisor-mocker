const std = @import("std");

pub const SubsystemId = enum {
    core,
    renderer,
    logger,
    background_job,
};

pub const MessageType = enum {
    // Control Messages (Core <-> Subsystem)
    subsystem_init,
    subsystem_start,
    subsystem_stop,
    subsystem_ready,

    // Application Messages
    log_message,
    render_log,
    render_update,
    render_invite,
    render_state_change,
    get_user_input,

    sync_started,
    sync_progress,
    sync_completed,
    sync_failed,
    invitation_required,
    update_required,

    user_response,

    // Response Messages
    response_ok,
    response_error,
    user_decision,
};

pub const Message = struct {
    from: SubsystemId,
    to: SubsystemId,
    type: MessageType,
    data: ?std.json.Value = null,

    pub fn serialize(self: Message, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(self, .{})});
    }

    pub fn deserialize(allocator: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(Message) {
        return try std.json.parseFromSlice(Message, allocator, json_text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

pub const LogData = struct {
    level: []const u8,
    subsystem: []const u8,
    message: []const u8,
    timestamp: i64,
};

pub const SyncProgressData = struct {
    percentage: u8,
    details: []const u8,
};

pub const UserDecisionData = struct {
    accepted: bool,
    details: ?[]const u8 = null,
};

pub const InvitationData = struct {
    id: []const u8,
    description: []const u8,
    from: []const u8,
    deployment: []const u8,
    release: []const u8,
    vendorRelease: ?[]const u8 = null,
    earliestUpdate: ?[]const u8 = null,
    latestUpdate: ?[]const u8 = null,
    mandatory: bool,
};
