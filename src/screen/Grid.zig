//! What Neovim's grid looks like, built from its redraw events.
//! Only grid 1: without ext_multigrid, Neovim draws everything there.

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
/// Highlight attributes by id. Id 0 is the default.
attrs: std.ArrayList(Attr) = .empty,
/// Defaults for colors an `Attr` leaves null.
default_fg: ?u24 = null,
default_bg: ?u24 = null,
default_sp: ?u24 = null,
/// Cursor looks by mode, from `mode_info_set`.
cursor_modes: std.ArrayList(CursorMode) = .empty,
/// False when 'guicursor' is empty: leave the terminal's cursor alone.
cursor_style_enabled: bool = false,
mode_idx: u32 = 0,
/// Between busy_start and busy_stop, the cursor is hidden.
busy: bool = false,
/// Full-width scrolls since the last frame, for the terminal to repeat.
scrolls: [max_scrolls]Scroll = undefined,
scrolls_len: u8 = 0,

const max_scrolls = 8;

pub const CursorMode = struct {
    shape: Shape = .block,
    blink: bool = false,

    pub const Shape = enum { block, horizontal, vertical };
};

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

/// A highlight from `hl_attr_define`. Null colors mean the default.
pub const Attr = struct {
    fg: ?u24 = null,
    bg: ?u24 = null,
    sp: ?u24 = null,
    bold: bool = false,
    italic: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
    dim: bool = false,
    blink: bool = false,
    conceal: bool = false,
    overline: bool = false,
    altfont: bool = false,
    underline: Underline = .none,
    /// 0 to 100.
    blend: u8 = 0,

    pub const Underline = enum { none, single, curl, double, dotted, dashed };
};

pub fn deinit(self: *Grid, gpa: Allocator) void {
    gpa.free(self.cells);
    self.dirty.deinit(gpa);
    self.attrs.deinit(gpa);
    self.cursor_modes.deinit(gpa);
    self.* = undefined;
}

/// How the cursor should look now; null to leave it alone.
pub fn cursorMode(self: *const Grid) ?CursorMode {
    if (!self.cursor_style_enabled or self.mode_idx >= self.cursor_modes.items.len) return null;
    return self.cursor_modes.items[self.mode_idx];
}

/// Scrolls to repeat before drawing the dirty rows.
pub fn pendingScrolls(self: *const Grid) []const Scroll {
    return self.scrolls[0..self.scrolls_len];
}

pub fn row(self: *const Grid, r: u32) []const Cell {
    return self.cells[r * self.width ..][0..self.width];
}

/// Applies a `redraw` notification's params. True if it ended a frame
/// with `flush`, so it's time to draw.
pub fn applyRedraw(self: *Grid, gpa: Allocator, params: *msgpack.Decoder) !bool {
    var flushed = false;
    // [[name, args, args, ...], ...]
    const events = try rpc.expectArray(params);
    for (0..events) |_| {
        const len = try rpc.expectArray(params);
        if (len == 0) return error.BadMessage;
        const name = try rpc.expectStr(params);
        const event = std.meta.stringToEnum(Event, name);
        for (1..len) |_| {
            if (event) |e| {
                try self.apply(gpa, e, params);
                if (e == .flush) flushed = true;
            } else {
                try rpc.skip(params);
            }
        }
    }
    return flushed;
}

const Event = enum {
    grid_resize,
    grid_clear,
    grid_line,
    grid_scroll,
    grid_cursor_goto,
    hl_attr_define,
    default_colors_set,
    mode_info_set,
    mode_change,
    busy_start,
    busy_stop,
    flush,
};

