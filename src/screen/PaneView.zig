//! What one pane's terminal shows: a window's grid from the top left, the
//! floats over it and, in the focused pane, the screen's floats and the
//! message grid over the bottom rows. Remembers what it drew so each frame
//! sends only what changed.
//!
//! Floats are drawn into their window's pane, except groups shown in Rex
//! floating panes, which `frameFloats` draws on their own.

const std = @import("std");
const Writer = std.Io.Writer;
const Grid = @import("Grid.zig");
const Grids = @import("Grids.zig");
const render = @import("render.zig");
const Style = @import("Style.zig");

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

/// How a pane draws the screen's floats and messages.
pub const Opts = struct {
    /// Draws the messages and the screen's floats.
    focused: bool = false,
    /// The pane's top left on grid 1, which spans the Rex window: screen
    /// floats move by it, then into the pane.
    origin: [2]i32 = .{ 0, 0 },
    /// Editor floats shown elsewhere, with every float hanging from them.
    skip: []const u32 = &.{},
};

/// A float as drawn, in terminal cells.
pub const Rect = struct {
    grid: u32,
    row: i32,
    col: i32,
    width: u32,
    height: u32,
    on_screen: bool = false,
    on_msg: bool = false,

    fn rows(r: Rect, limit: u32) struct { u32, u32 } {
        const top: u32 = @intCast(std.math.clamp(r.row, 0, @as(i64, limit)));
        const bot: u32 = @intCast(std.math.clamp(@as(i64, r.row) + r.height, 0, @as(i64, limit)));
        return .{ top, bot };
    }
};

/// Widest row floats are drawn into.
const max_cols = 1024;
/// Tallest terminal a floating pane draws into.
const max_rows = 512;

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
pub fn frame(self: *PaneView, grids: *Grids, grid_id: ?u32, opts: Opts, w: *Writer) Writer.Error!bool {
    const focused = opts.focused;
    const style = &grids.style;
    style.clearBlends();
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
    const rects = if (g != null) self.fitScreen(floatRects(grids, grids.floatsOver(id, focused, opts.skip, &placed_buf), &rects_buf), opts.origin, screenRows(grids)) else rects_buf[0..0];
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

fn screenRows(grids: *const Grids) u32 {
    return if (grids.get(1)) |g| g.height else 0;
}

/// Screen floats moved from grid 1 into the pane at `origin`, and kept
/// inside it where they fit. Message floats keep to the bottom, as the
/// messages do.
fn fitScreen(self: *const PaneView, rects: []Rect, origin: [2]i32, screen_rows: u32) []Rect {
    for (rects) |*r| if (r.on_screen) {
        const up: i32 = if (r.on_msg) @as(i32, @intCast(screen_rows)) - @as(i32, @intCast(self.rows)) else origin[0];
        r.row = fitInto(r.row - up, r.height, self.rows);
        if (!r.on_msg) r.col -= origin[1];
        r.col = fitInto(r.col, r.width, self.cols);
    };
    return rects;
}

/// `pos` moved back inside `0..limit` if `len` fits there.
fn fitInto(pos: i32, len: u32, limit: u32) i32 {
    if (len > limit) return @max(@min(pos, 0), @as(i32, @intCast(limit)) - @as(i32, @intCast(len)));
    return std.math.clamp(pos, 0, @as(i32, @intCast(limit - len)));
}

/// The floats drawn last frame, lowest first.
pub fn drawnFloats(self: *const PaneView) []const Rect {
    return self.drawn_floats[0..self.drawn_floats_len];
}

/// Draws just floats `placed`, moved up and left by `origin`, over a blank
/// terminal: a group shown in a Rex floating pane. True if it wrote anything.
pub fn frameFloats(self: *PaneView, grids: *Grids, placed: []const Grids.Placed, origin: [2]i32, w: *Writer) Writer.Error!bool {
    const style = &grids.style;
    style.clearBlends();
    var rects_buf: [Grids.max_floats]Rect = undefined;
    const rects = floatRects(grids, placed, &rects_buf);
    for (rects) |*r| {
        r.row -= origin[0];
        r.col -= origin[1];
    }
    if (!sameRects(rects, self.drawnFloats())) self.full = true;

    var dirty: std.StaticBitSet(max_rows) = .empty;
    const rows = @min(self.rows, max_rows);
    for (rects) |r| {
        const f = grids.get(r.grid).?;
        const top, const bot = r.rows(rows);
        if (f.scrolls_len > 0) {
            for (top..bot) |i| dirty.set(i);
            continue;
        }
        var it = f.dirty.iterator(.{});
        while (it.next()) |fr| {
            const tr = @as(i64, r.row) + @as(i64, @intCast(fr));
            if (tr >= 0 and tr < rows) dirty.set(@intCast(tr));
        }
    }
    const cur = floatCursor(grids, rects, rows, self.cols);
    if (!self.full and dirty.count() == 0 and std.meta.eql(cur, self.drawn_cursor)) return false;

    try render.begin(w);
    var current: ?u32 = null;
    if (self.full) {
        try render.setHl(style, 0, w, &current);
        try w.writeAll("\x1b[2J");
        dirty = .empty;
        for (rects) |r| {
            const top, const bot = r.rows(rows);
            for (top..bot) |i| dirty.set(i);
        }
    }
    var it = dirty.iterator(.{});
    while (it.next()) |r| {
        var line: [max_cols]Grid.Cell = undefined;
        const shown = compose(grids, &.{}, rects, @intCast(r), @min(self.cols, max_cols), &line);
        try render.drawRow(shown, style, @intCast(r), self.cols, w, &current);
    }
    try render.end(style, cur, w);

    self.full = false;
    self.drawn_grid = 0;
    self.drawn_size = .{ 0, 0 };
    self.drawn_cursor = cur;
    @memcpy(self.drawn_floats[0..rects.len], rects);
    self.drawn_floats_len = @intCast(rects.len);
    return true;
}

/// The cursor, if it's on one of the floats and inside the terminal.
fn floatCursor(grids: *const Grids, rects: []const Rect, rows: u32, cols: u32) ?render.Cursor {
    for (rects) |r| if (grids.cursor_grid == r.grid) {
        const f = grids.get(r.grid).?;
        const row = @as(i64, r.row) + f.cursor_row;
        const col = @as(i64, r.col) + f.cursor_col;
        if (row < 0 or row >= rows or col < 0 or col >= cols) return null;
        return .{ .row = @intCast(row), .col = @intCast(col) };
    };
    return null;
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
        out[n] = .{ .grid = p.grid, .row = p.row, .col = p.col, .width = f.width, .height = f.height, .on_screen = p.on_screen, .on_msg = p.on_msg };
        n += 1;
    }
    return out[0..n];
}

