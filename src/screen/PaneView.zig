//! What one pane's terminal shows: a window's grid from the top left, the
//! floats over it and, in the focused pane, the screen's floats and the
//! message grid over the bottom rows. Remembers what it drew so each frame
//! sends only what changed.
//!
//! Floats are drawn into their window's pane. Once Rex's floating panes
//! mature, they could be Rex floating panes instead.

const std = @import("std");
const Writer = std.Io.Writer;
const Grid = @import("Grid.zig");
const Grids = @import("Grids.zig");
const render = @import("render.zig");

const PaneView = @This();

/// The terminal's size.
cols: u32,
rows: u32,
/// Draw everything on the next frame.
full: bool = true,
/// The grid drawn last, and its size.
drawn_grid: u32 = 0,
drawn_size: [2]u32 = .{ 0, 0 },
/// Message rows drawn over the bottom last frame.
drawn_msg: u32 = 0,
drawn_cursor: ?render.Cursor = null,
/// The floats drawn last frame.
drawn_floats: [Grids.max_floats]Rect = undefined,
drawn_floats_len: u8 = 0,

/// A float as drawn, in terminal cells.
const Rect = struct {
    grid: u32,
    row: i32,
    col: i32,
    width: u32,
    height: u32,

    fn rows(r: Rect, limit: u32) struct { u32, u32 } {
        const top: u32 = @intCast(std.math.clamp(r.row, 0, @as(i64, limit)));
        const bot: u32 = @intCast(std.math.clamp(@as(i64, r.row) + r.height, 0, @as(i64, limit)));
        return .{ top, bot };
    }
};

/// Widest row floats are drawn into.
const max_cols = 1024;

pub fn init(cols: u32, rows: u32) PaneView {
    return .{ .cols = cols, .rows = rows };
}

/// The terminal changed size; its old contents can't be trusted.
pub fn resize(self: *PaneView, cols: u32, rows: u32) void {
    if (cols == self.cols and rows == self.rows) return;
    self.cols = cols;
    self.rows = rows;
    self.full = true;
}