/// One event's args tuple.
fn apply(self: *Grid, gpa: Allocator, event: Event, d: *msgpack.Decoder) !void {
    const len = try rpc.expectArray(d);
    const used: u32 = switch (event) {
        .grid_resize => used: {
            if (len < 3) return error.BadMessage;
            const grid = try expectInt(d, u32);
            const w = try expectInt(d, u32);
            const h = try expectInt(d, u32);
            if (grid == 1) try self.resize(gpa, w, h);
            break :used 3;
        },
        .grid_clear => used: {
            if (len < 1) return error.BadMessage;
            if (try expectInt(d, u32) == 1) self.clear();
            break :used 1;
        },
        .grid_line => used: {
            if (len < 4) return error.BadMessage;
            const grid = try expectInt(d, u32);
            const r = try expectInt(d, u32);
            const col = try expectInt(d, u32);
            if (grid == 1) {
                try self.line(d, r, col);
            } else {
                try rpc.skip(d);
            }
            break :used 4;
        },
        .grid_scroll => used: {
            if (len < 7) return error.BadMessage;
            const grid = try expectInt(d, u32);
            const top = try expectInt(d, u32);
            const bot = try expectInt(d, u32);
            const left = try expectInt(d, u32);
            const right = try expectInt(d, u32);
            const rows = try expectInt(d, i64);
            _ = try expectInt(d, i64); // cols, always 0
            if (grid == 1) try self.scroll(top, bot, left, right, rows);
            break :used 7;
        },
        .grid_cursor_goto => used: {
            if (len < 3) return error.BadMessage;
            const grid = try expectInt(d, u32);
            const r = try expectInt(d, u32);
            const c = try expectInt(d, u32);
            if (grid == 1) {
                self.cursor_row = r;
                self.cursor_col = c;
            }
            break :used 3;
        },
        .hl_attr_define => used: {
            if (len < 2) return error.BadMessage;
            const id = try expectInt(d, u32);
            const attr = try readAttr(d);
            if (id >= self.attrs.items.len) try self.attrs.appendNTimes(gpa, .{}, id + 1 - self.attrs.items.len);
            self.attrs.items[id] = attr;
            break :used 2;
        },
        .default_colors_set => used: {
            if (len < 3) return error.BadMessage;
            self.default_fg = try expectColor(d);
            self.default_bg = try expectColor(d);
            self.default_sp = try expectColor(d);
            break :used 3;
        },
        .mode_info_set => used: {
            if (len < 2) return error.BadMessage;
            self.cursor_style_enabled = try expectBool(d);
            const n = try rpc.expectArray(d);
            self.cursor_modes.clearRetainingCapacity();
            for (0..n) |_| try self.cursor_modes.append(gpa, try readCursorMode(d));
            break :used 2;
        },
        .mode_change => used: {
            if (len < 2) return error.BadMessage;
            try rpc.skip(d); // mode name
            self.mode_idx = try expectInt(d, u32);
            break :used 2;
        },
        .busy_start, .busy_stop => used: {
            self.busy = event == .busy_start;
            break :used 0;
        },
        .flush => 0,
    };
    for (used..len) |_| try rpc.skip(d);
}

/// New size; every cell blank, every row dirty.
pub fn resize(self: *Grid, gpa: Allocator, w: u32, h: u32) !void {
    const cells = try gpa.alloc(Cell, @as(usize, w) * h);
    gpa.free(self.cells);
    self.cells = cells;
    self.width = w;
    self.height = h;
    try self.dirty.resize(gpa, h, true);
    self.clear();
    self.cursor_row = @min(self.cursor_row, h -| 1);
    self.cursor_col = @min(self.cursor_col, w -| 1);
}

fn clear(self: *Grid) void {
    @memset(self.cells, .{});
    self.dirty.setAll();
    self.scrolls_len = 0;
}

