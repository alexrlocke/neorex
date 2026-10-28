//! `neorex pane SOCKET [ID]`: the helper each Rex pane runs. It hands its
//! terminal to the daemon, then waits. When the daemon hangs up it exits,
//! and Rex closes the pane. The ID says which window the daemon made the
//! pane for; the launcher's own pane has none.

const std = @import("std");
const net = std.Io.net;
const Signals = @import("../term/Signals.zig");
const fdpass = @import("fdpass.zig");

/// What a helper sends the daemon, one byte each.
pub const Message = enum(u8) {
    /// First, with the terminal's fd attached, then the ID in decimal if any.
    hello = 'p',
    /// The terminal was resized. Only the helper gets SIGWINCH: it's in
    /// the terminal's foreground process group, the daemon isn't.
    resized = 'w',
    _,
};

pub fn run(io: std.Io, socket_path: []const u8, id: ?u32) !void {
    const tty = std.posix.STDIN_FILENO;
    if (std.c.isatty(tty) == 0) return error.NotATerminal;

    // before the hello, so a resize in between isn't missed
    var signals = try Signals.init(&.{.WINCH});
    defer signals.deinit();

    const addr = try net.UnixAddress.init(socket_path);
    const stream = try addr.connect(io);
    defer stream.close(io);
    var buf: [16]u8 = undefined;
    var w = stream.writer(io, &buf);
    var hello_buf: [16]u8 = undefined;
    try fdpass.send(&w, try helloBytes(&hello_buf, id), tty);

    while (true) {
        var fds = [_]std.c.pollfd{
            .{ .fd = stream.socket.handle, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = signals.read_fd, .events = std.c.POLL.IN, .revents = 0 },
        };
        const ready = std.c.poll(&fds, fds.len, -1);
        if (ready < 0) {
            if (std.c.errno(ready) == .INTR) continue;
            return error.PollFailed;
        }
        if (fds[1].revents != 0 and (try signals.drain()).contains(.WINCH)) {
            try w.interface.writeByte(@intFromEnum(Message.resized));
            try w.interface.flush();
        }
        if (fds[0].revents != 0) {
            var in: [64]u8 = undefined;
            // nothing is sent this way yet; hang-up is the only message
            if ((try fdpass.recv(stream, io, &in)).len == 0) return;
        }
    }
}

/// The hello message: `p`, then the ID if there is one.
pub fn helloBytes(buf: []u8, id: ?u32) ![]const u8 {
    if (id) |n| return std.fmt.bufPrint(buf, "{c}{d}", .{ @intFromEnum(Message.hello), n });
    buf[0] = @intFromEnum(Message.hello);
    return buf[0..1];
}

/// The ID in a hello: null for the launcher's pane.
pub fn parseHello(bytes: []const u8) !?u32 {
    if (bytes.len == 0 or bytes[0] != @intFromEnum(Message.hello)) return error.BadHello;
    if (bytes.len == 1) return null;
    return std.fmt.parseInt(u32, bytes[1..], 10) catch error.BadHello;
}

test "hello carries the ID" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?u32, null), try parseHello(try helloBytes(&buf, null)));
    try std.testing.expectEqual(@as(?u32, 42), try parseHello(try helloBytes(&buf, 42)));
    try std.testing.expectError(error.BadHello, parseHello("w"));
    try std.testing.expectError(error.BadHello, parseHello("px"));
}
