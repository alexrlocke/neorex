//! One of Neovim's grids: its cells, dirty rows, cursor and pending scrolls.
//! `Grids` routes redraw events here by grid id.

const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("../nvim/msgpack.zig");
const rpc = @import("../nvim/rpc.zig");

const Grid = @This();

width: u32 = 0,
height: u32 = 0,
/// Row-major, `width * height` cells.
cells: []Cell = &.{},
/// Rows changed since the renderer last cleared this.
dirty: std.DynamicBitSetUnmanaged = .{},
cursor_row: u32 = 0,
cursor_col: u32 = 0,
/// Full-width scrolls since the last frame, for the terminal to repeat.
scrolls: [max_scrolls]Scroll = undefined,
scrolls_len: u8 = 0,

const max_scrolls = 8;

/// Rows `top..bot` moved up by `rows`, down if negative.
pub const Scroll = struct { top: u32, bot: u32, rows: i32 };

pub const Cell = struct {
    /// One grapheme cluster. Empty for the right half of a wide char.
    text: [max_text]u8 = " ".* ++ @as([max_text - 1]u8, @splat(0)),
    len: u8 = 1,
    hl: u32 = 0,

    /// Longer clusters are stored as U+FFFD.
    pub const max_text = 31;

    pub fn str(self: *const Cell) []const u8 {
        return self.text[0..self.len];
    }

    pub fn init(text: []const u8, hl: u32) Cell {
        var c: Cell = .{ .hl = hl };
        const t = if (text.len <= max_text) text else "\u{fffd}";
        @memcpy(c.text[0..t.len], t);
        c.len = @intCast(t.len);
        return c;
    }
};

pub fn deinit(self: *Grid, gpa: Allocator) void {
    gpa.free(self.cells);
    self.dirty.deinit(gpa);
    self.* = undefined;
}

/// Scrolls to repeat before drawing the dirty rows.
pub fn pendingScrolls(self: *const Grid) []const Scroll {
    return self.scrolls[0..self.scrolls_len];
}

pub fn row(self: *const Grid, r: u32) []const Cell {
    return self.cells[r * self.width ..][0..self.width];
}

/// New size, keeping the cells that still fit; the rest are blank. Every
/// row is dirty. Neovim only redraws a resized window's rows that changed.
pub fn resize(self: *Grid, gpa: Allocator, w: u32, h: u32) !void {
    const cells = try gpa.alloc(Cell, @as(usize, w) * h);
    @memset(cells, .{});
    const keep = @min(w, self.width);
    for (0..@min(h, self.height)) |r| @memcpy(cells[r * w ..][0..keep], self.cells[r * self.width ..][0..keep]);
    gpa.free(self.cells);
    self.cells = cells;
    self.width = w;
    self.height = h;
    try self.dirty.resize(gpa, h, true);
    self.dirty.setAll();
    self.scrolls_len = 0;
    self.cursor_row = @min(self.cursor_row, h -| 1);
    self.cursor_col = @min(self.cursor_col, w -| 1);
}

pub fn clear(self: *Grid) void {
    @memset(self.cells, .{});
    self.dirty.setAll();
    self.scrolls_len = 0;
}

/// `grid_line`'s cells: `[text, hl_id?, repeat?]`, from column `col`.
pub fn line(self: *Grid, d: *msgpack.Decoder, r: u32, col: u32) !void {
    if (r >= self.height) return error.BadMessage;
    const dst = self.cells[r * self.width ..][0..self.width];
    var c = col;
    // an absent hl_id means the previous cell's
    var hl: u32 = 0;
    const count = try rpc.expectArray(d);
    for (0..count) |_| {
        const len = try rpc.expectArray(d);
        if (len == 0) return error.BadMessage;
        const text = try rpc.expectStr(d);
        if (len >= 2) hl = try expectInt(d, u32);
        const repeat: u32 = if (len >= 3) try expectInt(d, u32) else 1;
        for (3..@max(len, 3)) |_| try rpc.skip(d);
        const cell: Cell = .init(text, hl);
        for (0..repeat) |_| {
            if (c >= self.width) return error.BadMessage;
            dst[c] = cell;
            c += 1;
        }
    }
    self.dirty.set(r);
}

