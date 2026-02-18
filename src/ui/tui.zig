const std = @import("std");
const vaxis = @import("vaxis");

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    log_message: LogMessage,
    invitation: Invitation,
    progress: Progress,
    update_prompt: void, // Signal to show update prompt
    auto_accept_update: void, // Signal to show update prompt
    quit,

    pub fn deinit(self: Event, allocator: std.mem.Allocator) void {
        switch (self) {
            .log_message => |lm| if (lm.message.len > 0) allocator.free(lm.message),
            .invitation => |inv| {
                if (inv.id.len > 0) allocator.free(inv.id);
                if (inv.description.len > 0) allocator.free(inv.description);
                if (inv.from.len > 0) allocator.free(inv.from);
                if (inv.deployment.len > 0) allocator.free(inv.deployment);
                if (inv.release.len > 0) allocator.free(inv.release);
                if (inv.vendorRelease) |v| if (v.len > 0) allocator.free(v);
                if (inv.earliestUpdate) |v| if (v.len > 0) allocator.free(v);
                if (inv.latestUpdate) |v| if (v.len > 0) allocator.free(v);
            },
            .progress => |p| {
                if (p.status.len > 0) allocator.free(p.status);
                if (p.@"status-msg".len > 0) allocator.free(p.@"status-msg");
                if (p.revision.len > 0) allocator.free(p.revision);
            },
            else => {},
        }
    }
};

pub const LogMessage = struct {
    message: []const u8,
    timestamp: i64,
};

pub const Invitation = struct {
    id: []const u8,
    description: []const u8,
    from: []const u8,
    deployment: []const u8,
    release: []const u8,
    vendorRelease: ?[]const u8,
    earliestUpdate: ?[]const u8,
    latestUpdate: ?[]const u8,
    mandatory: ?bool,
};

pub const InvitationResponse = enum {
    accept,
    skip,
    later,
};

pub const UpdateResponse = enum {
    updated,
    done,
    error_status,
    wontgo,
};

pub const Progress = struct {
    status: []const u8,
    progress: u8,
    @"status-msg": []const u8,
    revision: []const u8,
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    logs: std.ArrayList(LogMessage),
    pending_invitation: ?Invitation = null,
    awaiting_invitation: bool = false,
    awaiting_update: bool = false,
    current_progress: ?Progress = null,
    use_tui: bool = true,
    should_quit: bool = false,

    pub fn init(allocator: std.mem.Allocator, use_tui: bool) AppState {
        return .{
            .allocator = allocator,
            .logs = .{},
            .use_tui = use_tui,
        };
    }

    pub fn deinit(self: *AppState) void {
        for (self.logs.items) |log| {
            self.allocator.free(log.message);
        }
        self.logs.deinit(self.allocator);
        if (self.pending_invitation) |inv| {
            self.free_invitation(inv);
        }
        if (self.current_progress) |p| {
            self.free_progress(p);
        }
    }

    pub fn update_progress(self: *AppState, p: Progress) !void {
        if (self.current_progress) |old| {
            self.free_progress(old);
        }
        self.current_progress = p;
    }

    fn free_progress(self: *AppState, p: Progress) void {
        self.allocator.free(p.status);
        self.allocator.free(p.@"status-msg");
        self.allocator.free(p.revision);
    }

    pub fn add_log(self: *AppState, message: []const u8) !void {
        // Support multi-line logs by splitting by newline
        var it = std.mem.splitScalar(u8, message, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const owned = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(owned);
            try self.logs.append(self.allocator, .{
                .message = owned,
                .timestamp = std.time.timestamp(),
            });

            if (self.logs.items.len > 500) {
                const removed = self.logs.orderedRemove(0);
                self.allocator.free(removed.message);
            }
        }
    }

    pub fn set_invitation(self: *AppState, inv: Invitation) !void {
        if (self.pending_invitation) |old| {
            self.free_invitation(old);
        }
        self.pending_invitation = inv;
        self.awaiting_invitation = true;
    }

    fn free_invitation(self: *AppState, inv: Invitation) void {
        self.allocator.free(inv.id);
        self.allocator.free(inv.description);
        self.allocator.free(inv.from);
        self.allocator.free(inv.deployment);
        self.allocator.free(inv.release);
        if (inv.vendorRelease) |v| self.allocator.free(v);
        if (inv.earliestUpdate) |v| self.allocator.free(v);
        if (inv.latestUpdate) |v| self.allocator.free(v);
    }
};

