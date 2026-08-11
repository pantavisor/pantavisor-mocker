const std = @import("std");
const swarm_workspace = @import("swarm_workspace.zig");

/// Convert a legacy multi-file workspace (autojointoken.txt, group_key.txt,
/// base.json, channels.json, models.txt, to_random_keys.txt) into a single
/// swarm.json. The Pantahub endpoint and automation block are not stored in
/// the legacy files, so they are recovered from already-generated devices
/// (pantahub.config / mocker.json) when present; generation counts are
/// inferred from the existing appliances/ and devices/ content.
pub const SwarmConvertCmd = struct {
    dir: []const u8 = ".",
    output: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: ?[]const u8 = null,
    force: bool = false,

    pub const meta = .{
        .description = "Convert legacy workspace config files into a single swarm.json.",
        .args = .{
            .dir = .{ .short = 'd', .help = "Workspace directory with legacy config files." },
            .output = .{ .short = 'o', .help = "Output config file name (default: swarm.json; relative to workspace, or absolute)." },
            .host = .{ .help = "Pantahub API host (default: sniffed from generated devices, else api.pantahub.com)." },
            .port = .{ .help = "Pantahub API port (default: sniffed from generated devices, else 443)." },
            .force = .{ .short = 'f', .help = "Overwrite an existing output file." },
        },
    };

    pub fn run(self: @This(), allocator: std.mem.Allocator) !void {
        std.debug.assert(self.dir.len > 0);

        const out_name = self.output orelse swarm_workspace.SWARM_JSON_NAME;
        var path_buf: [4096]u8 = undefined;
        const out_path = if (std.fs.path.isAbsolute(out_name))
            out_name
        else
            try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.dir, out_name });
        if (!self.force) {
            if (std.fs.cwd().access(out_path, .{})) |_| {
                std.debug.print("Error: {s} already exists. Use --force to overwrite it.\n", .{out_path});
                return error.AlreadyExists;
            } else |_| {}
        }

        var ws = try swarm_workspace.SwarmWorkspace.initFromLegacyFiles(allocator, self.dir);
        defer ws.deinit();

        var sniffed = Sniffed{};
        defer sniffed.deinit(allocator);
        sniffPantahubConfig(allocator, self.dir, &sniffed);
        sniffAutomation(allocator, self.dir, &sniffed);

        const host = self.host orelse (sniffed.host orelse "api.pantahub.com");
        const port = self.port orelse (sniffed.port orelse "443");
        const counts = inferCounts(self.dir);

        const compact = try composeJson(allocator, &ws, host, port, sniffed.automation_json, counts);
        defer allocator.free(compact);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, compact, .{}) catch |err| {
            std.debug.print("Error: composed config is not valid JSON ({}). Check base.json/channels.json.\n", .{err});
            return err;
        };
        defer parsed.deinit();

        const pretty = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
        defer allocator.free(pretty);

        const file = try std.fs.cwd().createFile(out_path, .{});
        defer file.close();
        try file.writeAll(pretty);

        std.debug.print("Wrote {s}\n", .{out_path});
        std.debug.print("  pantahub: {s}:{s}{s}\n", .{ host, port, if (sniffed.host != null) " (sniffed from generated devices)" else "" });
        std.debug.print("  automation: {s}\n", .{if (sniffed.automation_json != null) "copied from generated mocker.json" else "not found (none written)"});
        std.debug.print("  generate: appliances={d} devices={d} (inferred from existing content)\n", .{ counts.appliances, counts.devices });
        std.debug.print("The legacy files are now ignored ({s} takes precedence) and can be deleted.\n", .{swarm_workspace.SWARM_JSON_NAME});
    }

    const Sniffed = struct {
        host: ?[]u8 = null,
        port: ?[]u8 = null,
        automation_json: ?[]u8 = null,

        fn deinit(self: *Sniffed, allocator: std.mem.Allocator) void {
            if (self.host) |h| allocator.free(h);
            if (self.port) |p| allocator.free(p);
            if (self.automation_json) |a| allocator.free(a);
        }
    };

    const GENERATED_SUBDIRS = [_][]const u8{ "appliances", "devices" };

    /// Find the first generated pantahub.config and take PH_CREDS_HOST/PORT.
    fn sniffPantahubConfig(allocator: std.mem.Allocator, workspace_dir: []const u8, out: *Sniffed) void {
        for (GENERATED_SUBDIRS) |sub| {
            if (out.host != null) return;
            const content = readFirstMatch(allocator, workspace_dir, sub, "pantahub.config") orelse continue;
            defer allocator.free(content);
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (std.mem.startsWith(u8, trimmed, "PH_CREDS_HOST=")) {
                    if (out.host == null) out.host = allocator.dupe(u8, trimmed["PH_CREDS_HOST=".len..]) catch null;
                } else if (std.mem.startsWith(u8, trimmed, "PH_CREDS_PORT=")) {
                    if (out.port == null) out.port = allocator.dupe(u8, trimmed["PH_CREDS_PORT=".len..]) catch null;
                }
            }
        }
    }

    /// Scan generated mocker.json files until one with an automation block is
    /// found, and copy that block.
    fn sniffAutomation(allocator: std.mem.Allocator, workspace_dir: []const u8, out: *Sniffed) void {
        for (GENERATED_SUBDIRS) |sub| {
            if (out.automation_json != null) return;
            var path_buf: [4096]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ workspace_dir, sub }) catch continue;
            var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch continue;
            defer dir.close();
            var walker = dir.walk(allocator) catch continue;
            defer walker.deinit();
            while (walker.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.eql(u8, entry.basename, "mocker.json")) continue;
                const content = entry.dir.readFileAlloc(allocator, entry.basename, 64 * 1024) catch continue;
                defer allocator.free(content);
                var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch continue;
                defer parsed.deinit();
                if (parsed.value != .object) continue;
                const automation = parsed.value.object.get("automation") orelse continue;
                if (automation != .object) continue;
                out.automation_json = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(automation, .{})}) catch null;
                return;
            }
        }
    }

    /// Walk {workspace}/{sub} and return the contents of the first file whose
    /// basename matches. Caller frees.
    fn readFirstMatch(allocator: std.mem.Allocator, workspace_dir: []const u8, sub: []const u8, basename: []const u8) ?[]u8 {
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ workspace_dir, sub }) catch return null;
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return null;
        defer dir.close();
        var walker = dir.walk(allocator) catch return null;
        defer walker.deinit();
        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, entry.basename, basename)) continue;
            return entry.dir.readFileAlloc(allocator, entry.basename, 64 * 1024) catch continue;
        }
        return null;
    }

    /// Infer generation counts from existing content: devices = entries in
    /// devices/, appliances = entries under the first channel in appliances/.
    /// Falls back to the init template default (1 appliance) when nothing was
    /// generated yet.
    fn inferCounts(workspace_dir: []const u8) swarm_workspace.GenerateConfig {
        var counts = swarm_workspace.GenerateConfig{
            .appliances = countAppliancesPerChannel(workspace_dir),
            .devices = countSubdirs(workspace_dir, "devices"),
        };
        if (counts.appliances == 0 and counts.devices == 0) {
            counts.appliances = 1;
        }
        return counts;
    }

    fn countSubdirs(workspace_dir: []const u8, sub: []const u8) u32 {
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ workspace_dir, sub }) catch return 0;
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return 0;
        defer dir.close();
        var count: u32 = 0;
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind == .directory) count += 1;
        }
        return count;
    }

    fn countAppliancesPerChannel(workspace_dir: []const u8) u32 {
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/appliances", .{workspace_dir}) catch return 0;
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return 0;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            return countSubdirs(path, entry.name);
        }
        return 0;
    }

    fn composeJson(
        allocator: std.mem.Allocator,
        ws: *const swarm_workspace.SwarmWorkspace,
        host: []const u8,
        port: []const u8,
        automation_json: ?[]const u8,
        counts: swarm_workspace.GenerateConfig,
    ) ![]u8 {
        std.debug.assert(ws.autojoin_token.len > 0);
        var out = std.ArrayList(u8){};
        defer out.deinit(allocator);
        const w = out.writer(allocator);

        try w.print("{{\"pantahub\":{{\"host\":{f},\"port\":{f},\"autojoin_token\":{f}}},", .{
            std.json.fmt(host, .{}),
            std.json.fmt(port, .{}),
            std.json.fmt(ws.autojoin_token, .{}),
        });
        try w.print("\"group_key\":{f},\"random_keys\":{f},", .{
            std.json.fmt(ws.group_key, .{}),
            std.json.fmt(ws.random_keys.items, .{}),
        });
        try w.print("\"base\":{s},", .{ws.base_json});
        if (ws.channels_json) |channels| {
            try w.print("\"channels\":{s},", .{channels});
        }
        try w.print("\"models\":{f},", .{std.json.fmt(ws.models.items, .{})});
        try w.print("\"generate\":{{\"appliances\":{d},\"devices\":{d}}},", .{ counts.appliances, counts.devices });
        if (automation_json) |auto_json| {
            try w.print("\"automation\":{s},", .{auto_json});
        }
        try w.print("\"simulate\":{{\"auto\":{},\"headless\":false}}}}", .{automation_json != null});

        return allocator.dupe(u8, out.items);
    }
};
