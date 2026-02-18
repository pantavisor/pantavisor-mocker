const std = @import("std");
const config = @import("config.zig");
const local_store = @import("local_store.zig");
const logger = @import("logger.zig");
const update_flow = @import("../flows/update_flow.zig");
const client_mod = @import("../net/client.zig");
const meta_mod = @import("meta.zig");
const log_pusher = @import("../net/log_pusher.zig");
const invitation = @import("../flows/invitation.zig");
const vaxis = @import("vaxis");
const tui = @import("../ui/tui.zig");
const constants = @import("constants.zig");
const business_logic = @import("business_logic.zig");
const router_mod = @import("router.zig");
const ipc = @import("ipc.zig");
const messages = @import("messages.zig");
pub const pvcontrol_server = @import("pvcontrol_server.zig");

const boot_state = constants.BOOT_STATE_JSON;
const boot_progress = constants.BOOT_PROGRESS_JSON;

pub const TaskContext = struct {
    allocator: std.mem.Allocator,
    storage_path: []const u8,
    is_one_shot: bool,
    is_debug: bool,
    ipc_client: ?*ipc.IpcClient,
    quit_flag: *std.atomic.Value(bool),
    inv_response_mutex: *std.Thread.Mutex,
    inv_response: *?tui.InvitationResponse,
    update_response_mutex: *std.Thread.Mutex,
    update_response: *?tui.UpdateResponse,
    progress_mutex: *std.Thread.Mutex,
    try_rev_ptr: *?[]const u8,
};

