//! A terminal in raw mode, with buffered output.

const std = @import("std");
const builtin = @import("builtin");

const Terminal = @This();

/// Not necessarily stdin; the daemon will drive panes' terminals.
fd: std.posix.fd_t,
/// Settings before raw mode, restored on deinit.
original: std.posix.termios,
/// Buffered output. Write a frame, then flush.
writer: std.Io.Writer,

extern "c" fn cfmakeraw(t: *std.posix.termios) void;

const vtable: std.Io.Writer.VTable = .{ .drain = drain };

/// Switches `fd` to raw mode. Fails if it isn't a terminal.
pub fn init(fd: std.posix.fd_t, buffer: []u8) !Terminal {
    const original = try getattr(fd);

    var raw = original;
    cfmakeraw(&raw);
    try setattr(fd, raw);

    return .{
        .fd = fd,
        .original = original,
        .writer = .{ .vtable = &vtable, .buffer = buffer },
    };
}

/// Flushes, then restores the original settings. Errors are ignored.
pub fn deinit(self: *Terminal) void {
    self.flush() catch {};
    setattr(self.fd, self.original) catch {};
}

// On Linux, std.posix.termios is the kernel's struct (NCCS 19, 44 bytes), but
// with libc linked std.posix.tcgetattr calls glibc's, whose struct is larger
// (NCCS 32, 60 bytes) and overflows ours. Use the ioctls directly there.
// cfmakeraw only touches the flags and c_cc[VMIN/VTIME], which both layouts share.

fn getattr(fd: std.posix.fd_t) !std.posix.termios {
    if (builtin.os.tag != .linux) return std.posix.tcgetattr(fd);
    const linux = std.os.linux;
    var t: std.posix.termios = undefined;
    while (true) switch (linux.errno(linux.tcgetattr(fd, &t))) {
        .SUCCESS => return t,
        .INTR => continue,
        .NOTTY => return error.NotATerminal,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

fn setattr(fd: std.posix.fd_t, t: std.posix.termios) !void {
    if (builtin.os.tag != .linux) return std.posix.tcsetattr(fd, .FLUSH, t);
    const linux = std.os.linux;
    while (true) switch (linux.errno(linux.tcsetattr(fd, .FLUSH, &t))) {
        .SUCCESS => return,
        .INTR => continue,
        .NOTTY => return error.NotATerminal,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

test "raw mode round trip on a pty" {
    const pt = struct {
        extern "c" fn posix_openpt(flags: c_int) c_int;
        extern "c" fn grantpt(fd: c_int) c_int;
        extern "c" fn unlockpt(fd: c_int) c_int;
        extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
    };
    const master = pt.posix_openpt(@bitCast(std.c.O{ .ACCMODE = .RDWR, .NOCTTY = true }));
    if (master < 0) return error.SkipZigTest;
    defer _ = std.c.close(master);
    if (pt.grantpt(master) != 0 or pt.unlockpt(master) != 0) return error.SkipZigTest;
    const name = pt.ptsname(master) orelse return error.SkipZigTest;
    const slave = std.c.open(name, .{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (slave < 0) return error.SkipZigTest;
    defer _ = std.c.close(slave);

    var buf: [64]u8 = undefined;
    var term = try Terminal.init(slave, &buf);
    const now = try getattr(slave);
    try std.testing.expect(!now.lflag.ICANON);
    try std.testing.expect(!now.lflag.ECHO);
    term.deinit();
    const back = try getattr(slave);
    try std.testing.expect(back.lflag.ICANON);
}

/// Current size in cells.
pub fn size(self: *const Terminal) !std.posix.winsize {
    var ws: std.posix.winsize = undefined;
    if (std.c.ioctl(self.fd, std.c.T.IOCGWINSZ, &ws) != 0) return error.NoTerminalSize;
    return ws;
}

/// Sends the buffered frame.
pub fn flush(self: *Terminal) !void {
    try self.writer.flush();
}

/// Sends the buffer, then `data` with the last slice repeated `splat` times.
/// Returns bytes of `data` consumed, not counting the buffer.
fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *Terminal = @fieldParentPtr("writer", w);

    writeAll(self.fd, w.buffer[0..w.end]) catch return error.WriteFailed;
    w.end = 0;

    var written: usize = 0;
    for (data[0 .. data.len - 1]) |chunk| {
        writeAll(self.fd, chunk) catch return error.WriteFailed;
        written += chunk.len;
    }

    const last = data[data.len - 1];
    for (0..splat) |_| {
        writeAll(self.fd, last) catch return error.WriteFailed;
        written += last.len;
    }

    return written;
}

/// Writes all of `bytes`, looping over short writes and EINTR.
fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining = bytes[offset..];
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        switch (std.c.errno(n)) {
            .SUCCESS => offset += @intCast(n),
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}
