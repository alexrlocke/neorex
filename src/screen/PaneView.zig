//! What one pane's terminal shows: a window's grid from the top left and,
//! in the focused pane, the message grid over the bottom rows. Remembers
//! what it drew so each frame sends only what changed.

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

    const cur = self.cursorAt(grids, g, id, grid_rows, msg, msg_total, msg_n);
    const grid_changed = if (g) |gr| gr.dirty.count() > 0 or gr.scrolls_len > 0 else false;
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
        try self.scrolls(gr, grid_rows, w);
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
            try render.drawRow(gr.row(@intCast(r)), style, @intCast(r), self.cols, w, &current);
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
    return true;
}

/// Repeats the grid's scrolls if they stay clear of the messages; else
/// redraws the rows they moved.
fn scrolls(self: *const PaneView, g: *Grid, grid_rows: u32, w: *Writer) Writer.Error!void {
    const pending = g.pendingScrolls();
    for (pending) |s| if (s.bot > grid_rows) {
        // one can't be repeated, so none are: the terminal must match each in turn
        for (pending) |p| for (p.top..p.bot) |r| g.dirty.set(r);
        g.scrolls_len = 0;
        return;
    };
    _ = self;
    try render.replayScrolls(g, w);
}

/// Where the cursor shows in this pane, if it does.
fn cursorAt(self: *const PaneView, grids: *const Grids, g: ?*Grid, id: u32, grid_rows: u32, msg: ?*Grid, msg_total: u32, msg_n: u32) ?render.Cursor {
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
