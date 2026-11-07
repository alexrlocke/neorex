//! An event loop on epoll, for Linux, with the same API as Kqueue.zig.
//! Register fds, signals and timers once, then wait for whichever is
//! ready. Each watch carries a token that comes back with its events.
//!
//! Signals come through a self-pipe, added to epoll under an internal
//! token. Timers are deadlines kept here: the nearest one is epoll_wait's
//! timeout, as in libxev and libuv.

const std = @import("std");
const linux = std.os.linux;
const EPOLL = linux.EPOLL;
const fd_t = std.posix.fd_t;
const Signals = @import("../../term/Signals.zig");

const Epoll = @This();

ep: fd_t,
/// Made on the first addSignal: one per process.
signals: ?Signals = null,
/// The caller's token for each signal number, if watched.
signal_tokens: [32]?usize = @splat(null),
/// Null once fired. The daemon uses two.
timers: [4]?Timer = @splat(null),

pub const Event = struct {
    token: usize,
    kind: Kind,
    /// The other end hung up. There may still be bytes to read first.
    eof: bool,

    pub const Kind = enum { read, signal, timer };
};

const Timer = struct {
    id: usize,
    /// On the monotonic clock, in nanoseconds.
    deadline: u64,
    token: usize,
};

/// Ours, so caller tokens stay below it.
const signal_pipe_token = std.math.maxInt(usize);

pub fn init() !Epoll {
    const ep = std.c.epoll_create1(EPOLL.CLOEXEC);
    if (ep < 0) return error.EpollFailed;
    return .{ .ep = ep };
}

/// Restores the old signal actions, then closes epoll.
pub fn deinit(self: *Epoll) void {
    if (self.signals) |*s| s.deinit();
    _ = std.c.close(self.ep);
    self.* = undefined;
}

/// Watches `fd` for reading. Adding it again replaces the token.
pub fn addRead(self: *const Epoll, fd: fd_t, token: usize) !void {
    std.debug.assert(token != signal_pipe_token);
    try self.watch(fd, token);
}

/// Stops watching `fd`. Call before closing it: a copy of the fd held
/// elsewhere, such as by a child process, keeps it registered.
pub fn remove(self: *const Epoll, fd: fd_t) !void {
    if (std.c.epoll_ctl(self.ep, EPOLL.CTL_DEL, fd, null) < 0) return error.EpollFailed;
}

/// Watches `sig`, and handles it so its default action never runs.
pub fn addSignal(self: *Epoll, sig: std.c.SIG, token: usize) !void {
    if (self.signals == null) {
        var s: Signals = try .init(&.{});
        errdefer s.deinit();
        try self.watch(s.read_fd, signal_pipe_token);
        self.signals = s;
    }
    self.signals.?.add(sig);
    self.signal_tokens[@backingInt(sig)] = token;
}

/// Fires once, `ms` milliseconds from now. Adding timer `id` again
/// restarts it.
pub fn addTimer(self: *Epoll, id: usize, ms: u32, token: usize) !void {
    const slot = for (&self.timers) |*s| {
        if (s.*) |t| if (t.id == id) break s;
    } else for (&self.timers) |*s| {
        if (s.* == null) break s;
    } else return error.TooManyTimers;
    slot.* = .{ .id = id, .deadline = now() + @as(u64, ms) * std.time.ns_per_ms, .token = token };
}

/// Blocks until something is ready, then fills the start of `buf`. What
/// doesn't fit stays ready for the next call.
pub fn wait(self: *Epoll, buf: []Event) ![]Event {
    var raw: [64]linux.epoll_event = undefined;
    const n: usize = while (true) {
        const rc = std.c.epoll_wait(self.ep, &raw, @intCast(@min(buf.len, raw.len)), self.timeout());
        if (rc >= 0) break @intCast(rc);
        if (std.c.errno(rc) != .INTR) return error.EpollFailed;
    };

    var len: usize = 0;
    var signalled = false;
    for (raw[0..n]) |e| {
        if (e.data.u64 == signal_pipe_token) {
            signalled = true;
            continue;
        }
        // a hang-up is a read that returns 0, as with kqueue
        const eof = e.events & (EPOLL.HUP | EPOLL.RDHUP | EPOLL.ERR) != 0;
        buf[len] = .{ .token = e.data.u64, .kind = .read, .eof = eof };
        len += 1;
    }
    // after the reads, which always fit, so these never crowd them out
    if (signalled) len += self.readSignals(buf[len..]);
    const t = now();
    for (&self.timers) |*slot| if (slot.*) |timer| {
        if (len == buf.len) break;
        if (timer.deadline > t) continue;
        buf[len] = .{ .token = timer.token, .kind = .timer, .eof = false };
        len += 1;
        slot.* = null;
    };
    return buf[0..len];
}

/// One event per signal, for as many as fit in `out`. The rest stay in the
/// pipe, which keeps it readable.
fn readSignals(self: *const Epoll, out: []Event) usize {
    var bytes: [32]u8 = undefined;
    const rc = std.c.read(self.signals.?.read_fd, &bytes, @min(out.len, bytes.len));
    // empty: another read took them
    if (rc <= 0) return 0;
    var seen: u32 = 0;
    var len: usize = 0;
    for (bytes[0..@intCast(rc)]) |sig| {
        // once per wait, as kqueue reports it
        const bit = @as(u32, 1) << @intCast(sig);
        if (seen & bit != 0) continue;
        seen |= bit;
        out[len] = .{ .token = self.signal_tokens[sig].?, .kind = .signal, .eof = false };
        len += 1;
    }
    return len;
}

/// Milliseconds to the nearest timer, rounded up so it never wakes early.
/// -1 with none: wait forever.
fn timeout(self: *const Epoll) c_int {
    var nearest: ?u64 = null;
    for (self.timers) |maybe_timer| if (maybe_timer) |t| {
        nearest = @min(nearest orelse t.deadline, t.deadline);
    };
    const left = (nearest orelse return -1) -| now();
    return @intCast(@min(std.math.divCeil(u64, left, std.time.ns_per_ms) catch unreachable, std.math.maxInt(c_int)));
}

/// Adds `fd` to epoll, or replaces its token if it's already there.
fn watch(self: *const Epoll, fd: fd_t, token: usize) !void {
    var ev: linux.epoll_event = .{ .events = EPOLL.IN | EPOLL.RDHUP, .data = .{ .u64 = token } };
    const rc = std.c.epoll_ctl(self.ep, EPOLL.CTL_ADD, fd, &ev);
    if (rc == 0) return;
    if (std.c.errno(rc) != .EXIST) return error.EpollFailed;
    if (std.c.epoll_ctl(self.ep, EPOLL.CTL_MOD, fd, &ev) < 0) return error.EpollFailed;
}

/// Nanoseconds on the monotonic clock.
fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