/// `grid_line`'s cells: `[text, hl_id?, repeat?]`, from column `col`.
fn line(self: *Grid, d: *msgpack.Decoder, r: u32, col: u32) !void {
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
fn scroll(self: *Grid, top: u32, bot: u32, left: u32, right: u32, rows: i64) !void {
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

/// A `mode_info_set` entry. Only shape and blink are used.
fn readCursorMode(d: *msgpack.Decoder) !CursorMode {
    var m: CursorMode = .{};
    var blinkon: i64 = 0;
    var blinkoff: i64 = 0;
    const n = try expectMap(d);
    for (0..n) |_| {
        const key = try rpc.expectStr(d);
        if (std.mem.eql(u8, key, "cursor_shape")) {
            m.shape = std.meta.stringToEnum(CursorMode.Shape, try rpc.expectStr(d)) orelse .block;
        } else if (std.mem.eql(u8, key, "blinkon")) {
            blinkon = try rpc.expectInt(d);
        } else if (std.mem.eql(u8, key, "blinkoff")) {
            blinkoff = try rpc.expectInt(d);
        } else {
            try rpc.skip(d);
        }
    }
    // as Neovim's TUI decides
    m.blink = blinkon != 0 and blinkoff != 0;
    return m;
}

/// An `rgb_attr` map. Unknown keys, such as `url`, are skipped.
fn readAttr(d: *msgpack.Decoder) !Attr {
    var a: Attr = .{};
    const n = try expectMap(d);
    for (0..n) |_| {
        const key = std.meta.stringToEnum(AttrKey, try rpc.expectStr(d)) orelse {
            try rpc.skip(d);
            continue;
        };
        switch (key) {
            .foreground => a.fg = try expectColor(d),
            .background => a.bg = try expectColor(d),
            .special => a.sp = try expectColor(d),
            .blend => a.blend = std.math.cast(u8, try rpc.expectInt(d)) orelse return error.BadMessage,
            .bold => a.bold = try expectBool(d),
            .italic => a.italic = try expectBool(d),
            .reverse => a.reverse = try expectBool(d),
            .strikethrough => a.strikethrough = try expectBool(d),
            .dim => a.dim = try expectBool(d),
            .blink => a.blink = try expectBool(d),
            .conceal => a.conceal = try expectBool(d),
            .overline => a.overline = try expectBool(d),
            .altfont => a.altfont = try expectBool(d),
            .underline => if (try expectBool(d)) {
                a.underline = .single;
            },
            .undercurl => if (try expectBool(d)) {
                a.underline = .curl;
            },
            .underdouble => if (try expectBool(d)) {
                a.underline = .double;
            },
            .underdotted => if (try expectBool(d)) {
                a.underline = .dotted;
            },
            .underdashed => if (try expectBool(d)) {
                a.underline = .dashed;
            },
        }
    }
    // cterm_attr and info: only RGB is used
    return a;
}

const AttrKey = enum {
    foreground,
    background,
    special,
    blend,
    bold,
    italic,
    reverse,
    strikethrough,
    dim,
    blink,
    conceal,
    overline,
    altfont,
    underline,
    undercurl,
    underdouble,
    underdotted,
    underdashed,
};

fn expectInt(d: *msgpack.Decoder, comptime T: type) !T {
    return std.math.cast(T, try rpc.expectInt(d)) orelse error.BadMessage;
}

/// An RGB color, or null for -1 (unset).
fn expectColor(d: *msgpack.Decoder) !?u24 {
    const n = try rpc.expectInt(d);
    if (n == -1) return null;
    return std.math.cast(u24, n) orelse error.BadMessage;
}

fn expectBool(d: *msgpack.Decoder) !bool {
    return switch ((try d.next()) orelse return error.BadMessage) {
        .bool => |b| b,
        else => error.BadMessage,
    };
}

fn expectMap(d: *msgpack.Decoder) !u32 {
    return switch ((try d.next()) orelse return error.BadMessage) {
        .map => |n| n,
        else => error.BadMessage,
    };
}

const testing = std.testing;
const Writer = std.Io.Writer;

/// Row `r` as text, wide-char halves dropped.
fn rowText(g: *const Grid, r: u32, buf: []u8) []const u8 {
    var w: Writer = .fixed(buf);
    for (g.row(r)) |c| w.writeAll(c.str()) catch break;
    return w.buffered();
}

/// Builds redraw params from events written by `f`, then applies them.
fn applyTest(g: *Grid, comptime f: fn (*Writer) anyerror!void) !bool {
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try f(&w);
    var d: msgpack.Decoder = .{};
    d.feed(w.buffered());
    return g.applyRedraw(testing.allocator, &d);
}

fn ints(w: *Writer, values: []const i64) !void {
    try msgpack.writeArrayHeader(w, @intCast(values.len));
    for (values) |v| try msgpack.writeInt(w, v);
}

test "resize, line, cursor and flush" {
    var g: Grid = .{};
    defer g.deinit(testing.allocator);
    const flushed = try applyTest(&g, struct {
        fn f(w: *Writer) !void {
            try msgpack.writeArrayHeader(w, 4);
            // ["grid_resize", [1, 6, 2]]
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "grid_resize");
            try ints(w, &.{ 1, 6, 2 });
            // ["grid_line", [1, 0, 0, [["h", 3], ["e"], ["l", 3, 2], ["o", 4]], false]]
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "grid_line");
            try msgpack.writeArrayHeader(w, 5);
            try msgpack.writeInt(w, 1);
            try msgpack.writeInt(w, 0);
            try msgpack.writeInt(w, 0);
            try msgpack.writeArrayHeader(w, 4);
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "h");
            try msgpack.writeInt(w, 3);
            try msgpack.writeArrayHeader(w, 1);
            try msgpack.writeStr(w, "e");
            try msgpack.writeArrayHeader(w, 3);
            try msgpack.writeStr(w, "l");
            try msgpack.writeInt(w, 3);
            try msgpack.writeInt(w, 2);
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "o");
            try msgpack.writeInt(w, 4);
            try msgpack.writeBool(w, false);
            // ["grid_cursor_goto", [1, 1, 2]]
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "grid_cursor_goto");
            try ints(w, &.{ 1, 1, 2 });
            // ["flush", []]
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "flush");
            try msgpack.writeArrayHeader(w, 0);
        }
    }.f);
    try testing.expect(flushed);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello ", rowText(&g, 0, &buf));
    try testing.expectEqualStrings("      ", rowText(&g, 1, &buf));
    // "e" carries "h"'s hl; the untouched last cell keeps 0
    const hls = [_]u32{ 3, 3, 3, 3, 4, 0 };
    for (g.row(0), hls) |c, hl| try testing.expectEqual(hl, c.hl);
    try testing.expectEqual(@as(u32, 1), g.cursor_row);
    try testing.expectEqual(@as(u32, 2), g.cursor_col);
    try testing.expect(g.dirty.isSet(0) and g.dirty.isSet(1));
}