/// Draws a frame if anything changed: grid `grid_id` (null for none yet)
/// and, if `focused`, the messages. Clears the grid's dirty rows but not
/// the message grid's, which the caller clears once every pane is drawn.
/// True if it wrote anything.
pub fn frame(self: *PaneView, grids: *Grids, grid_id: ?u32, focused: bool, w: *Writer) Writer.Error!bool {
    const style = &grids.style;
    const id = grid_id orelse 0;
    const g: ?*Grid = if (grid_id) |i| grids.get(i) else null;
    const size: [2]u32 = if (g) |gr| .{ gr.width, gr.height } else .{ 0, 0 };
    if (id != self.drawn_grid or !std.mem.eql(u32, &size, &self.drawn_size)) self.full = true;

    // the message grid's rows that show, from the bottom
    const msg_total = if (focused) grids.msgRows() else 0;
    const msg_n = @min(msg_total, self.rows);
    const msg: ?*Grid = if (msg_n > 0) grids.get(grids.msg_grid.?) else null;
    const msg_top = self.rows - msg_n;
    const grid_rows = @min(size[1], msg_top);

    var placed_buf: [Grids.max_floats]Grids.Placed = undefined;
    var rects_buf: [Grids.max_floats]Rect = undefined;
    const rects = if (g != null) floatRects(grids, grids.floatsOver(id, focused, &placed_buf), &rects_buf) else rects_buf[0..0];
    const floats_moved = !sameRects(rects, self.drawn_floats[0..self.drawn_floats_len]);
    var floats_changed = floats_moved;
    for (rects) |r| {
        const f = grids.get(r.grid).?;
        if (f.dirty.count() > 0 or f.scrolls_len > 0) floats_changed = true;
    }

    const cur = self.cursorAt(grids, g, id, grid_rows, msg, msg_total, msg_n, rects);
    const grid_changed = floats_changed or if (g) |gr| gr.dirty.count() > 0 or gr.scrolls_len > 0 else false;
    const msg_changed = if (msg) |m| m.dirty.count() > 0 or msg_n != self.drawn_msg else msg_n != self.drawn_msg;
    if (!self.full and !grid_changed and !msg_changed and std.meta.eql(cur, self.drawn_cursor)) return false;

    try render.begin(w);
    var current: ?u32 = null;
    if (self.full) {
        // ED fills with the current background
        try render.setHl(style, 0, w, &current);
        try w.writeAll("\x1b[2J");
        if (g) |gr| {
            gr.dirty.setAll();
            gr.scrolls_len = 0;
        }
    } else if (g) |gr| {
        try self.scrolls(gr, grid_rows, rects, w);
        // rows under floats that moved, changed or went
        if (floats_moved) for (self.drawn_floats[0..self.drawn_floats_len]) |r| markRows(gr, r, grid_rows);
        for (rects) |r| {
            const f = grids.get(r.grid).?;
            if (floats_moved or f.scrolls_len > 0) {
                markRows(gr, r, grid_rows);
                continue;
            }
            var it = f.dirty.iterator(.{});
            while (it.next()) |fr| {
                const tr = @as(i64, r.row) + @as(i64, @intCast(fr));
                if (tr >= 0 and tr < grid_rows) gr.dirty.set(@intCast(tr));
            }
        }
        // rows the messages covered last frame and no longer do
        const old_top = self.rows - @min(self.drawn_msg, self.rows);
        for (@min(old_top, msg_top)..msg_top) |r| {
            if (r < grid_rows) gr.dirty.set(r) else try render.clearRow(style, @intCast(r), w, &current);
        }
    } else {
        const old_top = self.rows - @min(self.drawn_msg, self.rows);
        for (@min(old_top, msg_top)..msg_top) |r| try render.clearRow(style, @intCast(r), w, &current);
    }
    if (g) |gr| {
        var it = gr.dirty.iterator(.{});
        while (it.next()) |r| {
            if (r >= grid_rows) break;
            const row = gr.row(@intCast(r));
            var line: [max_cols]Grid.Cell = undefined;
            const shown = compose(grids, row, rects, @intCast(r), @min(self.cols, max_cols), &line);
            try render.drawRow(shown, style, @intCast(r), self.cols, w, &current);
        }
        gr.dirty.unsetAll();
    }
    if (msg) |m| if (self.full or msg_changed) {
        for (0..msg_n) |i| {
            const src: u32 = @intCast(msg_total - msg_n + i);
            try render.drawRow(m.row(src), style, @intCast(msg_top + i), self.cols, w, &current);
        }
    };
    try render.end(style, cur, w);

    self.full = false;
    self.drawn_grid = id;
    self.drawn_size = size;
    self.drawn_msg = msg_n;
    self.drawn_cursor = cur;
    @memcpy(self.drawn_floats[0..rects.len], rects);
    self.drawn_floats_len = @intCast(rects.len);
    return true;
}

/// Repeats the grid's scrolls if they stay clear of the messages and
/// floats; else redraws the rows they moved.
fn scrolls(self: *const PaneView, g: *Grid, grid_rows: u32, rects: []const Rect, w: *Writer) Writer.Error!void {
    const pending = g.pendingScrolls();
    for (pending) |s| if (s.bot > grid_rows or underFloat(s, rects, grid_rows)) {
        // one can't be repeated, so none are: the terminal must match each in turn
        for (pending) |p| for (p.top..p.bot) |r| g.dirty.set(r);
        g.scrolls_len = 0;
        return;
    };
    _ = self;
    try render.replayScrolls(g, w);
}

fn sameRects(a: []const Rect, b: []const Rect) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