/// Moves rows `top..bot`, columns `left..right`, up by `rows` (down if
/// negative). The rows left behind are refilled by grid_line events.
pub fn scroll(self: *Grid, top: u32, bot: u32, left: u32, right: u32, rows: i64) !void {
    if (top > bot or bot > self.height or left > right or right > self.width) return error.BadMessage;
    if (rows == 0) return;
    const n: u32 = @intCast(@min(@abs(rows), bot - top));
    const w = right - left;
    if (rows > 0) {
        // up: copy top to bottom, so no source row is overwritten first
        var r = top;
        while (r + n < bot) : (r += 1) self.copyRow(r + n, r, left, w);
    } else {
        // down: copy bottom to top, for the same reason
        var r = bot;
        while (r > top + n) {
            r -= 1;
            self.copyRow(r - n, r, left, w);
        }
    }

    // a split window's scroll can't be repeated, so redraw its rows
    const full = left == 0 and right == self.width;
    if (!full or n == bot - top or self.scrolls_len == max_scrolls) {
        for (top..bot) |r| self.dirty.set(r);
        return;
    }
    self.scrolls[self.scrolls_len] = .{ .top = top, .bot = bot, .rows = if (rows > 0) @intCast(n) else -@as(i32, @intCast(n)) };
    self.scrolls_len += 1;
    // dirty bits move with their rows; only the rows left behind are new
    if (rows > 0) {
        for (top..bot - n) |r| self.dirty.setValue(r, self.dirty.isSet(r + n));
        for (bot - n..bot) |r| self.dirty.set(r);
    } else {
        var r = bot;
        while (r > top + n) {
            r -= 1;
            self.dirty.setValue(r, self.dirty.isSet(r - n));
        }
        for (top..top + n) |i| self.dirty.set(i);
    }
}

fn copyRow(self: *Grid, from: u32, to: u32, left: u32, w: u32) void {
    const src = self.cells[from * self.width + left ..][0..w];
    const dst = self.cells[to * self.width + left ..][0..w];
    @memcpy(dst, src);
}

fn expectInt(d: *msgpack.Decoder, comptime T: type) !T {
    return std.math.cast(T, try rpc.expectInt(d)) orelse error.BadMessage;
}

const testing = std.testing;
const Writer = std.Io.Writer;

/// Row `r` as text, wide-char halves dropped.
pub fn rowText(g: *const Grid, r: u32, buf: []u8) []const u8 {
    var w: Writer = .fixed(buf);
    for (g.row(r)) |c| w.writeAll(c.str()) catch break;
    return w.buffered();
}

test "resize keeps what still fits" {
    var g: Grid = .{};
    defer g.deinit(testing.allocator);
    try g.resize(testing.allocator, 3, 2);
    for (g.cells, 0..) |*c, i| c.* = .init(&.{@intCast('a' + i)}, 0);
    g.dirty.unsetAll();
    try g.resize(testing.allocator, 2, 3);
    var buf: [8]u8 = undefined;
    for ([_][]const u8{ "ab", "de", "  " }, 0..) |want, r| try testing.expectEqualStrings(want, rowText(&g, @intCast(r), &buf));
    try testing.expectEqual(@as(usize, 3), g.dirty.count());
}

test "scroll up and down" {
    var g: Grid = .{};
    defer g.deinit(testing.allocator);
    try g.resize(testing.allocator, 2, 5);
    for (0..5) |r| g.cells[r * 2] = .init(&.{@intCast('a' + r)}, 0);
    var buf: [8]u8 = undefined;

    // rows 1..4 up by 1: rows 1..3 get rows 2..4; row 3 is left for grid_line
    try g.scroll(1, 4, 0, 2, 1);
    const up = [_][]const u8{ "a ", "c ", "d ", "d ", "e " };
    for (up, 0..) |want, r| try testing.expectEqualStrings(want, rowText(&g, @intCast(r), &buf));

    // rows 0..5 down by 2: rows 2..5 get rows 0..3; rows 0..2 are left
    try g.scroll(0, 5, 0, 2, -2);
    const down = [_][]const u8{ "a ", "c ", "a ", "c ", "d " };
    for (down, 0..) |want, r| try testing.expectEqualStrings(want, rowText(&g, @intCast(r), &buf));
}

test "full-width scrolls are kept; dirty rows move with them" {
    var g: Grid = .{};
    defer g.deinit(testing.allocator);
    try g.resize(testing.allocator, 2, 5);
    g.dirty.unsetAll();
    g.dirty.set(3);

    try g.scroll(0, 5, 0, 2, 2);
    try testing.expectEqualSlices(Scroll, &.{.{ .top = 0, .bot = 5, .rows = 2 }}, g.pendingScrolls());
    // row 3 moved to 1; rows 3 and 4 were left behind
    for ([_]bool{ false, true, false, true, true }, 0..) |want, r| try testing.expectEqual(want, g.dirty.isSet(r));

    // not full width: no scroll kept, the region is redrawn
    g.dirty.unsetAll();
    try g.scroll(1, 3, 0, 1, -1);
    try testing.expectEqual(@as(usize, 1), g.pendingScrolls().len);
    for ([_]bool{ false, true, true, false, false }, 0..) |want, r| try testing.expectEqual(want, g.dirty.isSet(r));
}
