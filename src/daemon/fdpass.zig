//! Passing file descriptors over a Unix socket (SCM_RIGHTS).
//! TLPI section 61.13.3.

const std = @import("std");
const net = std.Io.net;
const fd_t = std.posix.fd_t;

/// Most fds one read takes; extras are closed.
const max_fds = 4;

/// Sends `bytes` with a copy of `fd` attached, then flushes.
pub fn send(w: *net.Stream.Writer, bytes: []const u8, fd: fd_t) !void {
    std.debug.assert(bytes.len > 0);
    var control: [net.cmsg.space(@sizeOf(fd_t))]u8 align(net.cmsg_align) = @splat(0);
    const header: *std.posix.cmsghdr = @ptrCast(&control);
    header.* = .{ .len = net.cmsg.len(@sizeOf(fd_t)), .level = std.c.SOL.SOCKET, .type = std.c.SCM.RIGHTS };
    @memcpy(net.cmsg.data(header)[0..@sizeOf(fd_t)], std.mem.asBytes(&fd));

    // the fd rides with the first byte sent, so send what's buffered first
    try w.interface.flush();
    w.control = &control;
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

pub const Received = struct {
    /// Bytes read into the buffer; 0 when the peer hung up.
    len: usize,
    /// A passed fd, close-on-exec. The caller owns it.
    fd: ?fd_t = null,
};

/// One read into `buf`, keeping the first passed fd.
pub fn recv(stream: net.Stream, io: std.Io, buf: []u8) !Received {
    var control: [net.cmsg.space(max_fds * @sizeOf(fd_t))]u8 align(net.cmsg_align) = undefined;
    var data = [_][]u8{buf};
    const r = stream.readWithControl(io, &data, &control) catch |err| switch (err) {
        error.ConnectionResetByPeer => return .{ .len = 0 },
        else => return err,
    };

    var fd: ?fd_t = null;
    var it: net.cmsg.Iterator = .{ .control = control[0..r.control_len] };
    while (it.next()) |m| {
        if (m.header.level != std.c.SOL.SOCKET or m.header.type != std.c.SCM.RIGHTS) continue;
        var fds = m.data;
        while (fds.len >= @sizeOf(fd_t)) : (fds = fds[@sizeOf(fd_t)..]) {
            const got = std.mem.bytesToValue(fd_t, fds[0..@sizeOf(fd_t)]);
            if (fd != null) {
                _ = std.c.close(got);
                continue;
            }
            // macOS has no MSG_CMSG_CLOEXEC
            _ = std.c.fcntl(got, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
            fd = got;
        }
    }
    return .{ .len = r.data_len, .fd = fd };
}

const testing = std.testing;

fn socketPair() ![2]net.Stream {
    var fds: [2]fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
    return .{
        .{ .socket = .{ .handle = fds[0], .address = undefined } },
        .{ .socket = .{ .handle = fds[1], .address = undefined } },
    };
}

test "a passed pipe writes into the original" {
    const io = testing.io;
    const s = try socketPair();
    defer s[0].close(io);
    defer s[1].close(io);
    var pipe: [2]fd_t = undefined;
    if (std.c.pipe(&pipe) != 0) return error.Pipe;
    defer _ = std.c.close(pipe[0]);

    var wbuf: [8]u8 = undefined;
    var w = s[0].writer(io, &wbuf);
    try send(&w, "p", pipe[1]);
    _ = std.c.close(pipe[1]); // the receiver's copy keeps it open

    var buf: [8]u8 = undefined;
    const r = try recv(s[1], io, &buf);
    try testing.expectEqualStrings("p", buf[0..r.len]);
    const fd = r.fd orelse return error.NoFd;
    try testing.expect(std.c.fcntl(fd, std.c.F.GETFD) & std.c.FD_CLOEXEC != 0);
    _ = std.c.write(fd, "hi", 2);
    _ = std.c.close(fd);

    var out: [8]u8 = undefined;
    const n = std.c.read(pipe[0], &out, out.len);
    try testing.expectEqualStrings("hi", out[0..@intCast(n)]);
}

test "plain bytes, then hang-up" {
    const io = testing.io;
    const s = try socketPair();
    defer s[1].close(io);
    var wbuf: [8]u8 = undefined;
    var w = s[0].writer(io, &wbuf);
    try w.interface.writeAll("w");
    try w.interface.flush();
    s[0].close(io);

    var buf: [8]u8 = undefined;
    const r = try recv(s[1], io, &buf);
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(@as(?fd_t, null), r.fd);
    try testing.expectEqual(@as(usize, 0), (try recv(s[1], io, &buf)).len);
}