pub fn render(vx: *vaxis.Vaxis, state: *AppState, arena: std.mem.Allocator) !void {
    const win = vx.window();
    win.clear();

    const height = win.height;
    const width = win.width;

    // Split layout:
    // Bottom 10 rows total for Interaction + Progress
    // Interaction: 7 rows
    // Progress: 3 rows
    // Top: Logs (remaining)

    const bottom_section_height: u16 = 16;
    const progress_height: u16 = 3;
    const interaction_height: u16 = bottom_section_height - progress_height;

    const log_height = if (height > bottom_section_height) height - bottom_section_height else 1;

    // 1. Logs Pane
    const log_pane = win.child(.{
        .x_off = 0,
        .y_off = 0,
        .width = width,
        .height = log_height,
        .border = .{ .where = .all, .glyphs = .single_rounded },
    });

    _ = log_pane.printSegment(.{ .text = " Logs ", .style = .{ .bold = true } }, .{ .col_offset = 2 });

    const log_content = log_pane.child(.{
        .x_off = 1,
        .y_off = 1,
        .width = width -| 2,
        .height = log_height -| 2,
    });

    const start_idx = if (state.logs.items.len > log_content.height)
        state.logs.items.len - log_content.height
    else
        0;

    for (state.logs.items[start_idx..], 0..) |log, idx| {
        _ = log_content.printSegment(.{ .text = log.message }, .{
            .row_offset = @intCast(idx),
        });
    }

    // 2. Interaction Pane
    const interact_pane = win.child(.{
        .x_off = 0,
        .y_off = @intCast(log_height),
        .width = width,
        .height = interaction_height,
        .border = .{ .where = .all, .glyphs = .single_rounded },
    });

    _ = interact_pane.printSegment(.{ .text = " Interaction ", .style = .{ .bold = true } }, .{ .col_offset = 2 });

    const content_pane = interact_pane.child(.{
        .x_off = 1,
        .y_off = 1,
        .width = width -| 2,
        .height = interaction_height -| 2,
    });

    if (state.awaiting_invitation) {
        if (state.pending_invitation) |inv| {
            _ = content_pane.printSegment(.{
                .text = "INVITATION RECEIVED",
                .style = .{ .bold = true, .fg = .{ .index = 3 } },
            }, .{ .row_offset = 0 });

            const from_text = try std.fmt.allocPrint(arena, "From: {s} | Release: {s}", .{ inv.from, inv.release });
            _ = content_pane.printSegment(.{ .text = from_text }, .{ .row_offset = 1 });

            var details_line = std.ArrayList(u8){};
            try details_line.appendSlice(arena, "Vendor Rev: ");
            try details_line.appendSlice(arena, inv.vendorRelease orelse "N/A");
            try details_line.appendSlice(arena, " | Mandatory: ");
            if (inv.mandatory) |m| {
                if (m) try details_line.appendSlice(arena, "YES") else try details_line.appendSlice(arena, "NO");
            } else {
                try details_line.appendSlice(arena, "NO");
            }

            _ = content_pane.printSegment(.{ .text = details_line.items }, .{ .row_offset = 2 });

            var time_line = std.ArrayList(u8){};
            try time_line.appendSlice(arena, "Earliest: ");
            try time_line.appendSlice(arena, inv.earliestUpdate orelse "NOW");
            try time_line.appendSlice(arena, " | Latest: ");
            try time_line.appendSlice(arena, inv.latestUpdate orelse "NEVER");

            _ = content_pane.printSegment(.{ .text = time_line.items }, .{ .row_offset = 3 });
            _ = content_pane.printSegment(.{ .text = "Actions: [A]ccept  [S]kip  [L]ater", .style = .{ .bold = true } }, .{ .row_offset = 5 });
        }
    } else if (state.awaiting_update) {
        _ = content_pane.printSegment(.{
            .text = "UPDATE DECISION REQUIRED",
            .style = .{ .bold = true, .fg = .{ .index = 6 } }, // Cyan
        }, .{ .row_offset = 0 });

        _ = content_pane.printSegment(.{ .text = "An update cycle is in TESTING phase." }, .{ .row_offset = 1 });
        _ = content_pane.printSegment(.{ .text = "Select Outcome:", .style = .{ .ul_style = .single } }, .{ .row_offset = 2 });
        _ = content_pane.printSegment(
            .{ .text = "[U]PDATED  - Success (Immediate)" },
            .{ .row_offset = 3 },
        );
        _ = content_pane.printSegment(
            .{ .text = "[D]ONE     - Success (Reboot)" },
            .{ .row_offset = 4 },
        );
        _ = content_pane.printSegment(
            .{ .text = "[E]RROR    - Simulate Failure" },
            .{ .row_offset = 5 },
        );
        _ = content_pane.printSegment(
            .{ .text = "[W]ONTGO   - Reject Update" },
            .{ .row_offset = 6 },
        );
        _ = content_pane.printSegment(
            .{ .text = "(10s timeout defaults to DONE)", .style = .{ .dim = true } },
            .{ .row_offset = 8 },
        );
    } else {
        _ = content_pane.printSegment(.{
            .text = "Status: Idle / Running...",
            .style = .{ .dim = true },
        }, .{ .row_offset = 0 });

        _ = content_pane.printSegment(.{
            .text = "(Press Ctrl+C to quit)",
            .style = .{ .dim = true },
        }, .{ .row_offset = 2 });
    }

    // 3. Progress Pane
    const progress_pane = win.child(.{
        .x_off = 0,
        .y_off = @intCast(log_height + interaction_height),
        .width = width,
        .height = progress_height,
        .border = .{ .where = .all, .glyphs = .single_rounded },
    });

    _ = progress_pane.printSegment(.{ .text = " Progress ", .style = .{ .bold = true } }, .{ .col_offset = 2 });

    const progress_content = progress_pane.child(.{
        .x_off = 1,
        .y_off = 1,
        .width = width -| 2,
        .height = progress_height -| 2,
    });

    if (state.current_progress) |p| {
        // Status line
        const status_text = try std.fmt.allocPrint(arena, "Rev: {s} | Status: {s} | {s}", .{ p.revision, p.status, p.@"status-msg" });
        _ = progress_content.printSegment(.{ .text = status_text }, .{ .row_offset = 0 });

        // Progress bar
        const bar_width = width -| 4;
        const filled_width = @as(u16, @intCast((@as(u32, p.progress) * bar_width) / 100));
        var bar_buf = std.ArrayList(u8){};
        try bar_buf.append(arena, '[');
        var i: u16 = 0;
        while (i < bar_width) : (i += 1) {
            if (i < filled_width) {
                try bar_buf.append(arena, '=');
            } else if (i == filled_width) {
                try bar_buf.append(arena, '>');
            } else {
                try bar_buf.append(arena, ' ');
            }
        }

        try bar_buf.append(arena, ']');
        const pct_text = try std.fmt.allocPrint(arena, " {d}%", .{p.progress});
        try bar_buf.appendSlice(arena, pct_text);
        _ = progress_content.printSegment(
            .{
                .text = bar_buf.items,
                .style = .{ .fg = .{ .index = 2 } }, // Green
            },
            .{
                .row_offset = 1,
            },
        );
    } else {
        _ = progress_content.printSegment(.{ .text = "No active revision", .style = .{ .dim = true } }, .{ .row_offset = 0 });
    }
}
