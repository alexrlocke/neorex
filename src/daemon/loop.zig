//! The daemon's event loop: kqueue on macOS, epoll on Linux. Both have
//! the same API; the tests below run against whichever is built.

const std = @import("std");
const builtin = @import("builtin");
const fd_t = std.posix.fd_t;

pub const Loop = switch (builtin.os.tag) {
    .macos => @import("loop/Kqueue.zig"),
    // becomes @import("loop/Epoll.zig") once that exists: Zig loads every
    // imported file, even in a branch it doesn't take
    .linux => @compileError("the epoll loop isn't written yet"),
    else => @compileError("neorex runs on macOS and Linux"),
};

const Event = Loop.Event;
const testing = std.testing;

fn pipe() ![2]fd_t {
    var p: [2]fd_t = undefined;
    if (std.c.pipe(&p) != 0) return error.Pipe;
    return p;
}

test "a readable pipe, then its hang-up" {
    var loop: Loop = try .init();
    defer loop.deinit();
    const p = try pipe();
    defer _ = std.c.close(p[0]);
    try loop.addRead(p[0], 7);

    _ = std.c.write(p[1], "x", 1);
    var buf: [4]Event = undefined;
    try testing.expectEqualSlices(Event, &.{.{ .token = 7, .kind = .read, .eof = false }}, try loop.wait(&buf));

    _ = std.c.close(p[1]);
    try testing.expectEqualSlices(Event, &.{.{ .token = 7, .kind = .read, .eof = true }}, try loop.wait(&buf));
}

test "only ready fds are reported; removed ones aren't" {
    var loop: Loop = try .init();
    defer loop.deinit();
    const a = try pipe();
    const b = try pipe();
    defer for (a ++ b) |fd| {
        _ = std.c.close(fd);
    };
    try loop.addRead(a[0], 1);
    try loop.addRead(b[0], 2);
    try loop.remove(a[0]);

    _ = std.c.write(a[1], "x", 1);
    _ = std.c.write(b[1], "x", 1);
    var buf: [4]Event = undefined;
    try testing.expectEqualSlices(Event, &.{.{ .token = 2, .kind = .read, .eof = false }}, try loop.wait(&buf));
}

test "signals arrive as events and the old action comes back" {
    var loop: Loop = try .init();
    try loop.addSignal(.USR1, 9);
    // the whole process: raise only signals this thread, which kqueue misses
    _ = std.c.kill(std.c.getpid(), .USR1);
    var buf: [4]Event = undefined;
    try testing.expectEqualSlices(Event, &.{.{ .token = 9, .kind = .signal, .eof = false }}, try loop.wait(&buf));

    loop.deinit();
    var now: std.c.Sigaction = undefined;
    std.posix.sigaction(.USR1, null, &now);
    try testing.expect(now.handler.handler != std.c.SIG.IGN);
}

test "a timer fires once" {
    var loop: Loop = try .init();
    defer loop.deinit();
    try loop.addTimer(1, 5, 11);
    var buf: [4]Event = undefined;
    try testing.expectEqualSlices(Event, &.{.{ .token = 11, .kind = .timer, .eof = false }}, try loop.wait(&buf));
}
