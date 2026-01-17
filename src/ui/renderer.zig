const std = @import("std");
const messages = @import("../core/messages.zig");
const SubsystemId = messages.SubsystemId;
const Message = messages.Message;

pub const Renderer = struct {
    pub const VTable = struct {
        render_log: *const fn (ctx: *anyopaque, msg: messages.LogData) anyerror!void,
        render_update: *const fn (ctx: *anyopaque, data: std.json.Value) anyerror!void,
        render_invite: *const fn (ctx: *anyopaque, data: messages.InvitationData) anyerror!void,
        render_state_change: *const fn (ctx: *anyopaque, state: []const u8) anyerror!void,
        get_user_input: *const fn (ctx: *anyopaque, prompt: []const u8) anyerror![]u8,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn render_log(self: Renderer, msg: messages.LogData) !void {
        try self.vtable.render_log(self.ptr, msg);
    }

    pub fn render_update(self: Renderer, data: std.json.Value) !void {
        try self.vtable.render_update(self.ptr, data);
    }

    pub fn render_invite(self: Renderer, data: messages.InvitationData) !void {
        try self.vtable.render_invite(self.ptr, data);
    }

    pub fn render_state_change(self: Renderer, state: []const u8) !void {
        try self.vtable.render_state_change(self.ptr, state);
    }

    pub fn get_user_input(self: Renderer, prompt: []const u8) ![]u8 {
        return try self.vtable.get_user_input(self.ptr, prompt);
    }

    pub fn deinit(self: Renderer) void {
        self.vtable.deinit(self.ptr);
    }
};