test "wide chars and long clusters" {
    var g: Grid = .{};
    defer g.deinit(testing.allocator);
    _ = try applyTest(&g, struct {
        fn f(w: *Writer) !void {
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "grid_resize");
            try ints(w, &.{ 1, 4, 1 });
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "grid_line");
            try msgpack.writeArrayHeader(w, 5);
            try msgpack.writeInt(w, 1);
            try msgpack.writeInt(w, 0);
            try msgpack.writeInt(w, 0);
            try msgpack.writeArrayHeader(w, 3);
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "界");
            try msgpack.writeInt(w, 0);
            try msgpack.writeArrayHeader(w, 1);
            try msgpack.writeStr(w, "");
            try msgpack.writeArrayHeader(w, 1);
            const long: [Cell.max_text + 2]u8 = @splat('x');
            try msgpack.writeStr(w, &long);
            try msgpack.writeBool(w, false);
        }
    }.f);
    try testing.expectEqualStrings("界", g.row(0)[0].str());
    try testing.expectEqualStrings("", g.row(0)[1].str());
    try testing.expectEqualStrings("\u{fffd}", g.row(0)[2].str());
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

test "hl_attr_define and default colors" {
    var g: Grid = .{};
    defer g.deinit(testing.allocator);
    _ = try applyTest(&g, struct {
        fn f(w: *Writer) !void {
            try msgpack.writeArrayHeader(w, 2);
            // ["default_colors_set", [0xffffff, 0x000000, -1, 0, 0]]
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "default_colors_set");
            try ints(w, &.{ 0xffffff, 0, -1, 0, 0 });
            // ["hl_attr_define", [5, {fg, bold, undercurl, url}, {}, []]]
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "hl_attr_define");
            try msgpack.writeArrayHeader(w, 4);
            try msgpack.writeInt(w, 5);
            try msgpack.writeMapHeader(w, 4);
            try msgpack.writeStr(w, "foreground");
            try msgpack.writeInt(w, 0x112233);
            try msgpack.writeStr(w, "bold");
            try msgpack.writeBool(w, true);
            try msgpack.writeStr(w, "undercurl");
            try msgpack.writeBool(w, true);
            try msgpack.writeStr(w, "url");
            try msgpack.writeStr(w, "https://neovim.io");
            try msgpack.writeMapHeader(w, 0);
            try msgpack.writeArrayHeader(w, 0);
        }
    }.f);
    try testing.expectEqual(@as(?u24, 0xffffff), g.default_fg);
    try testing.expectEqual(@as(?u24, null), g.default_sp);
    const a = g.attrs.items[5];
    try testing.expectEqual(@as(?u24, 0x112233), a.fg);
    try testing.expectEqual(@as(?u24, null), a.bg);
    try testing.expect(a.bold and !a.italic);
    try testing.expectEqual(Attr.Underline.curl, a.underline);
    try testing.expectEqual(@as(usize, 6), g.attrs.items.len);
}

