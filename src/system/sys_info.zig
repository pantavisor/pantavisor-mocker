const std = @import("std");
const builtin = @import("builtin");

pub const SysInfo = struct {
    pub const Interfaces = std.StringArrayHashMap(std.ArrayList([]const u8));

    pub const Storage = struct {
        free: u64,
        real_free: u64,
        reserved: u64,
        total: u64,
    };

    pub const Uname = struct {
        @"kernel.name": []const u8,
        @"kernel.release": []const u8,
        @"kernel.version": []const u8,
        machine: []const u8,
        @"node.name": []const u8,
    };

    pub const Info = struct {
        bufferram: u64,
        freehigh: u64,
        freeram: u64,
        freeswap: u64,
        @"loads.0": u64,
        @"loads.1": u64,
        @"loads.2": u64,
        mem_unit: u32,
        procs: u16,
        sharedram: u64,
        totalhigh: u64,
        totalram: u64,
        totalswap: u64,
        uptime: i64,
    };

    pub const Time = struct {
        timeval: struct {
            tv_sec: i64,
            tv_usec: i64,
        },
        timezone: struct {
            tz_dsttime: i32,
            tz_minuteswest: i32,
        },
    };
};

const c = @cImport({
    @cInclude("ifaddrs.h");
    @cInclude("netdb.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("sys/statvfs.h");
    @cInclude("sys/sysinfo.h");
    @cInclude("sys/time.h");
});

pub fn get_uname(allocator: std.mem.Allocator) !SysInfo.Uname {
    const u = std.posix.uname();
    std.debug.assert(u.sysname[0] != 0);
    std.debug.assert(u.release[0] != 0);

    var res: SysInfo.Uname = .{
        .@"kernel.name" = try allocator.dupe(u8, std.mem.sliceTo(&u.sysname, 0)),
        .@"kernel.release" = undefined,
        .@"kernel.version" = undefined,
        .machine = undefined,
        .@"node.name" = undefined,
    };
    errdefer allocator.free(res.@"kernel.name");

    res.@"kernel.release" = try allocator.dupe(u8, std.mem.sliceTo(&u.release, 0));
    errdefer allocator.free(res.@"kernel.release");

    res.@"kernel.version" = try allocator.dupe(u8, std.mem.sliceTo(&u.version, 0));
    errdefer allocator.free(res.@"kernel.version");

    res.machine = try allocator.dupe(u8, std.mem.sliceTo(&u.machine, 0));
    errdefer allocator.free(res.machine);

    res.@"node.name" = try allocator.dupe(u8, std.mem.sliceTo(&u.nodename, 0));

    return res;
}

pub fn get_storage(path: []const u8) !SysInfo.Storage {
    std.debug.assert(path.len > 0);
    const path_z = try std.posix.toPosixPath(path);
    var s: c.struct_statvfs = undefined;
    if (c.statvfs(&path_z, &s) != 0) return error.StatVfsFailed;
    std.debug.assert(s.f_blocks > 0);

    const total = @as(u64, s.f_blocks) * s.f_frsize;
    const free = @as(u64, s.f_bfree) * s.f_frsize;
    const real_free = @as(u64, s.f_bavail) * s.f_frsize;
    const reserved = free - real_free;

    return .{
        .total = total,
        .free = free,
        .real_free = real_free,
        .reserved = reserved,
    };
}

pub fn get_sysinfo() !SysInfo.Info {
    var si: c.struct_sysinfo = undefined;
    if (c.sysinfo(&si) != 0) return error.SysinfoFailed;
    std.debug.assert(si.uptime >= 0);
    std.debug.assert(si.totalram > 0);

    return .{
        .bufferram = si.bufferram,
        .freehigh = si.freehigh,
        .freeram = si.freeram,
        .freeswap = si.freeswap,
        .@"loads.0" = si.loads[0],
        .@"loads.1" = si.loads[1],
        .@"loads.2" = si.loads[2],
        .mem_unit = si.mem_unit,
        .procs = si.procs,
        .sharedram = si.sharedram,
        .totalhigh = si.totalhigh,
        .totalram = si.totalram,
        .totalswap = si.totalswap,
        .uptime = si.uptime,
    };
}

pub fn get_time() SysInfo.Time {
    var tv: c.struct_timeval = undefined;
    var tz: c.struct_timezone = undefined;
    _ = c.gettimeofday(&tv, &tz);
    std.debug.assert(tv.tv_sec > 0);
    return .{
        .timeval = .{ .tv_sec = tv.tv_sec, .tv_usec = tv.tv_usec },
        .timezone = .{ .tz_dsttime = tz.tz_dsttime, .tz_minuteswest = tz.tz_minuteswest },
    };
}

pub fn get_dtmodel(allocator: std.mem.Allocator) ![]const u8 {
    const path = "/proc/device-tree/model";
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err == error.FileNotFound) return allocator.dupe(u8, "Mock Device Model");
        return err;
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024);
    std.debug.assert(content.len > 0);
    const trimmed = std.mem.trimRight(u8, content, "\x00\n\r ");
    allocator.free(content);
    return allocator.dupe(u8, trimmed);
}