/// Base row `row` at terminal row `r` with the floats over it, in `line`.
/// Just `row` if no float covers it.
fn compose(grids: *Grids, row: []const Grid.Cell, rects: []const Rect, r: u32, cols: u32, line: *[max_cols]Grid.Cell) []const Grid.Cell {
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
        for (src[skip..][0..n], left..) |cell, i| line[i] = blendCell(&grids.style, cell, line[0..width], i);
        if (line[left].len == 0) line[left] = .{ .hl = line[left].hl };
    }
    return line[0..width];
}

/// Float cell `cell` over `line[i]`. A blended blank lets the text under
/// it show, unless that's half a wide char.
fn blendCell(style: *Style, cell: Grid.Cell, line: []const Grid.Cell, i: usize) Grid.Cell {
    if (style.attr(cell.hl).blend == 0) return cell;
    const under = line[i];
    const wide = under.len == 0 or (i + 1 < line.len and line[i + 1].len == 0);
    if (cell.len == 1 and cell.text[0] == ' ' and !wide) {
        var c = under;
        c.hl = style.blendOver(cell.hl, under.hl, true);
        return c;
    }
    var c = cell;
    c.hl = style.blendOver(cell.hl, under.hl, false);
    return c;
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

const testing = std.testing;

test "screen floats move into the pane and stay inside it" {
    const view: PaneView = .init(20, 10);
    var rects = [_]Rect{
        // over the pane at 0, 30 of a wider screen
        .{ .grid = 3, .row = 2, .col = 35, .width = 4, .height = 2, .on_screen = true },
        // past its right edge: moved back in
        .{ .grid = 4, .row = 0, .col = 70, .width = 8, .height = 1, .on_screen = true },
        // over a window: left alone
        .{ .grid = 5, .row = 1, .col = 1, .width = 2, .height = 1 },
        // on the messages: kept to the bottom
        .{ .grid = 6, .row = 25, .col = 2, .width = 5, .height = 3, .on_screen = true, .on_msg = true },
    };
    _ = view.fitScreen(&rects, .{ 0, 30 }, 30);
    try testing.expectEqual(@as(i32, 2), rects[0].row);
    try testing.expectEqual(@as(i32, 5), rects[0].col);
    try testing.expectEqual(@as(i32, 12), rects[1].col);
    try testing.expectEqual(@as(i32, 1), rects[2].col);
    try testing.expectEqual(@as(i32, 5), rects[3].row);
    try testing.expectEqual(@as(i32, 2), rects[3].col);
}

test "frameFloats draws a group on its own and the cursor in it" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    try gs.grids.put(testing.allocator, 3, .{});
    try gs.grids.getPtr(3).?.resize(testing.allocator, 6, 2);
    try gs.grids.put(testing.allocator, 4, .{});
    try gs.grids.getPtr(4).?.resize(testing.allocator, 3, 1);
    gs.grids.getPtr(3).?.cells[0] = .init("a", 0);
    gs.grids.getPtr(4).?.cells[0] = .init("b", 0);
    gs.cursor_grid = 4;
    gs.grids.getPtr(4).?.cursor_col = 1;
    const placed = [_]Grids.Placed{
        .{ .grid = 3, .row = 10, .col = 20, .zindex = 50, .compindex = 0 },
        .{ .grid = 4, .row = 11, .col = 21, .zindex = 51, .compindex = 1 },
    };
    var view: PaneView = .init(8, 4);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expect(try view.frameFloats(&gs, &placed, .{ 10, 20 }, &out.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "a") != null);
    try testing.expectEqual(render.Cursor{ .row = 1, .col = 2 }, view.drawn_cursor.?);
    try testing.expectEqual(@as(usize, 2), view.drawnFloats().len);
    // nothing changed: nothing drawn
    gs.grids.getPtr(3).?.dirty.unsetAll();
    gs.grids.getPtr(4).?.dirty.unsetAll();
    try testing.expect(!try view.frameFloats(&gs, &placed, .{ 10, 20 }, &out.writer));
}
