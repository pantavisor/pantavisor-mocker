const std = @import("std");
const client_mod = @import("../net/client.zig");
const local_store = @import("../storage/local_store.zig");
const logger_mod = @import("../ui/logger.zig");
const config_mod = @import("../core/config.zig");
const meta_mod = @import("../core/meta.zig");

pub const InviteToken = struct {
    spec: []const u8,
    type: []const u8,
    deployment: []const u8,
    release: []const u8,
    vendorRelease: ?[]const u8 = null,
    earliestUpdate: ?[]const u8 = null,
    latestUpdate: ?[]const u8 = null,
    mandatory: ?bool = false,
    rev: ?i64 = null, // For CANCELED
};

pub const AnswerToken = struct {
    spec: []const u8 = "fleet-update-proto@v1",
    type: []const u8,
    deployment: []const u8,
    release: ?[]const u8 = null,
    vendorRelease: ?[]const u8 = null,
    preferredUpdate: ?[]const u8 = null, // For ACCEPT
    askAgainUpdate: ?[]const u8 = null, // For ASKAGAIN
};

pub fn detect_invitation(
    allocator: std.mem.Allocator,
    store: *local_store.LocalStore,
    log: *logger_mod.Logger,
    client: *client_mod.Client,
    cfg: *config_mod.Config,
) !?InviteToken {
    log.log_debug("Checking for invitations...", .{});
    if (cfg.creds_prn == null) return null;
    const user_meta_json = client.get_user_meta(cfg.creds_prn.?) catch |err| {
        log.log("Failed to fetch user-meta: {any}", .{err});
        return null;
    };
    defer allocator.free(user_meta_json);

    var um_parsed = std.json.parseFromSlice(std.json.Value, allocator, user_meta_json, .{ .duplicate_field_behavior = .use_last }) catch |err| {
        log.log("Failed to parse user-meta: {any}", .{err});
        return null;
    };
    defer um_parsed.deinit();

    var invite: ?InviteToken = null;
    if (um_parsed.value.object.get("fleet.update-proto.token")) |token_val| {
        if (token_val == .string) {
            var token_parsed = std.json.parseFromSlice(InviteToken, allocator, token_val.string, .{ .ignore_unknown_fields = true, .duplicate_field_behavior = .use_last }) catch |err| {
                log.log("Failed to parse invite token string: {any}", .{err});
                return null;
            };
            defer token_parsed.deinit();
            invite = try clone_invite(allocator, token_parsed.value);
        }
    } else {
        return null;
    }

    if (invite == null) return null;
    const inv = invite.?;

    if (!std.mem.eql(u8, inv.type, "INVITE")) {
        free_invite(allocator, inv);
        return null;
    }

    const dm_path = try std.fs.path.join(allocator, &[_][]const u8{ store.base_path, "device-meta", "meta.json" });
    defer allocator.free(dm_path);

    var answered = false;
    if (std.fs.cwd().openFile(dm_path, .{})) |file| {
        const content = try file.readToEndAlloc(allocator, 1024 * 100);
        defer allocator.free(content);
        file.close();

        if (std.json.parseFromSlice(std.json.Value, allocator, content, .{ .duplicate_field_behavior = .use_last })) |dm_parsed| {
            defer dm_parsed.deinit();
            if (dm_parsed.value.object.get("fleet.update-proto.token")) |ans_val| {
                if (ans_val == .object) {
                    if (ans_val.object.get("deployment")) |dep_val| {
                        if (dep_val == .string and std.mem.eql(u8, dep_val.string, inv.deployment)) {
                            answered = true;
                        }
                    }
                } else if (ans_val == .string) {
                    if (std.json.parseFromSlice(std.json.Value, allocator, ans_val.string, .{})) |ans_inner| {
                        defer ans_inner.deinit();
                        if (ans_inner.value.object.get("deployment")) |dep_val| {
                            if (dep_val == .string and std.mem.eql(u8, dep_val.string, inv.deployment)) {
                                answered = true;
                            }
                        }
                    } else |_| {}
                }
            }
        } else |_| {}
    } else |_| {}

    if (answered) {
        free_invite(allocator, inv);
        return null;
    }

    return inv;
}

pub const Decision = enum {
    accept,
    skip,
    later,
};