test "cursor modes and busy" {
    var g: Grid = .{};
    defer g.deinit(testing.allocator);
    _ = try applyTest(&g, struct {
        fn f(w: *Writer) !void {
            try msgpack.writeArrayHeader(w, 3);
            // ["mode_info_set", [true, [{cursor_shape: "block"}, {cursor_shape: "vertical", blinkon: 500, blinkoff: 500, name: "insert"}]]]
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "mode_info_set");
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeBool(w, true);
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeMapHeader(w, 1);
            try msgpack.writeStr(w, "cursor_shape");
            try msgpack.writeStr(w, "block");
            try msgpack.writeMapHeader(w, 4);
            try msgpack.writeStr(w, "cursor_shape");
            try msgpack.writeStr(w, "vertical");
            try msgpack.writeStr(w, "blinkon");
            try msgpack.writeInt(w, 500);
            try msgpack.writeStr(w, "blinkoff");
            try msgpack.writeInt(w, 500);
            try msgpack.writeStr(w, "name");
            try msgpack.writeStr(w, "insert");
            // ["mode_change", ["insert", 1]]
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "mode_change");
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "insert");
            try msgpack.writeInt(w, 1);
            // ["busy_start", []]
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "busy_start");
            try msgpack.writeArrayHeader(w, 0);
        }
    }.f);
    try testing.expectEqual(@as(?CursorMode, .{ .shape = .vertical, .blink = true }), g.cursorMode());
    try testing.expect(g.busy);
    g.mode_idx = 0;
    try testing.expectEqual(@as(?CursorMode, .{}), g.cursorMode());
    g.cursor_style_enabled = false;
    try testing.expectEqual(@as(?CursorMode, null), g.cursorMode());
}

test "unknown events are skipped" {
    var g: Grid = .{};
    defer g.deinit(testing.allocator);
    const flushed = try applyTest(&g, struct {
        fn f(w: *Writer) !void {
            // ["option_set", [...], [...]]
            try msgpack.writeArrayHeader(w, 1);
            try msgpack.writeArrayHeader(w, 3);
            try msgpack.writeStr(w, "option_set");
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "emoji");
            try msgpack.writeBool(w, true);
            try msgpack.writeArrayHeader(w, 2);
            try msgpack.writeStr(w, "linespace");
            try msgpack.writeInt(w, 0);
        }
    }.f);
    try testing.expect(!flushed);
}

test "neovim draws into the grid" {
    const Nvim = @import("../nvim/Nvim.zig");
    const gpa = testing.allocator;
    var buf: [256]u8 = undefined;
    var nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed" }, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer nvim.deinit(gpa);

    _ = try nvim.request("nvim_ui_attach", 3);
    try msgpack.writeInt(nvim.writer(), 20);
    try msgpack.writeInt(nvim.writer(), 5);
    try msgpack.writeMapHeader(nvim.writer(), 1);
    try msgpack.writeStr(nvim.writer(), "ext_linegrid");
    try msgpack.writeBool(nvim.writer(), true);
    _ = try nvim.request("nvim_input", 1);
    try msgpack.writeStr(nvim.writer(), "ihello<Esc>");
    try nvim.flush();

    var g: Grid = .{};
    defer g.deinit(gpa);
    var text: [64]u8 = undefined;
    var reads: usize = 0;
    while (true) : (reads += 1) {
        if (reads > 100) return error.TestTimedOut;
        var fds = [_]std.c.pollfd{.{ .fd = nvim.readFd(), .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 2000) <= 0) return error.TestTimedOut;
        if (!try nvim.read(gpa)) return error.NvimExited;
        while (try nvim.next()) |msg| switch (msg) {
            .notification => |n| if (std.mem.eql(u8, n.method, "redraw")) {
                var params = n.params;
                if (try g.applyRedraw(gpa, &params) and
                    std.mem.startsWith(u8, rowText(&g, 0, &text), "hello")) break;
            },
            else => {},
        } else continue;
        break;
    }
    try testing.expectEqual(@as(u32, 20), g.width);
    try testing.expectEqual(@as(u32, 5), g.height);
    try testing.expectEqualStrings("hello               ", rowText(&g, 0, &text));
    try testing.expectEqualStrings("~                   ", rowText(&g, 1, &text));
    // normal mode puts the cursor back on the "o"
    try testing.expectEqual(@as(u32, 0), g.cursor_row);
    try testing.expectEqual(@as(u32, 4), g.cursor_col);
}