pub const Mocker = struct {
    allocator: std.mem.Allocator,
    storage_path: []const u8,
    is_one_shot: bool,
    is_debug: bool,
    quit_flag: std.atomic.Value(bool),
    router: ?router_mod.Router = null,
    ipc_client: ?ipc.IpcClient = null,
    router_thread: ?std.Thread = null,
    ipc_thread: ?std.Thread = null,
    pvcontrol_server: ?pvcontrol_server.PvControlServer = null,

    // Start synchronization
    start_mutex: std.Thread.Mutex = .{},
    start_cond: std.Thread.Condition = .{},
    started: bool = false,

    // Coordination state

    inv_response_mutex: std.Thread.Mutex = .{}, // Use default value
    inv_response: ?tui.InvitationResponse = null,
    update_response_mutex: std.Thread.Mutex = .{}, // Use default value
    update_response: ?tui.UpdateResponse = null,
    progress_mutex: std.Thread.Mutex = .{}, // Use default value
    try_rev_ptr: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, storage_path: []const u8, is_one_shot: bool, is_debug: bool) Mocker {
        return .{ // Use default value
            .allocator = allocator,
            .storage_path = storage_path,
            .is_one_shot = is_one_shot,
            .is_debug = is_debug,
            .quit_flag = std.atomic.Value(bool).init(false),
            .ipc_client = null,
            .try_rev_ptr = null,
        };
    }

    pub fn deinit(self: *Mocker) void {
        self.quit_flag.store(true, .release);
        // Signal start condition to unblock if waiting
        {
            self.start_mutex.lock();
            defer self.start_mutex.unlock();
            self.start_cond.signal();
        }

        if (self.router) |*r| {
            r.requestShutdown();
        }
        if (self.router_thread) |t| {
            t.join();
            self.router_thread = null;
        }
        if (self.router) |*r| {
            r.deinit();
            self.router = null;
        }

        if (self.ipc_client) |*c| {
            std.posix.shutdown(c.stream.handle, .both) catch {};
        }
        if (self.ipc_thread) |t| {
            t.join();
            self.ipc_thread = null;
        }
        if (self.ipc_client) |*c| {
            c.deinit();
            self.ipc_client = null;
        }
        if (self.pvcontrol_server) |*s| {
            s.deinit();
            self.pvcontrol_server = null;
        }
        if (self.try_rev_ptr) |ptr| {
            self.allocator.free(ptr);
            self.try_rev_ptr = null;
        }
    }

    pub fn getContext(self: *Mocker) TaskContext {
        return .{ // Use default value
            .allocator = self.allocator,
            .storage_path = self.storage_path,
            .is_one_shot = self.is_one_shot,
            .is_debug = self.is_debug,
            .ipc_client = if (self.ipc_client) |*c| c else null,
            .quit_flag = &self.quit_flag,
            .inv_response_mutex = &self.inv_response_mutex,
            .inv_response = &self.inv_response,
            .update_response_mutex = &self.update_response_mutex,
            .update_response = &self.update_response,
            .progress_mutex = &self.progress_mutex,
            .try_rev_ptr = &self.try_rev_ptr,
        };
    }

    pub fn runBackground(self: *Mocker) !void {
        const socket_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.storage_path, "mocker.sock" });
        defer self.allocator.free(socket_path);

        // self.router = try router_mod.Router.init(self.allocator, socket_path, &self.quit_flag);
        // self.router_thread = try std.Thread.spawn(.{}, router_mod.Router.run, .{&self.router.?});

        // // Wait a bit for router to start
        // std.Thread.sleep(100 * std.time.ns_per_ms);

        self.ipc_client = try ipc.IpcClient.init(self.allocator, socket_path, .background_job);
        self.ipc_thread = try std.Thread.spawn(.{}, listenToIpc, .{self});

        // Wait for start signal from Core
        self.start_mutex.lock();
        while (!self.started and !self.quit_flag.load(.acquire)) {
            self.start_cond.wait(&self.start_mutex);
        }
        self.start_mutex.unlock();

        if (self.quit_flag.load(.acquire)) return;

        const ctx = self.getContext();
        try self.background_task_err(ctx);

        if (self.is_one_shot) {
            if (self.ipc_client) |*client| {
                client.sendMessage(.renderer, .subsystem_stop, null) catch {};
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
            self.quit_flag.store(true, .release);
        }
    }

    fn listenToIpc(self: *Mocker) void {
        while (!self.quit_flag.load(.acquire)) {
            var parsed = self.ipc_client.?.receiveMessage() catch |err| {
                if (err == error.ConnectionClosed) break;
                continue;
            };
            defer parsed.deinit();

            const msg = parsed.value;

            if (msg.type == .subsystem_start) {
                {
                    self.start_mutex.lock();
                    defer self.start_mutex.unlock();
                    self.started = true;
                    self.start_cond.signal();
                }
            } else if (msg.type == .user_response) {
                // Handle user response
                if (msg.data) |data| {
                    if (data == .string) {
                        const resp_text = data.string;

                        // Check if it's an invitation response
                        var inv_resp: ?tui.InvitationResponse = null;
                        if (std.mem.eql(u8, resp_text, "accept")) {
                            inv_resp = .accept;
                        } else if (std.mem.eql(u8, resp_text, "skip")) {
                            inv_resp = .skip;
                        } else if (std.mem.eql(u8, resp_text, "later")) {
                            inv_resp = .later;
                        }

                        if (inv_resp) |ir| {
                            self.inv_response_mutex.lock();
                            defer self.inv_response_mutex.unlock();
                            self.inv_response = ir;
                        }

                        // Check if it's an update response
                        var update_resp: ?tui.UpdateResponse = null;
                        if (std.mem.eql(u8, resp_text, "updated")) {
                            update_resp = .updated;
                        } else if (std.mem.eql(u8, resp_text, "done")) {
                            update_resp = .done;
                        } else if (std.mem.eql(u8, resp_text, "error_status")) {
                            update_resp = .error_status;
                        } else if (std.mem.eql(u8, resp_text, "wontgo")) {
                            update_resp = .wontgo;
                        }

                        if (update_resp) |ur| {
                            self.update_response_mutex.lock();
                            defer self.update_response_mutex.unlock();
                            self.update_response = ur;
                        }
                    }
                }
            }
        }
    }

    fn background_task_err(self: *Mocker, ctx: TaskContext) !void {
        var store = try local_store.LocalStore.init(ctx.allocator, ctx.storage_path, null, true);
        defer store.deinit();

        const revisions = try store.get_revisions();
        defer {
            ctx.allocator.free(revisions.rev);
            ctx.allocator.free(revisions.try_rev);
        }

        try store.update_current_symlinks(revisions.try_rev);
        try store.init_log_dir(revisions.try_rev);
        const log_path = try store.get_log_path(revisions.try_rev);
        defer ctx.allocator.free(log_path);

        var log = try logger.Logger.init(log_path, ctx.is_debug);
        defer log.deinit();
        log.ipc_client = ctx.ipc_client;
        log.allocator = ctx.allocator;

        self.pvcontrol_server = try pvcontrol_server.PvControlServer.init(ctx.allocator, ctx.storage_path, ctx.quit_flag, ctx.is_debug, &log);
        try self.pvcontrol_server.?.start();

        {
            ctx.progress_mutex.lock();
            defer ctx.progress_mutex.unlock();
            if (ctx.try_rev_ptr.*) |p| ctx.allocator.free(p);
            ctx.try_rev_ptr.* = try ctx.allocator.dupe(u8, revisions.try_rev);
        }

        log.log(
            "Pantavisor Mocker Starting... \nRevision: {s}\nTry Revision: {s}",
            .{ revisions.rev, revisions.try_rev },
        );

        var cfg = try config.load(ctx.allocator, store, &log);
        defer cfg.deinit();
        std.debug.assert(cfg.pantahub_host != null);

        var meta = meta_mod.Meta.init(ctx.allocator);
        defer meta.deinit();

        var ph_client_ptr = try ctx.allocator.create(client_mod.Client);
        ph_client_ptr.* = try client_mod.Client.init(
            ctx.allocator,
            cfg.pantahub_host.?,
            cfg.pantahub_port orelse "443",
            &log,
        );
        defer {
            ph_client_ptr.deinit();
            ctx.allocator.destroy(ph_client_ptr);
        }

        try ensure_registered_and_logged_in(ctx.allocator, &store, &log, ph_client_ptr, &cfg, &revisions);
        try check_tls_ownership(ctx.allocator, &store, &log, ph_client_ptr, &cfg, &meta);

        var pending_inv: ?invitation.InviteToken = null;
        defer if (pending_inv) |inv| invitation.free_invite(ctx.allocator, inv);

        try self.main_event_loop(ctx, &store, &log, ph_client_ptr, &cfg, &meta, &pending_inv);
    }

    fn main_event_loop(
        self: *Mocker,
        ctx: TaskContext,
        store: *local_store.LocalStore,
        log: *logger.Logger,
        ph_client: *client_mod.Client,
        cfg: *config.Config,
        meta: *meta_mod.Meta,
        pending_inv: *?invitation.InviteToken,
    ) !void {
        while (!ctx.quit_flag.load(.acquire)) {
            try check_and_process_claim(ctx.allocator, store, log, ph_client, cfg);

            if (cfg.is_claimed) {
                try self.process_invitation_cycle(ctx, store, log, ph_client, cfg, meta, pending_inv);
                try self.process_update_cycle(ctx, store, log, ph_client, cfg);
                try self.sync_and_push(ctx, store, log, ph_client, cfg, meta);
            }

            if (ctx.is_one_shot) {
                break;
            }

            try self.wait_for_next_cycle(ctx, log, store, cfg, meta, pending_inv);
        }
    }

    fn process_invitation_cycle(
        self: *Mocker,
        ctx: TaskContext,
        store: *local_store.LocalStore,
        log: *logger.Logger,
        ph_client: *client_mod.Client,
        cfg: *config.Config,
        meta: *meta_mod.Meta,
        pending_inv: *?invitation.InviteToken,
    ) !void {
        _ = self;
        // Check for new invitations
        if (pending_inv.* == null) {
            if (try invitation.detect_invitation(ctx.allocator, store, log, ph_client, cfg)) |inv| {
                pending_inv.* = inv;

                // Always use IPC now
                if (ctx.ipc_client) |client| {
                    const inv_data = messages.InvitationData{
                        .id = inv.deployment,
                        .description = inv.release,
                        .from = "Pantahub",
                        .deployment = inv.deployment,
                        .release = inv.release,
                        .vendorRelease = inv.vendorRelease,
                        .earliestUpdate = inv.earliestUpdate,
                        .latestUpdate = inv.latestUpdate,
                        .mandatory = inv.mandatory orelse false,
                    };

                    // Convert inv_data to json.Value
                    var map = std.json.ObjectMap.init(ctx.allocator);
                    defer map.deinit();
                    try map.put("id", .{ .string = inv_data.id });
                    try map.put("description", .{ .string = inv_data.description });
                    try map.put("from", .{ .string = inv_data.from });
                    try map.put("deployment", .{ .string = inv_data.deployment });
                    try map.put("release", .{ .string = inv_data.release });
                    if (inv_data.vendorRelease) |v| try map.put("vendorRelease", .{ .string = v });
                    if (inv_data.earliestUpdate) |v| try map.put("earliestUpdate", .{ .string = v });
                    if (inv_data.latestUpdate) |v| try map.put("latestUpdate", .{ .string = v });
                    try map.put("mandatory", .{ .bool = inv_data.mandatory });

                    try client.sendMessage(.renderer, .render_invite, .{ .object = map });

                    if (inv.mandatory orelse false) {
                        log.log("Invitation is MANDATORY. Automatically ACCEPTING.", .{});
                        try invitation.process_answer(ctx.allocator, store, log, meta, cfg, inv, .accept);
                        invitation.free_invite(ctx.allocator, inv);
                        pending_inv.* = null;
                        return;
                    }
                }
            }
        }

        // Check for TUI response to pending invitation
        if (pending_inv.*) |inv| {
            var response: ?tui.InvitationResponse = null;
            {
                ctx.inv_response_mutex.lock();
                defer ctx.inv_response_mutex.unlock();
                response = ctx.inv_response.*;
                ctx.inv_response.* = null;
            }

            if (response) |resp| {
                try invitation.process_answer(ctx.allocator, store, log, meta, cfg, inv, switch (resp) {
                    .accept => .accept,
                    .skip => .skip,
                    .later => .later,
                });
                invitation.free_invite(ctx.allocator, inv);
                pending_inv.* = null;
            }
        }
    }

    fn process_update_cycle(
        self: *Mocker,
        ctx: TaskContext,
        store: *local_store.LocalStore,
        log: *logger.Logger,
        ph_client: *client_mod.Client,
        cfg: *config.Config,
    ) !void {
        _ = self;
        update_flow.run_update_cycle(ctx.allocator, store, log, ph_client, cfg, &ctx, ask_user_update_status) catch |err| {
            log.log("Update Cycle Error: {any}", .{err});
        };

        // Refresh revisions for progress monitoring
        const new_revs = try store.get_revisions();
        defer {
            ctx.allocator.free(new_revs.rev);
            ctx.allocator.free(new_revs.try_rev);
        }
        {
            ctx.progress_mutex.lock();
            defer ctx.progress_mutex.unlock();
            if (ctx.try_rev_ptr.*) |p| ctx.allocator.free(p);
            ctx.try_rev_ptr.* = try ctx.allocator.dupe(u8, new_revs.try_rev);
        }
    }

    fn sync_and_push(
        self: *Mocker,
        ctx: TaskContext,
        store: *local_store.LocalStore,
        log: *logger.Logger,
        ph_client: *client_mod.Client,
        cfg: *config.Config,
        meta: *meta_mod.Meta,
    ) !void {
        _ = self;
        try meta.sync(ph_client, store, log, cfg, ctx.ipc_client);
        try meta.push(ph_client, store, log, cfg, ctx.ipc_client);
    }

    fn wait_for_next_cycle(
        self: *Mocker,
        ctx: TaskContext,
        log: *logger.Logger,
        store: *local_store.LocalStore,
        cfg: *config.Config,
        meta: *meta_mod.Meta,
        pending_inv: *?invitation.InviteToken,
    ) !void {
        _ = self;
        log.log("Waiting for next cycle...", .{});
        const interval_ms: i64 = @intCast(cfg.devmeta_interval_s * std.time.ms_per_s);
        const start_time = std.time.milliTimestamp();
        while (!ctx.quit_flag.load(.acquire)) {
            if (business_logic.hasIntervalElapsed(start_time, std.time.milliTimestamp(), interval_ms)) {
                break;
            }
            if (pending_inv.*) |inv| {
                var response: ?tui.InvitationResponse = null;
                {
                    ctx.inv_response_mutex.lock();
                    defer ctx.inv_response_mutex.unlock();
                    response = ctx.inv_response.*;
                    if (response != null) ctx.inv_response.* = null;
                }
                if (response) |resp| {
                    try invitation.process_answer(ctx.allocator, store, log, meta, cfg, inv, switch (resp) {
                        .accept => .accept,
                        .skip => .skip,
                        .later => .later,
                    });
                    invitation.free_invite(ctx.allocator, inv);
                    pending_inv.* = null;
                }
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
};

fn ask_user_update_status(ctx_ptr: *const anyopaque) client_mod.UpdateStatus {
    const ctx: *const TaskContext = @ptrCast(@alignCast(ctx_ptr));

    if (ctx.ipc_client) |client| {
        client.sendMessage(.renderer, .update_required, null) catch return .DONE;

        // Block until we get a response
        const start_time = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - start_time < constants.USER_RESPONSE_TIMEOUT_MS) {
            var resp: ?tui.UpdateResponse = null;
            {
                ctx.update_response_mutex.lock();
                defer ctx.update_response_mutex.unlock();
                resp = ctx.update_response.*;
                if (resp != null) ctx.update_response.* = null;
            }

            if (resp) |r| {
                return switch (r) {
                    .updated => .UPDATED,
                    .done => .DONE,
                    .error_status => .ERROR,
                    .wontgo => .WONTGO,
                };
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        return .DONE; // Timeout
    }

    return .DONE;
}

fn check_and_process_claim(
    allocator: std.mem.Allocator,
    store: *local_store.LocalStore,
    log: *logger.Logger,
    ph_client: *client_mod.Client,
    cfg: *config.Config,
) !void {
    if (!cfg.is_claimed and cfg.creds_prn != null) {
        if (cfg.creds_prn) |prn| {
            if (std.mem.lastIndexOf(u8, prn, "/")) |idx| {
                if (idx + 1 < prn.len) {
                    log.log("Device ID: {s}", .{prn[idx + 1 ..]});
                }
            }
        }
        if (cfg.creds_challenge) |challenge| {
            log.log("Challenge: {s}", .{challenge});
        }
        log.log("Device not claimed. Polling status...", .{});
        const device_info_res = ph_client.get_device_info(cfg.creds_prn.?) catch |err| blk: {
            log.log("Failed to get device info: {any}", .{err});
            break :blk null;
        };
        if (device_info_res) |res| {
            defer allocator.free(res);
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, res, .{ .duplicate_field_behavior = .use_last }) catch |err| {
                log.log("Failed to parse device info: {any}", .{err});
                return err;
            };
            defer parsed.deinit();

            if (parsed.value.object.get("owner")) |owner_val| {
                if (owner_val == .string and owner_val.string.len > 0) {
                    log.log("Device CLAIMED by {s}! Initializing cloud state...", .{owner_val.string});
                    try cfg.set_claimed(store.*, true);

                    // After the device was claimed, we need to do login again to refresh the token
                    log.log("Refreshing token after claim...", .{});
                    try ph_client.login(cfg.creds_prn.?, cfg.creds_secret.?);
                    log.log("Login successful!", .{});

                    // Send cloud config to logger subsystem
                    if (log.ipc_client) |client| {
                        var map = std.StringArrayHashMap(std.json.Value).init(allocator);
                        defer map.deinit();
                        try map.put("host", .{ .string = cfg.pantahub_host.? });
                        try map.put("port", .{ .string = cfg.pantahub_port orelse "443" });
                        try map.put("token", .{ .string = ph_client.token.? });
                        try client.sendMessage(.logger, .subsystem_init, .{ .object = map });
                    }

                    // do syncing process
                    try ph_client.create_trail(boot_state);
                    try ph_client.post_progress(cfg.creds_prn.?, 0, .{ // Use default value
                        .status = client_mod.UpdateStatus.DONE.toString(),
                        .progress = 100,
                        .@"status-msg" = "Bootstrap complete",
                    });
                    log.log("Cloud bootstrap complete.", .{});
                }
            }
        }
    }
}

fn ensure_registered_and_logged_in(
    allocator: std.mem.Allocator,
    store: *local_store.LocalStore,
    log: *logger.Logger,
    ph_client: *client_mod.Client,
    cfg: *config.Config,
    revisions: *const local_store.Revisions,
) !void {
    if (cfg.creds_prn == null or cfg.creds_secret == null) {
        log.log("No credentials found. Registering device...", .{});
        const creds = try ph_client.register_device(
            cfg.pantahub_host.?,
            cfg.pantahub_port orelse "443",
            cfg.factory_autotok,
        );
        log.log("Device registered. PRN: {s}", .{creds.prn});
        if (std.mem.lastIndexOf(u8, creds.prn, "/")) |idx| {
            if (idx + 1 < creds.prn.len) {
                log.log("Device ID: {s}", .{creds.prn[idx + 1 ..]});
            }
        }
        if (creds.challenge) |c| {
            log.log("Challenge received: {s}", .{c});
        }

        try cfg.save_credentials(
            store.*,
            creds.prn,
            creds.secret,
            creds.challenge,
        );
        log.log("Credentials saved.", .{});

        log.log("Initializing bootstrap state (Revision 0)...", .{});
        try store.set_revision("0");
        try store.init_revision_dirs("0");
        try store.save_revision_state("0", boot_state);
        log.log("Progress JSON for revision 0: {s}", .{boot_progress});
        try store.save_revision_progress("0", boot_progress);

        log.log("Logging in to bootstrap cloud state...", .{});
        try ph_client.login(creds.prn, creds.secret);
        if (log.debug_mode) {
            log.log("Login successful. Token: {s}", .{ph_client.token.?});
        } else {
            log.log("Login successful. Token: (OBFUSCATED)", .{});
        }

        // Send cloud config to logger subsystem
        if (log.ipc_client) |client| {
            var map = std.StringArrayHashMap(std.json.Value).init(allocator);
            defer map.deinit();
            try map.put("host", .{ .string = cfg.pantahub_host.? });
            try map.put("port", .{ .string = cfg.pantahub_port orelse "443" });
            try map.put("token", .{ .string = ph_client.token.? });
            try client.sendMessage(.logger, .subsystem_init, .{ .object = map });
        }

        allocator.free(creds.prn);
        allocator.free(creds.secret);
        if (creds.challenge) |c| allocator.free(c);
    } else {
        log.log("Credentials found for PRN: {s}", .{cfg.creds_prn.?});
        try ph_client.login(cfg.creds_prn.?, cfg.creds_secret.?);

        // Send cloud config to logger subsystem
        if (log.ipc_client) |client| {
            var map = std.StringArrayHashMap(std.json.Value).init(allocator);
            defer map.deinit();
            try map.put("host", .{ .string = cfg.pantahub_host.? });
            try map.put("port", .{ .string = cfg.pantahub_port orelse "443" });
            try map.put("token", .{ .string = ph_client.token.? });
            try client.sendMessage(.logger, .subsystem_init, .{ .object = map });
        }

        // If we are at revision 0, ensure local files exist
        if (std.mem.eql(u8, revisions.try_rev, "0")) {
            try store.init_revision_dirs("0");
            try store.save_revision_state("0", boot_state);
            log.log("Progress JSON for revision 0: {s}", .{boot_progress});
            try store.save_revision_progress("0", boot_progress);
        }
    }
}

fn check_tls_ownership(
    allocator: std.mem.Allocator,
    store: *local_store.LocalStore,
    log: *logger.Logger,
    ph_client: *client_mod.Client,
    cfg: *config.Config,
    meta: *meta_mod.Meta,
) !void {
    if (cfg.client_cert != null and cfg.client_key != null) {
        log.log("Checking TLS ownership status...", .{});
        // Check local device-meta for ovmode_status
        var is_verified = false;
        const meta_path = try std.fs.path.join(allocator, &[_][]const u8{ store.base_path, "device-meta", "meta.json" });
        defer allocator.free(meta_path);

        if (std.fs.cwd().openFile(meta_path, .{})) |file| {
            const content = try file.readToEndAlloc(allocator, 1024 * 100);
            defer allocator.free(content);
            file.close();

            if (std.json.parseFromSlice(std.json.Value, allocator, content, .{ .duplicate_field_behavior = .use_last })) |parsed| {
                defer parsed.deinit();
                if (parsed.value.object.get("ovmode_status")) |val| {
                    if (val == .string and std.mem.eql(u8, val.string, "completed")) {
                        is_verified = true;
                        log.log("Device is already verified (ovmode_status=completed).", .{});
                    }
                }
            } else |_| {}
        } else |_| {}

        if (!is_verified) {
            log.log("Device not verified. Attempting TLS ownership validation...", .{});
            // We are already logged in above.
            if (try ph_client.validate_ownership(cfg.creds_prn.?, cfg.client_cert.?, cfg.client_key.?)) {
                log.log("TLS Ownership Validation SUCCESS!", .{});

                // Update local metadata using consolidated function
                var extra_map = std.StringArrayHashMap(std.json.Value).init(allocator);
                defer extra_map.deinit();
                try extra_map.put("ovmode_status", std.json.Value{ .string = "completed" });

                try meta.update_local(store, cfg, extra_map);

                log.log("Local metadata updated. Device 'rebooting' (simulated)...", .{});
            } else {
                log.log("TLS Ownership Validation FAILED. Retrying in next cycle...", .{});
            }
        }
    }
}
