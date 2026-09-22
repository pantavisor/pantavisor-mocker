const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    if (builtin.os.tag == .linux) @cInclude("sys/signalfd.h");
});

/// A pollable fd that becomes readable on SIGINT/SIGTERM. Linux uses
/// signalfd (signals blocked, delivered through the fd); macOS has no
/// signalfd, so a handler writes into a self-pipe whose read end is returned.
/// Only one may be open at a time.
var pipe_write_fd: c_int = -1;

fn onSignal(_: i32) callconv(.c) void {
    const byte: u8 = 1;
    _ = c.write(pipe_write_fd, &byte, 1);
}

pub fn open() !c_int {
    if (builtin.os.tag == .linux) {
        var mask: c.sigset_t = undefined;
        _ = c.sigemptyset(&mask);
        _ = c.sigaddset(&mask, c.SIGINT);
        _ = c.sigaddset(&mask, c.SIGTERM);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &mask, null);
        const fd = c.signalfd(-1, &mask, c.SFD_CLOEXEC);
        if (fd == -1) return error.SignalFdFailed;
        return fd;
    }

    std.debug.assert(pipe_write_fd == -1);
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.SignalFdFailed;
    for (fds) |fd| _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
    // The handler must never block on a full pipe.
    _ = c.fcntl(fds[1], c.F_SETFL, c.fcntl(fds[1], c.F_GETFL) | c.O_NONBLOCK);
    pipe_write_fd = fds[1];
    setHandler(.{ .handler = onSignal });
    return fds[0];
}

// Via std.posix: C's SIG_DFL macro doesn't translate on macOS.
fn setHandler(handler: @FieldType(std.posix.Sigaction, "handler")) void {
    const act = std.posix.Sigaction{ .handler = handler, .mask = std.posix.sigemptyset(), .flags = std.posix.SA.RESTART };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

pub fn close(fd: c_int) void {
    if (builtin.os.tag != .linux) {
        // Detach the handler before the write end's fd number can be reused.
        setHandler(.{ .handler = std.posix.SIG.DFL });
        _ = c.close(pipe_write_fd);
        pipe_write_fd = -1;
    }
    _ = c.close(fd);
}

test "signal fd becomes readable on SIGTERM" {
    const fd = try open();
    defer close(fd);
    _ = c.raise(c.SIGTERM);
    var fds = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 1000));
    // Drain it (a signalfd_siginfo on Linux, one byte on the self-pipe).
    var buf: [128]u8 = undefined;
    try std.testing.expect(c.read(fd, &buf, buf.len) > 0);
}