pub fn process_answer(
    allocator: std.mem.Allocator,
    store: *local_store.LocalStore,
    log: *logger_mod.Logger,
    meta: *meta_mod.Meta,
    cfg: *config_mod.Config,
    inv: InviteToken,
    decision: Decision,
) !void {
    var answer: AnswerToken = undefined;
    var ask_again_str: ?[]u8 = null;
    defer if (ask_again_str) |s| allocator.free(s);

    if (decision == .accept) {
        answer = AnswerToken{
            .type = "ACCEPT",
            .deployment = inv.deployment,
            .release = inv.release,
            .vendorRelease = inv.vendorRelease,
            .preferredUpdate = "NOW",
        };
        log.log("Accepting invitation...", .{});
    } else if (decision == .skip) {
        answer = AnswerToken{
            .type = "SKIP",
            .deployment = inv.deployment,
            .release = inv.release,
            .vendorRelease = inv.vendorRelease,
        };
        log.log("Skipping invitation...", .{});
    } else if (decision == .later) {
        const future_ts = std.time.timestamp() + 3600;
        ask_again_str = try get_iso_timestamp(allocator, future_ts);

        answer = AnswerToken{
            .type = "ASKAGAIN",
            .deployment = inv.deployment,
            .release = inv.release,
            .vendorRelease = inv.vendorRelease,
            .askAgainUpdate = ask_again_str,
        };
        log.log("Asking to remind later (at {s})...", .{if (ask_again_str) |s| s else "unknown"});
    }

    const answer_str = try std.json.Stringify.valueAlloc(allocator, answer, .{ .emit_null_optional_fields = false });
    defer allocator.free(answer_str);

    var ans_val_parsed = try std.json.parseFromSlice(std.json.Value, allocator, answer_str, .{});
    defer ans_val_parsed.deinit();

    var overrides = std.StringArrayHashMap(std.json.Value).init(allocator);
    defer overrides.deinit();

    try overrides.put("fleet.update-proto.token", ans_val_parsed.value);
    try meta.update_local(store, cfg, overrides);
}

pub fn free_invite(allocator: std.mem.Allocator, inv: InviteToken) void {
    allocator.free(inv.spec);
    allocator.free(inv.type);
    allocator.free(inv.deployment);
    allocator.free(inv.release);
    if (inv.vendorRelease) |v| allocator.free(v);
    if (inv.earliestUpdate) |v| allocator.free(v);
    if (inv.latestUpdate) |v| allocator.free(v);
}

fn clone_invite(allocator: std.mem.Allocator, src: InviteToken) !InviteToken {
    var new_inv = InviteToken{
        .spec = try allocator.dupe(u8, src.spec),
        .type = try allocator.dupe(u8, src.type),
        .deployment = try allocator.dupe(u8, src.deployment),
        .release = try allocator.dupe(u8, src.release),
        .vendorRelease = null,
        .earliestUpdate = null,
        .latestUpdate = null,
        .mandatory = src.mandatory,
        .rev = src.rev,
    };
    errdefer free_invite(allocator, new_inv);

    if (src.vendorRelease) |v| new_inv.vendorRelease = try allocator.dupe(u8, v);
    if (src.earliestUpdate) |v| new_inv.earliestUpdate = try allocator.dupe(u8, v);
    if (src.latestUpdate) |v| new_inv.latestUpdate = try allocator.dupe(u8, v);

    return new_inv;
}

// Duplicated from client.zig to avoid circular dependency or public exposure issues if not public
// Ideally this should be in a utility module.
fn clone_json_value(allocator: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    switch (v) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = std.json.Array.init(allocator);
            errdefer {
                for (new_arr.items) |item| free_json_value_standalone(allocator, item);
                new_arr.deinit();
            }
            try new_arr.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| {
                try new_arr.append(try clone_json_value(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = std.json.ObjectMap.init(allocator);
            errdefer {
                var it = new_obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    free_json_value_standalone(allocator, entry.value_ptr.*);
                }
                new_obj.deinit();
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_copy);
                const value_copy = try clone_json_value(allocator, entry.value_ptr.*);
                try new_obj.put(key_copy, value_copy);
            }
            return .{ .object = new_obj };
        },
        .number_string => |s| return .{ .number_string = try allocator.dupe(u8, s) },
    }
}

fn free_json_value_standalone(allocator: std.mem.Allocator, v: std.json.Value) void {
    switch (v) {
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| free_json_value_standalone(allocator, item);
            var mutable_arr = arr;
            mutable_arr.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                free_json_value_standalone(allocator, entry.value_ptr.*);
            }
            var mutable_obj = obj;
            mutable_obj.deinit();
        },
        .number_string => |s| allocator.free(s),
        else => {},
    }
}

fn get_iso_timestamp(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const day = es.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = es.getDaySeconds();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}
