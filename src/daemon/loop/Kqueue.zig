//! An event loop on kqueue: register fds and signals once, then wait for
//! whichever is ready. Each watch carries a token that comes back with its
//! events.

const std = @import("std");
const fd_t = std.posix.fd_t;

const Loop = @This();

kq: fd_t,
/// Signal actions before addSignal, restored on deinit.
old: [32]?std.c.Sigaction,

pub const Event = struct {
    token: usize,
    kind: Kind,
    /// The other end hung up. There may still be bytes to read first.
    eof: bool,

    pub const Kind = enum { read, signal, timer };
};

pub fn init() !Loop {
    const kq = std.c.kqueue();
    if (kq < 0) return error.KqueueFailed;
    // not inherited by children such as Neovim
    _ = std.c.fcntl(kq, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    return .{ .kq = kq, .old = @splat(null) };
}

/// Restores the old signal actions, then closes the kqueue.
pub fn deinit(self: *Loop) void {
    // restore first, so no signal is ignored once nothing watches it
    for (self.old, 0..) |maybe_old_action, n| {
        if (maybe_old_action) |old_action| {
            std.posix.sigaction(@fromBackingInt(@intCast(n)), &old_action, null);
        }
    }
    _ = std.c.close(self.kq);
    self.* = undefined;
}

/// Watches `fd` for reading. Adding it again replaces the token.
pub fn addRead(self: *const Loop, fd: fd_t, token: usize) !void {
    try self.change(@intCast(fd), std.c.EVFILT.READ, std.c.EV.ADD, token);
}

/// Stops watching `fd`. Call before closing it: on Linux, a copy of the
/// fd held elsewhere keeps it registered.
pub fn remove(self: *const Loop, fd: fd_t) !void {
    try self.change(@intCast(fd), std.c.EVFILT.READ, std.c.EV.DELETE, 0);
}

/// Watches `sig`, and ignores it so its default action never runs.
pub fn addSignal(self: *Loop, sig: std.c.SIG, token: usize) !void {
    const n = @backingInt(sig);
    // only the first time, so a second call can't save our own SIG_IGN
    if (self.old[n] == null) {
        var old: std.c.Sigaction = undefined;
        std.posix.sigaction(sig, null, &old);
        self.old[n] = old;
    }
    const ignore: std.c.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.mem.zeroes(std.c.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(sig, &ignore, null);
    try self.change(n, std.c.EVFILT.SIGNAL, std.c.EV.ADD, token);
}

/// Fires once, `ms` milliseconds from now. Adding timer `id` again
/// restarts it.
pub fn addTimer(self: *const Loop, id: usize, ms: u32, token: usize) !void {
    try self.changeData(id, std.c.EVFILT.TIMER, std.c.EV.ADD | std.c.EV.ONESHOT, token, ms);
}

/// Blocks until something is ready, then fills the start of `buf`.
pub fn wait(self: *const Loop, buf: []Event) ![]Event {
    var raw: [64]std.c.Kevent = undefined;
    const max: c_int = @intCast(@min(buf.len, raw.len));
    const n: usize = while (true) {
        const rc = std.c.kevent(self.kq, &raw, 0, &raw, max, null);
        if (rc >= 0) break @intCast(rc);
        if (std.c.errno(rc) != .INTR) return error.KeventFailed;
    };

    for (raw[0..n], buf[0..n]) |e, *out| {
        if (e.flags & std.c.EV.ERROR != 0) return error.KeventFailed;
        out.* = .{
            .token = e.udata,
            .kind = switch (e.filter) {
                std.c.EVFILT.READ => .read,
                std.c.EVFILT.SIGNAL => .signal,
                std.c.EVFILT.TIMER => .timer,
                else => unreachable, // only these are registered
            },
            .eof = e.flags & std.c.EV.EOF != 0,
        };
    }
    return buf[0..n];
}

/// Registers one change with the kqueue.
fn change(self: *const Loop, ident: usize, filter: i16, flags: u16, token: usize) !void {
    try self.changeData(ident, filter, flags, token, 0);
}

fn changeData(self: *const Loop, ident: usize, filter: i16, flags: u16, token: usize, data: isize) !void {
    const changes = [_]std.c.Kevent{.{
        .ident = ident,
        .filter = filter,
        .flags = flags,
        .fflags = 0,
        .data = data,
        .udata = token,
    }};
    var none: [0]std.c.Kevent = undefined;
    if (std.c.kevent(self.kq, &changes, changes.len, &none, 0, null) < 0) return error.KeventFailed;
}
