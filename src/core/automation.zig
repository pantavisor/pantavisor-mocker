const std = @import("std");
const invitation = @import("../flows/invitation.zig");
const client_mod = @import("../net/client.zig");
const tui = @import("../ui/tui.zig");

/// Weights for invitation response selection.
/// Values are relative weights, not percentages.
/// Example: {accept: 70, skip: 20, later: 10} = 70% accept, 20% skip, 10% later
pub const InvitationWeights = struct {
    accept: u32 = 100,
    skip: u32 = 0,
    later: u32 = 0,

    pub fn total(self: InvitationWeights) u32 {
        return self.accept + self.skip + self.later;
    }
};

/// Weights for update response selection.
/// Values are relative weights, not percentages.
pub const UpdateWeights = struct {
    done: u32 = 100,
    updated: u32 = 0,
    @"error": u32 = 0,
    wontgo: u32 = 0,

    pub fn total(self: UpdateWeights) u32 {
        return self.done + self.updated + self.@"error" + self.wontgo;
    }
};

/// Automation configuration loaded from mocker.json
pub const AutomationConfig = struct {
    allocator: std.mem.Allocator,
    enabled: bool = false,
    seed: ?u64 = null,
    invitation: InvitationWeights = .{},
    update: UpdateWeights = .{},

    // Runtime state - initialized lazily
    rng: std.Random.DefaultPrng,

    /// Initialize automation config with optional seed
    pub fn init(allocator: std.mem.Allocator, seed: ?u64) AutomationConfig {
        const actual_seed = seed orelse @as(u64, @bitCast(std.time.milliTimestamp()));
        return .{
            .allocator = allocator,
            .enabled = false,
            .seed = seed,
            .invitation = .{},
            .update = .{},
            .rng = std.Random.DefaultPrng.init(actual_seed),
        };
    }

    /// Parse automation config from mocker.json parsed value
    /// Returns null if automation block is not present
    pub fn parseFromJson(allocator: std.mem.Allocator, json_value: ?std.json.Value) ?AutomationConfig {
        const root = json_value orelse return null;
        if (root != .object) return null;

        const automation_obj = root.object.get("automation") orelse return null;
        if (automation_obj != .object) return null;

        var cfg = AutomationConfig.init(allocator, null);

        // Parse enabled flag
        if (automation_obj.object.get("enabled")) |enabled_val| {
            if (enabled_val == .bool) {
                cfg.enabled = enabled_val.bool;
            }
        }

        // Parse seed
        if (automation_obj.object.get("seed")) |seed_val| {
            if (seed_val == .integer) {
                cfg.seed = @intCast(seed_val.integer);
                cfg.rng = std.Random.DefaultPrng.init(cfg.seed.?);
            }
        }

        // Parse invitation weights
        if (automation_obj.object.get("invitation")) |inv_obj| {
            if (inv_obj == .object) {
                if (inv_obj.object.get("accept")) |v| {
                    if (v == .integer and v.integer >= 0) cfg.invitation.accept = @intCast(v.integer);
                }
                if (inv_obj.object.get("skip")) |v| {
                    if (v == .integer and v.integer >= 0) cfg.invitation.skip = @intCast(v.integer);
                }
                if (inv_obj.object.get("later")) |v| {
                    if (v == .integer and v.integer >= 0) cfg.invitation.later = @intCast(v.integer);
                }
            }
        }

        // Parse update weights
        if (automation_obj.object.get("update")) |upd_obj| {
            if (upd_obj == .object) {
                if (upd_obj.object.get("done")) |v| {
                    if (v == .integer and v.integer >= 0) cfg.update.done = @intCast(v.integer);
                }
                if (upd_obj.object.get("updated")) |v| {
                    if (v == .integer and v.integer >= 0) cfg.update.updated = @intCast(v.integer);
                }
                if (upd_obj.object.get("error")) |v| {
                    if (v == .integer and v.integer >= 0) cfg.update.@"error" = @intCast(v.integer);
                }
                if (upd_obj.object.get("wontgo")) |v| {
                    if (v == .integer and v.integer >= 0) cfg.update.wontgo = @intCast(v.integer);
                }
            }
        }

        // Validate: at least one weight must be non-zero for each category
        if (cfg.invitation.total() == 0) {
            cfg.invitation = .{}; // Reset to defaults
        }
        if (cfg.update.total() == 0) {
            cfg.update = .{}; // Reset to defaults
        }

        return cfg;
    }

    /// Select an invitation response based on configured weights
    pub fn selectInvitationResponse(self: *AutomationConfig) invitation.Decision {
        const total = self.invitation.total();
        if (total == 0) return .accept; // Fallback

        const rand_val = self.rng.random().intRangeAtMost(u32, 1, total);

        if (rand_val <= self.invitation.accept) {
            return .accept;
        } else if (rand_val <= self.invitation.accept + self.invitation.skip) {
            return .skip;
        } else {
            return .later;
        }
    }

    /// Select an update response based on configured weights
    pub fn selectUpdateResponse(self: *AutomationConfig) client_mod.UpdateStatus {
        const total = self.update.total();
        if (total == 0) return .DONE; // Fallback

        const rand_val = self.rng.random().intRangeAtMost(u32, 1, total);

        if (rand_val <= self.update.done) {
            return .DONE;
        } else if (rand_val <= self.update.done + self.update.updated) {
            return .UPDATED;
        } else if (rand_val <= self.update.done + self.update.updated + self.update.@"error") {
            return .ERROR;
        } else {
            return .WONTGO;
        }
    }

    /// Convert invitation decision to TUI response type
    pub fn decisionToTuiResponse(decision: invitation.Decision) tui.InvitationResponse {
        return switch (decision) {
            .accept => .accept,
            .skip => .skip,
            .later => .later,
        };
    }

    /// Convert update status to TUI response type
    pub fn statusToTuiResponse(status: client_mod.UpdateStatus) tui.UpdateResponse {
        return switch (status) {
            .DONE => .done,
            .UPDATED => .updated,
            .ERROR => .error_status,
            .WONTGO => .wontgo,
            else => .done, // Fallback for non-terminal statuses
        };
    }

    /// Get a string representation of invitation weights for logging
    pub fn invitationWeightsString(self: *const AutomationConfig, buf: []u8) []const u8 {
        const result = std.fmt.bufPrint(buf, "accept={}, skip={}, later={}", .{
            self.invitation.accept,
            self.invitation.skip,
            self.invitation.later,
        }) catch return "?";
        return result;
    }

    /// Get a string representation of update weights for logging
    pub fn updateWeightsString(self: *const AutomationConfig, buf: []u8) []const u8 {
        const result = std.fmt.bufPrint(buf, "done={}, updated={}, error={}, wontgo={}", .{
            self.update.done,
            self.update.updated,
            self.update.@"error",
            self.update.wontgo,
        }) catch return "?";
        return result;
    }
};