fn underFloat(s: Grid.Scroll, rects: []const Rect, grid_rows: u32) bool {
    for (rects) |r| {
        const top, const bot = r.rows(grid_rows);
        if (top < s.bot and s.top < bot) return true;
    }
    return false;
}

fn markRows(g: *Grid, r: Rect, grid_rows: u32) void {
    const top, const bot = r.rows(grid_rows);
    for (top..bot) |i| g.dirty.set(i);
}

/// The floats' rects, lowest first, leaving out empty ones.
fn floatRects(grids: *const Grids, placed: []const Grids.Placed, out: *[Grids.max_floats]Rect) []Rect {
    var n: usize = 0;
    for (placed) |p| {
        const f = grids.get(p.grid) orelse continue;
        if (f.width == 0 or f.height == 0) continue;
        out[n] = .{ .grid = p.grid, .row = p.row, .col = p.col, .width = f.width, .height = f.height };
        n += 1;
    }
    return out[0..n];
}

/// Base row `row` at terminal row `r` with the floats over it, in `line`.
/// Just `row` if no float covers it.
fn compose(grids: *const Grids, row: []const Grid.Cell, rects: []const Rect, r: u32, cols: u32, line: *[max_cols]Grid.Cell) []const Grid.Cell {
    var width: usize = row.len;
    var covered = false;
    for (rects) |f| {
        if (r < f.row or r >= @as(i64, f.row) + f.height) continue;
        covered = true;
        width = @max(width, @as(usize, @intCast(std.math.clamp(@as(i64, f.col) + f.width, 0, @as(i64, cols)))));
    }
    if (!covered) return row;
    width = @min(width, cols);
    const base = row[0..@min(row.len, width)];
    @memcpy(line[0..base.len], base);
    @memset(line[base.len..width], .{});
    for (rects) |f| {
        if (r < f.row or r >= @as(i64, f.row) + f.height) continue;
        const src = grids.get(f.grid).?.row(@intCast(@as(i64, r) - f.row));
        const left: usize = @intCast(@max(f.col, 0));
        const skip: usize = @intCast(@max(-f.col, 0));
        if (left >= width or skip >= src.len) continue;
        const n = @min(src.len - skip, width - left);
        // a wide char cut by the float's edges leaves a blank
        if (left > 0 and line[left].len == 0) line[left - 1] = .{ .hl = line[left - 1].hl };
        if (left + n < width and line[left + n].len == 0) line[left + n] = .{ .hl = line[left + n].hl };
        @memcpy(line[left..][0..n], src[skip..][0..n]);
        if (line[left].len == 0) line[left] = .{ .hl = line[left].hl };
    }
    return line[0..width];
}

/// Where the cursor shows in this pane, if it does.
fn cursorAt(self: *const PaneView, grids: *const Grids, g: ?*Grid, id: u32, grid_rows: u32, msg: ?*Grid, msg_total: u32, msg_n: u32, rects: []const Rect) ?render.Cursor {
    for (rects) |r| if (grids.cursor_grid == r.grid) {
        const f = grids.get(r.grid).?;
        const row = @as(i64, r.row) + f.cursor_row;
        const col = @as(i64, r.col) + f.cursor_col;
        if (row < 0 or row >= grid_rows or col < 0 or col >= self.cols) return null;
        return .{ .row = @intCast(row), .col = @intCast(col) };
    };
    if (g) |gr| if (grids.cursor_grid == id) {
        if (gr.cursor_row < grid_rows and gr.cursor_col < self.cols) return .{ .row = gr.cursor_row, .col = gr.cursor_col };
        return null;
    };
    const m = msg orelse return null;
    if (grids.cursor_grid != grids.msg_grid.?) return null;
    const first = msg_total - msg_n;
    if (m.cursor_row < first or m.cursor_row >= msg_total or m.cursor_col >= self.cols) return null;
    return .{ .row = self.rows - msg_n + (m.cursor_row - first), .col = m.cursor_col };
}
