//! Turns Unix signals into fd events using the self-pipe trick.

const std = @import("std");

const Signals = @This();

/// Read end. Poll it; readable when a signal has fired.
read_fd: std.posix.fd_t,
/// Write end, written by the handler.
write_fd: std.posix.fd_t,
/// Old actions by signal number, restored on deinit.
old: [32]?std.c.Sigaction = @splat(null),

/// Write end for the handler, which can't see `self`. -1 if no Signals exists.
var handler_fd: std.posix.fd_t = -1;

/// Creates the pipe and installs the handler for each signal. One per process.
pub fn init(signals: []const std.c.SIG) !Signals {
    // one Signals per process
    std.debug.assert(handler_fd == -1);

    // non-blocking so neither end can hang; close-on-exec so children don't inherit it
    const fds: [2]std.posix.fd_t = try std.Io.Threaded.pipe2(.{
        .NONBLOCK = true,
        .CLOEXEC = true,
    });
    var self: Signals = .{ .read_fd = fds[0], .write_fd = fds[1] };

    // before installing, so the handler never sees -1
    handler_fd = self.write_fd;

    const action: std.c.Sigaction = .{
        .handler = .{ .handler = handle },
        .mask = std.posix.sigemptyset(),
        .flags = std.c.SA.RESTART,
    };

    for (signals) |sig| {
        const n = @backingInt(sig);
        std.debug.assert(n < self.old.len);
        var old: std.c.Sigaction = undefined;
        std.posix.sigaction(sig, &action, &old);
        self.old[n] = old;
    }

    return self;
}

/// Writes the signal number to the pipe. Only async-signal-safe calls here.
fn handle(sig: std.c.SIG) callconv(.c) void {
    // write can clobber errno mid-check in the interrupted code
    const saved = std.c._errno().*;
    defer std.c._errno().* = saved;
    const byte = [1]u8{@intCast(@backingInt(sig))};
    _ = std.c.write(handler_fd, &byte, byte.len);
}

/// Restores the old actions, then closes the pipe.
pub fn deinit(self: *Signals) void {
    // restore first, so no handler writes to a closed fd
    for (self.old, 0..) |maybe_old_action, n| {
        if (maybe_old_action) |old_action| {
            std.posix.sigaction(@fromBackingInt(@intCast(n)), &old_action, null);
        }
    }
    handler_fd = -1;
    _ = std.c.close(self.read_fd);
    _ = std.c.close(self.write_fd);
    self.* = undefined;
}

/// Empties the pipe and returns which signals fired. Call when read_fd is readable.
pub fn drain(self: *Signals) !Set {
    var set: Set = .{};
    var buf: [64]u8 = @splat(0);
    while (true) {
        const n = std.posix.read(self.read_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return set, // pipe empty
            else => return err,
        };
        // EOF means every write end is closed, but we hold one
        if (n == 0) return error.WriteEndClosed;
        for (buf[0..n]) |byte| set.bits.set(byte);
    }
}

/// Which signals fired since the last drain.
pub const Set = struct {
    // TODO: std.EnumSet(std.c.SIG) once it stops crashing on macOS
    bits: std.bit_set.IntegerBitSet(32) = .empty,

    pub fn contains(self: Set, sig: std.c.SIG) bool {
        return self.bits.isSet(@backingInt(sig));
    }
};

test "raise then drain" {
    var s = try Signals.init(&.{.WINCH});
    defer s.deinit();
    _ = std.c.raise(.WINCH);
    _ = std.c.raise(.WINCH);
    const fired = try s.drain();
    try std.testing.expect(fired.contains(.WINCH));
    try std.testing.expect(!fired.contains(.TERM));
}

test "empty drain" {
    var s = try Signals.init(&.{.WINCH});
    defer s.deinit();
    try std.testing.expectEqual(@as(u32, 0), (try s.drain()).bits.mask);
}
