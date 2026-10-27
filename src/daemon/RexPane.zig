//! One Rex pane showing one Neovim window: the helper's connection, its
//! terminal in raw mode, and what's drawn there. Heap-allocated, since the
//! terminal's writer points into `out_buf`.

const std = @import("std");
const net = std.Io.net;
const Terminal = @import("../term/Terminal.zig");
const modes = @import("../term/modes.zig");
const Forwarder = @import("../nvim/Forwarder.zig");
const PaneView = @import("../screen/PaneView.zig");

const RexPane = @This();

/// Matches the helper's hello to this pane. The launcher's pane is 0.
id: u32,
/// The Neovim window shown; 0 until one is given.
win: i64 = 0,
/// Rex's block, owned; null until `session.new_split` answers.
block: ?[]u8 = null,
/// Keep the pane when its window closes: a new window takes it.
reuse: bool = false,
/// Rex couldn't make it; it waits only to be freed.
failed: bool = false,
/// Its terminal is gone, so there's nothing to restore.
gone: bool = false,
/// The connected helper; null until it says hello.
conn: ?Conn = null,
view: PaneView = .init(0, 0),
forwarder: Forwarder = .{ .ctrl_q_quits = false, .send_focus = false },
/// The window size last asked of Neovim, and for which grid.
asked: struct { grid: u32 = 0, cols: u32 = 0, rows: u32 = 0 } = .{},
out_buf: [32 * 1024]u8 = undefined,

pub const Conn = struct {
    stream: net.Stream,
    term: Terminal,
};

/// Loop tokens from here up, two per pane id.
pub const token_base = 8;

pub const Source = enum(u1) { socket, tty };

pub fn token(self: *const RexPane, source: Source) usize {
    return token_base + 2 * @as(usize, self.id) + @intFromEnum(source);
}

/// The pane id and source a loop token names.
pub fn fromToken(t: usize) struct { id: u32, source: Source } {
    return .{ .id = @intCast((t - token_base) / 2), .source = @enumFromInt((t - token_base) % 2) };
}

/// Takes over the helper's terminal: raw mode, the editor's modes, and
/// its size.
pub fn connect(self: *RexPane, stream: net.Stream, tty: std.posix.fd_t) !void {
    var term = try Terminal.init(tty, &self.out_buf);
    errdefer term.deinit();
    try term.writer.writeAll(modes.editor_on);
    const ws = try term.size();
    self.conn = .{ .stream = stream, .term = term };
    self.view = .init(ws.col, ws.row);
}

/// Restores the terminal and hangs up, so the helper exits and Rex closes
/// the pane. Frees `block`.
pub fn deinit(self: *RexPane, gpa: std.mem.Allocator, io: std.Io) void {
    if (self.conn) |*c| {
        if (!self.gone) {
            c.term.writer.writeAll(modes.editor_off) catch {};
            c.term.deinit();
        }
        _ = std.c.close(c.term.fd);
        c.stream.close(io);
    }
    if (self.block) |b| gpa.free(b);
    self.* = undefined;
}

/// Where the window's rows end: the last row is the message line.
pub fn windowSize(self: *const RexPane) [2]u32 {
    return .{ @max(self.view.cols, 1), @max(self.view.rows -| 1, 1) };
}

test "tokens round-trip" {
    const p: RexPane = .{ .id = 5 };
    const t = fromToken(p.token(.tty));
    try std.testing.expectEqual(@as(u32, 5), t.id);
    try std.testing.expectEqual(Source.tty, t.source);
    try std.testing.expect(p.token(.socket) >= token_base);
}
