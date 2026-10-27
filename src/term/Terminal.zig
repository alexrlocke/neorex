//! A terminal in raw mode, with buffered output.

const std = @import("std");

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
    const original = try std.posix.tcgetattr(fd);

    var raw = original;
    cfmakeraw(&raw);
    try std.posix.tcsetattr(fd, .FLUSH, raw);

    return .{
        .fd = fd,
        .original = original,
        .writer = .{ .vtable = &vtable, .buffer = buffer },
    };
}

/// Flushes, then restores the original settings. Errors are ignored.
pub fn deinit(self: *Terminal) void {
    self.flush() catch {};
    std.posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
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