test "automation config parsing" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{
        \\  "automation": {
        \\    "enabled": true,
        \\    "seed": 12345,
        \\    "invitation": {
        \\      "accept": 70,
        \\      "skip": 20,
        \\      "later": 10
        \\    },
        \\    "update": {
        \\      "done": 60,
        \\      "updated": 25,
        \\      "error": 10,
        \\      "wontgo": 5
        \\    }
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const cfg = AutomationConfig.parseFromJson(allocator, parsed.value);
    try std.testing.expect(cfg != null);

    const c = cfg.?;
    try std.testing.expect(c.enabled == true);
    try std.testing.expect(c.seed.? == 12345);
    try std.testing.expect(c.invitation.accept == 70);
    try std.testing.expect(c.invitation.skip == 20);
    try std.testing.expect(c.invitation.later == 10);
    try std.testing.expect(c.update.done == 60);
    try std.testing.expect(c.update.updated == 25);
    try std.testing.expect(c.update.@"error" == 10);
    try std.testing.expect(c.update.wontgo == 5);
}

test "automation config defaults" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{
        \\  "automation": {
        \\    "enabled": true
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const cfg = AutomationConfig.parseFromJson(allocator, parsed.value);
    try std.testing.expect(cfg != null);

    const c = cfg.?;
    try std.testing.expect(c.enabled == true);
    try std.testing.expect(c.invitation.accept == 100);
    try std.testing.expect(c.invitation.skip == 0);
    try std.testing.expect(c.update.done == 100);
}

test "weighted selection distribution" {
    const allocator = std.testing.allocator;

    var cfg = AutomationConfig.init(allocator, 42); // Fixed seed for reproducibility
    cfg.invitation = .{ .accept = 50, .skip = 30, .later = 20 };

    var accept_count: u32 = 0;
    var skip_count: u32 = 0;
    var later_count: u32 = 0;

    const iterations: u32 = 1000;
    for (0..iterations) |_| {
        switch (cfg.selectInvitationResponse()) {
            .accept => accept_count += 1,
            .skip => skip_count += 1,
            .later => later_count += 1,
        }
    }

    // With 1000 iterations and weights 50/30/20, we expect roughly:
    // accept: ~500, skip: ~300, later: ~200
    // Allow 15% tolerance
    try std.testing.expect(accept_count > 350 and accept_count < 650);
    try std.testing.expect(skip_count > 150 and skip_count < 450);
    try std.testing.expect(later_count > 50 and later_count < 350);
}