pub fn get_interfaces(allocator: std.mem.Allocator) ![]const u8 {
    var ifap: ?*c.ifaddrs = null;
    if (c.getifaddrs(&ifap) != 0) return error.GetIfAddrsFailed;
    defer c.freeifaddrs(ifap);

    var interface_map = std.StringArrayHashMap(std.ArrayList([]const u8)).init(allocator);
    defer {
        var it = interface_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |val| allocator.free(val);
            entry.value_ptr.deinit(allocator);
        }
        interface_map.deinit();
    }

    var curr = ifap;
    while (curr) |ifa| : (curr = ifa.*.ifa_next) {
        if (ifa.*.ifa_addr == null) continue;
        const family = ifa.*.ifa_addr.*.sa_family;
        if (family != c.AF_INET and family != c.AF_INET6) continue;

        const name = std.mem.sliceTo(ifa.*.ifa_name, 0);
        const suffix = if (family == c.AF_INET) ".ipv4" else ".ipv6";
        const key = try std.mem.concat(allocator, u8, &[_][]const u8{ name, suffix });
        defer allocator.free(key);

        var buf: [c.NI_MAXHOST]u8 = undefined;
        const addr_len: c.socklen_t = if (family == c.AF_INET) @sizeOf(c.struct_sockaddr_in) else @sizeOf(c.struct_sockaddr_in6);
        if (c.getnameinfo(ifa.*.ifa_addr, addr_len, &buf, buf.len, null, 0, c.NI_NUMERICHOST) != 0) continue;
        const addr_str = std.mem.sliceTo(&buf, 0);

        const entry = try interface_map.getOrPut(key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try allocator.dupe(u8, key);
            entry.value_ptr.* = std.ArrayList([]const u8){};
        }
        const addr_dupe = try allocator.dupe(u8, addr_str);
        errdefer allocator.free(addr_dupe);
        try entry.value_ptr.append(allocator, addr_dupe);
    }

    var list = std.ArrayList(u8){};
    errdefer list.deinit(allocator);
    try list.append(allocator, '{');

    var first_if = true;
    var it = interface_map.iterator();
    while (it.next()) |entry| {
        if (!first_if) try list.appendSlice(allocator, ", ");
        try list.writer(allocator).print("\"{s}\": [", .{entry.key_ptr.*});
        for (entry.value_ptr.items, 0..) |addr, i| {
            if (i > 0) try list.appendSlice(allocator, ", ");
            try list.writer(allocator).print("\"{s}\"", .{addr});
        }
        try list.append(allocator, ']');
        first_if = false;
    }
    try list.append(allocator, '}');
    return list.toOwnedSlice(allocator);
}

pub fn get_arch(allocator: std.mem.Allocator) ![]const u8 {
    const arch_name = @tagName(builtin.cpu.arch);
    const bits = builtin.target.ptrBitWidth();
    const endian = if (builtin.target.cpu.arch.endian() == .little) "EL" else "EB";
    return std.fmt.allocPrint(allocator, "{s}/{d}/{s}", .{ arch_name, bits, endian });
}
