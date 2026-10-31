//! Every grid Neovim draws, built from its redraw events. With ext_multigrid
//! each window has its own grid; grid 1 holds what's left (statuslines of
//! split windows, the tabline). Also tracks where windows and the message
//! grid are.

const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("../nvim/msgpack.zig");
const rpc = @import("../nvim/rpc.zig");
const Grid = @import("Grid.zig");
const Style = @import("Style.zig");

const Grids = @This();

grids: std.AutoArrayHashMapUnmanaged(u32, Grid) = .empty,
/// Windows by grid id.
wins: std.AutoArrayHashMapUnmanaged(u32, Win) = .empty,
style: Style = .{},
/// The grid the cursor is on.
cursor_grid: u32 = 1,
/// The message grid, drawn over grid 1 from `msg_row` down.
msg_grid: ?u32 = null,
msg_row: u32 = 0,

pub const Win = struct {
    /// Neovim's window handle; -1 for the popup menu.
    win: i64,
    kind: Kind,
    /// Where it floats, for `.float`.
    float: Float = .{},

    pub const Kind = enum {
        /// In the tab's split layout, positioned on grid 1.
        ordinary,
        /// Outside the layout, for the UI to place.
        external,
        /// Floating over another grid, such as the popup menu.
        float,
        /// An ordinary window on another tab page.
        hidden,
    };
};

/// A float's position, as `win_float_pos` gives it.
pub const Float = struct {
    /// The grid it floats over, and the corner of the float at `row`, `col`.
    anchor_grid: u32 = 1,
    anchor: Anchor = .nw,
    row: f64 = 0,
    col: f64 = 0,
    zindex: u32 = 50,
    /// Takes the mouse; Neovim sets this for focusable floats.
    focusable: bool = true,
    /// Neovim's drawing order among equal zindexes.
    compindex: u32 = 0,
    /// Where Neovim put it on grid 1, kept inside the screen.
    screen: ?[2]i32 = null,

    pub const Anchor = enum { nw, ne, sw, se };
};

/// A float placed over a base grid, in that grid's cells.
pub const Placed = struct {
    grid: u32,
    row: i32,
    col: i32,
    zindex: u32,
    compindex: u32,
    /// On the screen (grid 1 or the message grid), not over a window.
    on_screen: bool = false,
    /// On the message grid, which shows at the bottom.
    on_msg: bool = false,
    /// The editor-relative float it hangs from, itself included; 0 if none.
    top: u32 = 0,
};

/// Where a float sits on the grid under it all.
pub const Place = struct { root: u32, row: i32, col: i32, top: u32 };

/// Most floats drawn over one pane.
pub const max_floats = 16;

pub fn deinit(self: *Grids, gpa: Allocator) void {
    for (self.grids.values()) |*g| g.deinit(gpa);
    self.grids.deinit(gpa);
    self.wins.deinit(gpa);
    self.style.deinit(gpa);
    self.* = undefined;
}

/// Grid `id`, if it exists. Valid until the next `applyRedraw`.
pub fn get(self: *const Grids, id: u32) ?*Grid {
    return self.grids.getPtr(id);
}

/// The grid showing window `win`.
pub fn gridOf(self: *const Grids, win: i64) ?u32 {
    for (self.wins.keys(), self.wins.values()) |grid, w| if (w.win == win) return grid;
    return null;
}

/// The window on `grid`.
pub fn winOn(self: *const Grids, grid: u32) ?Win {
    return self.wins.get(grid);
}

/// The floats over grid `base`, and over the screen too if `screen`
/// (floats on grid 1 and the message grid), lowest first. Floats hanging
/// from an editor float in `skip` are left out.
pub fn floatsOver(self: *const Grids, base: u32, screen: bool, skip: []const u32, out: *[max_floats]Placed) []Placed {
    var n: usize = 0;
    for (self.wins.keys(), self.wins.values()) |id, w| {
        if (w.kind != .float or n == out.len) continue;
        const p = self.place(id) orelse continue;
        if (p.top != 0 and std.mem.indexOfScalar(u32, skip, p.top) != null) continue;
        const on_screen = p.root == 1 or p.root == self.msg_grid;
        if (p.root != base and !(screen and on_screen)) continue;
        out[n] = .{ .grid = id, .row = p.row, .col = p.col, .zindex = w.float.zindex, .compindex = w.float.compindex, .on_screen = on_screen, .on_msg = p.root == self.msg_grid, .top = p.top };
        n += 1;
    }
    const placed = out[0..n];
    sortPlaced(placed);
    return placed;
}

/// Lowest first, as Neovim stacks them.
pub fn sortPlaced(placed: []Placed) void {
    std.mem.sort(Placed, placed, {}, struct {
        fn lt(_: void, a: Placed, b: Placed) bool {
            return if (a.zindex != b.zindex) a.zindex < b.zindex else a.compindex < b.compindex;
        }
    }.lt);
}

/// Where float grid `id` sits on the grid under it all: floats can float over floats.
pub fn place(self: *const Grids, id: u32) ?Place {
    const w = self.wins.get(id) orelse return null;
    if (w.kind != .float) return null;
    var row: i32 = 0;
    var col: i32 = 0;
    var grid = id;
    var float = w.float;
    var top: u32 = 0;
    for (0..8) |_| {
        const g = self.get(grid) orelse return null;
        if (float.anchor_grid == 1) {
            top = grid;
            if (float.screen) |pos| return .{ .root = 1, .row = row + pos[0], .col = col + pos[1], .top = top };
        }
        row += @as(i32, @intFromFloat(@floor(float.row))) - if (float.anchor == .sw or float.anchor == .se) @as(i32, @intCast(g.height)) else 0;
        col += @as(i32, @intFromFloat(@floor(float.col))) - if (float.anchor == .ne or float.anchor == .se) @as(i32, @intCast(g.width)) else 0;
        grid = float.anchor_grid;
        const under = self.wins.get(grid) orelse {
            // the message grid sits on grid 1 at msg_row
            if (grid == self.msg_grid) return .{ .root = grid, .row = row + @as(i32, @intCast(self.msg_row)), .col = col, .top = top };
            return .{ .root = grid, .row = row, .col = col, .top = top };
        };
        if (under.kind != .float) return .{ .root = grid, .row = row, .col = col, .top = top };
        float = under.float;
    }
    return null;
}

/// Rows the message grid covers at the bottom of grid 1: the command
/// line, or more while a long message scrolls up.
pub fn msgRows(self: *const Grids) u32 {
    const id = self.msg_grid orelse return 0;
    const screen = self.get(1) orelse return 0;
    const msg = self.get(id) orelse return 0;
    return @min(screen.height -| self.msg_row, msg.height);
}

/// Applies a `redraw` notification's params. True if it ended a frame
/// with `flush`, so it's time to draw.
pub fn applyRedraw(self: *Grids, gpa: Allocator, params: *msgpack.Decoder) !bool {
    var flushed = false;
    // [[name, args, args, ...], ...]
    const events = try rpc.expectArray(params);
    for (0..events) |_| {
        const len = try rpc.expectArray(params);
        if (len == 0) return error.BadMessage;
        const name = try rpc.expectStr(params);
        const event = std.meta.stringToEnum(Event, name);
        for (1..len) |_| {
            const e = event orelse {
                try rpc.skip(params);
                continue;
            };
            const n = try rpc.expectArray(params);
            const used = try self.apply(gpa, e, params, n);
            for (used..n) |_| try rpc.skip(params);
            if (e == .flush) flushed = true;
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
    grid_destroy,
    win_pos,
    win_external_pos,
    win_float_pos,
    win_hide,
    win_close,
    msg_set_pos,
    hl_attr_define,
    default_colors_set,
    mode_info_set,
    mode_change,
    busy_start,
    busy_stop,
    flush,
};

/// One event's args, after their array header of `len`. Returns how many
/// args it read.
fn apply(self: *Grids, gpa: Allocator, event: Event, d: *msgpack.Decoder, len: u32) !u32 {
    switch (event) {
        .grid_resize => {
            if (len < 3) return error.BadMessage;
            const id = try expectInt(d, u32);
            const w = try expectInt(d, u32);
            const h = try expectInt(d, u32);
            const entry = try self.grids.getOrPut(gpa, id);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            try entry.value_ptr.resize(gpa, w, h);
            return 3;
        },
        .grid_clear => {
            if (len < 1) return error.BadMessage;
            if (self.get(try expectInt(d, u32))) |g| g.clear();
            return 1;
        },
        .grid_line => {
            if (len < 4) return error.BadMessage;
            const g = self.get(try expectInt(d, u32));
            const r = try expectInt(d, u32);
            const col = try expectInt(d, u32);
            if (g) |grid| try grid.line(d, r, col) else try rpc.skip(d);
            return 4;
        },
        .grid_scroll => {
            if (len < 7) return error.BadMessage;
            const g = self.get(try expectInt(d, u32));
            const top = try expectInt(d, u32);
            const bot = try expectInt(d, u32);
            const left = try expectInt(d, u32);
            const right = try expectInt(d, u32);
            const rows = try expectInt(d, i64);
            _ = try expectInt(d, i64); // cols, always 0
            if (g) |grid| try grid.scroll(top, bot, left, right, rows);
            return 7;
        },
        .grid_cursor_goto => {
            if (len < 3) return error.BadMessage;
            const id = try expectInt(d, u32);
            const r = try expectInt(d, u32);
            const c = try expectInt(d, u32);
            self.cursor_grid = id;
            if (self.get(id)) |g| {
                g.cursor_row = r;
                g.cursor_col = c;
            }
            return 3;
        },
        .grid_destroy => {
            if (len < 1) return error.BadMessage;
            const id = try expectInt(d, u32);
            if (self.grids.fetchSwapRemove(id)) |kv| {
                var g = kv.value;
                g.deinit(gpa);
            }
            _ = self.wins.swapRemove(id);
            return 1;
        },
        .win_pos, .win_external_pos, .win_float_pos => {
            if (len < 2) return error.BadMessage;
            const id = try expectInt(d, u32);
            const win = try rpc.expectHandle(d);
            const kind: Win.Kind = switch (event) {
                .win_pos => .ordinary,
                .win_external_pos => .external,
                else => .float,
            };
            if (event != .win_float_pos) {
                try self.wins.put(gpa, id, .{ .win = win, .kind = kind });
                return 2;
            }
            if (len < 8) return error.BadMessage;
            var f: Float = .{};
            f.anchor = std.meta.stringToEnum(Float.Anchor, &lower2(try rpc.expectStr(d))) orelse .nw;
            f.anchor_grid = try expectInt(d, u32);
            f.row = try expectNumber(d);
            f.col = try expectNumber(d);
            f.focusable = try rpc.expectBool(d);
            f.zindex = try expectInt(d, u32);
            if (len < 11) {
                try self.wins.put(gpa, id, .{ .win = win, .kind = kind, .float = f });
                return 8;
            }
            f.compindex = try expectInt(d, u32);
            f.screen = .{ try expectInt(d, i32), try expectInt(d, i32) };
            try self.wins.put(gpa, id, .{ .win = win, .kind = kind, .float = f });
            return 11;
        },
        .win_hide => {
            if (len < 1) return error.BadMessage;
            if (self.wins.getPtr(try expectInt(d, u32))) |w| w.kind = .hidden;
            return 1;
        },
        .win_close => {
            if (len < 1) return error.BadMessage;
            _ = self.wins.swapRemove(try expectInt(d, u32));
            return 1;
        },
        .msg_set_pos => {
            if (len < 2) return error.BadMessage;
            self.msg_grid = try expectInt(d, u32);
            self.msg_row = try expectInt(d, u32);
            return 2;
        },
        .hl_attr_define, .default_colors_set, .mode_info_set, .mode_change, .busy_start, .busy_stop => {
            const e = std.meta.stringToEnum(Style.Event, @tagName(event)).?;
            return self.style.apply(gpa, e, d, len);
        },
        .flush => return 0,
    }
}

/// "NW" as "nw"; anything else as "??".
fn lower2(s: []const u8) [2]u8 {
    if (s.len != 2) return "??".*;
    return .{ std.ascii.toLower(s[0]), std.ascii.toLower(s[1]) };
}

/// A float or an int, as Neovim sends positions.
fn expectNumber(d: *msgpack.Decoder) !f64 {
    return switch (try d.next() orelse return error.BadMessage) {
        .float => |f| f,
        .int => |n| @floatFromInt(n),
        .uint => |n| @floatFromInt(n),
        else => error.BadMessage,
    };
}

fn expectInt(d: *msgpack.Decoder, comptime T: type) !T {
    return std.math.cast(T, try rpc.expectInt(d)) orelse error.BadMessage;
}

const testing = std.testing;
const Writer = std.Io.Writer;
const rowText = Grid.rowText;

/// Builds redraw params from events written by `f`, then applies them.
fn applyTest(gs: *Grids, comptime f: fn (*Writer) anyerror!void) !bool {
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try f(&w);
    var d: msgpack.Decoder = .{};
    d.feed(w.buffered());
    return gs.applyRedraw(testing.allocator, &d);
}

fn ints(w: *Writer, values: []const i64) !void {
    try msgpack.writeArrayHeader(w, @intCast(values.len));
    for (values) |v| try msgpack.writeInt(w, v);
}

/// `[name, [args...]]` with int args.
fn ev(w: *Writer, name: []const u8, args: []const i64) !void {
    try msgpack.writeArrayHeader(w, 2);
    try msgpack.writeStr(w, name);
    try ints(w, args);
}

/// `[name, [grid, window handle]]`, the handle as Neovim's ext 1.
fn winEvent(w: *Writer, name: []const u8, grid: i64, win: u16) !void {
    try msgpack.writeArrayHeader(w, 2);
    try msgpack.writeStr(w, name);
    try msgpack.writeArrayHeader(w, 2);
    try msgpack.writeInt(w, grid);
    try w.writeAll(&.{ 0xc7, 0x03, 0x01, 0xcd, @intCast(win >> 8), @truncate(win) });
}

/// `["grid_line", [grid, row, col, [[text, 0]], false]]`
fn lineEvent(w: *Writer, grid: i64, r: i64, col: i64, text: []const u8) !void {
    try msgpack.writeArrayHeader(w, 2);
    try msgpack.writeStr(w, "grid_line");
    try msgpack.writeArrayHeader(w, 5);
    try msgpack.writeInt(w, grid);
    try msgpack.writeInt(w, r);
    try msgpack.writeInt(w, col);
    try msgpack.writeArrayHeader(w, 1);
    try msgpack.writeArrayHeader(w, 2);
    try msgpack.writeStr(w, text);
    try msgpack.writeInt(w, 0);
    try msgpack.writeBool(w, false);
}

test "events go to their grids; windows are tracked" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    const flushed = try applyTest(&gs, struct {
        fn f(w: *Writer) !void {
            try msgpack.writeArrayHeader(w, 10);
            try ev(w, "grid_resize", &.{ 1, 4, 3 });
            try ev(w, "grid_resize", &.{ 2, 3, 2 });
            try ev(w, "grid_resize", &.{ 4, 4, 3 });
            try lineEvent(w, 2, 1, 0, "x");
            try lineEvent(w, 4, 0, 1, "m");
            try winEvent(w, "win_external_pos", 2, 1000);
            try winEvent(w, "win_pos", 3, 1001);
            try ev(w, "msg_set_pos", &.{ 4, 2 });
            try ev(w, "grid_cursor_goto", &.{ 2, 1, 2 });
            try ev(w, "flush", &.{});
        }
    }.f);
    try testing.expect(flushed);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("   ", rowText(gs.get(2).?, 0, &buf));
    try testing.expectEqualStrings("x  ", rowText(gs.get(2).?, 1, &buf));
    try testing.expectEqualStrings("    ", rowText(gs.get(1).?, 1, &buf));
    try testing.expectEqualStrings(" m  ", rowText(gs.get(4).?, 0, &buf));
    try testing.expectEqual(@as(?u32, 2), gs.gridOf(1000));
    try testing.expectEqual(Win.Kind.external, gs.winOn(2).?.kind);
    try testing.expectEqual(Win.Kind.ordinary, gs.winOn(3).?.kind);
    try testing.expectEqual(@as(u32, 2), gs.cursor_grid);
    try testing.expectEqual(@as(u32, 1), gs.get(2).?.cursor_row);
    // grid 1 is 3 rows; messages from row 2 down
    try testing.expectEqual(@as(u32, 1), gs.msgRows());

    _ = try applyTest(&gs, struct {
        fn f(w: *Writer) !void {
            try msgpack.writeArrayHeader(w, 4);
            try ev(w, "win_hide", &.{3});
            try ev(w, "win_close", &.{2});
            try ev(w, "grid_destroy", &.{2});
            // a line for a grid that's gone is skipped
            try lineEvent(w, 2, 0, 0, "y");
        }
    }.f);
    try testing.expectEqual(@as(?*Grid, null), gs.get(2));
    try testing.expectEqual(@as(?u32, null), gs.gridOf(1000));
    try testing.expectEqual(Win.Kind.hidden, gs.winOn(3).?.kind);
}

test "resize, line, cursor and flush" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    const flushed = try applyTest(&gs, struct {
        fn f(w: *Writer) !void {
            try msgpack.writeArrayHeader(w, 4);
            // ["grid_resize", [1, 6, 2]]
            try ev(w, "grid_resize", &.{ 1, 6, 2 });
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
            try ev(w, "grid_cursor_goto", &.{ 1, 1, 2 });
            try ev(w, "flush", &.{});
        }
    }.f);
    try testing.expect(flushed);
    const g = gs.get(1).?;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello ", rowText(g, 0, &buf));
    try testing.expectEqualStrings("      ", rowText(g, 1, &buf));
    // "e" carries "h"'s hl; the untouched last cell keeps 0
    const hls = [_]u32{ 3, 3, 3, 3, 4, 0 };
    for (g.row(0), hls) |c, hl| try testing.expectEqual(hl, c.hl);
    try testing.expectEqual(@as(u32, 1), g.cursor_row);
    try testing.expectEqual(@as(u32, 2), g.cursor_col);
    try testing.expect(g.dirty.isSet(0) and g.dirty.isSet(1));
}

test "wide chars and long clusters" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    _ = try applyTest(&gs, struct {
        fn f(w: *Writer) !void {
            try msgpack.writeArrayHeader(w, 2);
            try ev(w, "grid_resize", &.{ 1, 4, 1 });
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
            const long: [Grid.Cell.max_text + 2]u8 = @splat('x');
            try msgpack.writeStr(w, &long);
            try msgpack.writeBool(w, false);
        }
    }.f);
    const g = gs.get(1).?;
    try testing.expectEqualStrings("界", g.row(0)[0].str());
    try testing.expectEqualStrings("", g.row(0)[1].str());
    try testing.expectEqualStrings("\u{fffd}", g.row(0)[2].str());
}

test "hl_attr_define and default colors" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    _ = try applyTest(&gs, struct {
        fn f(w: *Writer) !void {
            try msgpack.writeArrayHeader(w, 2);
            // ["default_colors_set", [0xffffff, 0x000000, -1, 0, 0]]
            try ev(w, "default_colors_set", &.{ 0xffffff, 0, -1, 0, 0 });
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
    const s = &gs.style;
    try testing.expectEqual(@as(?u24, 0xffffff), s.default_fg);
    try testing.expectEqual(@as(?u24, null), s.default_sp);
    const a = s.attrs.items[5];
    try testing.expectEqual(@as(?u24, 0x112233), a.fg);
    try testing.expectEqual(@as(?u24, null), a.bg);
    try testing.expect(a.bold and !a.italic);
    try testing.expectEqual(Style.Attr.Underline.curl, a.underline);
    try testing.expectEqual(@as(usize, 6), s.attrs.items.len);
}

test "cursor modes and busy" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    _ = try applyTest(&gs, struct {
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
            try ev(w, "busy_start", &.{});
        }
    }.f);
    const s = &gs.style;
    try testing.expectEqual(@as(?Style.CursorMode, .{ .shape = .vertical, .blink = true }), s.cursorMode());
    try testing.expect(s.busy);
    s.mode_idx = 0;
    try testing.expectEqual(@as(?Style.CursorMode, .{}), s.cursorMode());
    s.cursor_style_enabled = false;
    try testing.expectEqual(@as(?Style.CursorMode, null), s.cursorMode());
}

test "unknown events are skipped" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    const flushed = try applyTest(&gs, struct {
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

/// Applies Neovim's redraws until `done` holds after a flush.
fn pumpUntil(nvim: anytype, gs: *Grids, comptime done: fn (*Grids) bool) !void {
    const gpa = testing.allocator;
    for (0..100) |_| {
        var fds = [_]std.c.pollfd{.{ .fd = nvim.readFd(), .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 2000) <= 0) return error.TestTimedOut;
        if (!try nvim.read(gpa)) return error.NvimExited;
        while (try nvim.next()) |msg| switch (msg) {
            .notification => |n| if (std.mem.eql(u8, n.method, "redraw")) {
                var params = n.params;
                if (try gs.applyRedraw(gpa, &params) and done(gs)) return;
            },
            .response => |r| if (r.err) |e| {
                std.debug.print("neovim: {s}\n", .{e});
                return error.NvimError;
            },
            else => {},
        };
    }
    return error.TestTimedOut;
}

test "neovim draws windows into their own grids" {
    const Nvim = @import("../nvim/Nvim.zig");
    const gpa = testing.allocator;
    var buf: [512]u8 = undefined;
    var nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer nvim.deinit(gpa);
    try nvim.uiAttach(20, 6, .{ .ext_multigrid = true });
    _ = try nvim.request("nvim_input", 1);
    try msgpack.writeStr(nvim.writer(), "ihello<Esc>");
    try nvim.flush();

    var gs: Grids = .{};
    defer gs.deinit(gpa);
    try pumpUntil(&nvim, &gs, struct {
        fn f(g: *Grids) bool {
            const id = g.gridOf(1000) orelse return false;
            var b: [32]u8 = undefined;
            return std.mem.startsWith(u8, rowText(g.get(id).?, 0, &b), "hello");
        }
    }.f);
    const first = gs.gridOf(1000).?;
    try testing.expect(first != 1);
    try testing.expectEqual(Win.Kind.ordinary, gs.winOn(first).?.kind);
    try testing.expectEqual(first, gs.cursor_grid);
    try testing.expectEqual(@as(u32, 4), gs.get(first).?.cursor_col);

    // a split gets another grid; the first window, made external, keeps its own
    _ = try nvim.execLua(
        \\vim.cmd.split()
        \\vim.api.nvim_win_set_config(1000, { external = true, width = 12, height = 3 })
    , 0);
    try nvim.flush();
    try pumpUntil(&nvim, &gs, struct {
        fn f(g: *Grids) bool {
            const id = g.gridOf(1000) orelse return false;
            var b: [32]u8 = undefined;
            return g.winOn(id).?.kind == .external and g.get(id).?.width == 12 and g.gridOf(1001) != null and
                std.mem.startsWith(u8, rowText(g.get(id).?, 0, &b), "hello");
        }
    }.f);
    var text: [32]u8 = undefined;
    try testing.expectEqualStrings("hello       ", rowText(gs.get(gs.gridOf(1000).?).?, 0, &text));
    try testing.expectEqual(Win.Kind.ordinary, gs.winOn(gs.gridOf(1001).?).?.kind);
    try testing.expect(gs.msg_grid != null);
}

/// `["win_float_pos", [grid, win, anchor, anchor_grid, row, col, true, zindex, compindex, screen_row, screen_col]]`
fn floatEvent(w: *Writer, grid: i64, anchor: []const u8, anchor_grid: i64, row: f64, col: f64, zindex: i64, screen: ?[2]i64) !void {
    try msgpack.writeArrayHeader(w, 2);
    try msgpack.writeStr(w, "win_float_pos");
    try msgpack.writeArrayHeader(w, if (screen != null) 11 else 8);
    try msgpack.writeInt(w, grid);
    try w.writeAll(&.{ 0xc7, 0x03, 0x01, 0xcd, 0x03, 0xf0 });
    try msgpack.writeStr(w, anchor);
    try msgpack.writeInt(w, anchor_grid);
    try msgpack.writeFloat(w, row);
    try msgpack.writeFloat(w, col);
    try msgpack.writeBool(w, true);
    try msgpack.writeInt(w, zindex);
    if (screen) |s| {
        try msgpack.writeInt(w, 0);
        try msgpack.writeInt(w, s[0]);
        try msgpack.writeInt(w, s[1]);
    }
}

test "floats are placed over the grid under them" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    _ = try applyTest(&gs, struct {
        fn f(w: *Writer) !void {
            try msgpack.writeArrayHeader(w, 9);
            try ev(w, "grid_resize", &.{ 2, 20, 10 });
            try winEvent(w, "win_external_pos", 2, 1000);
            try ev(w, "grid_resize", &.{ 3, 4, 2 });
            try ev(w, "grid_resize", &.{ 4, 3, 1 });
            try ev(w, "grid_resize", &.{ 5, 5, 2 });
            // its bottom right corner at 6.5, 10 of grid 2
            try floatEvent(w, 3, "SE", 2, 6.5, 10, 50, null);
            // over the float, so over grid 2 too; drawn above it
            try floatEvent(w, 4, "NW", 3, 1, 1, 40, .{ 0, 0 });
            // on the screen: where Neovim put it
            try floatEvent(w, 5, "NW", 1, 30, 30, 50, .{ 7, 2 });
            try ev(w, "flush", &.{});
        }
    }.f);
    var buf: [max_floats]Placed = undefined;
    const over = gs.floatsOver(2, false, &.{}, &buf);
    try testing.expectEqual(2, over.len);
    try testing.expectEqual(Placed{ .grid = 4, .row = 5, .col = 7, .zindex = 40, .compindex = 0 }, over[0]);
    try testing.expectEqual(Placed{ .grid = 3, .row = 4, .col = 6, .zindex = 50, .compindex = 0 }, over[1]);
    const all = gs.floatsOver(2, true, &.{}, &buf);
    try testing.expectEqual(3, all.len);
    try testing.expectEqual(Placed{ .grid = 5, .row = 7, .col = 2, .zindex = 50, .compindex = 0, .on_screen = true, .top = 5 }, all[2]);
    // left out with the editor float it hangs from
    try testing.expectEqual(2, gs.floatsOver(2, true, &.{5}, &buf).len);
}

test "floats over an editor float hang from it" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    _ = try applyTest(&gs, struct {
        fn f(w: *Writer) !void {
            try msgpack.writeArrayHeader(w, 6);
            try ev(w, "grid_resize", &.{ 3, 20, 8 });
            try ev(w, "grid_resize", &.{ 4, 10, 1 });
            try ev(w, "grid_resize", &.{ 5, 4, 2 });
            // a box on the screen, an input inside it, the pair on a third
            try floatEvent(w, 3, "NW", 1, 2, 5, 50, .{ 2, 5 });
            try floatEvent(w, 4, "NW", 3, 1, 1, 51, null);
            try floatEvent(w, 5, "NW", 4, 0, 2, 52, null);
        }
    }.f);
    try testing.expectEqual(Place{ .root = 1, .row = 2, .col = 5, .top = 3 }, gs.place(3).?);
    try testing.expectEqual(Place{ .root = 1, .row = 3, .col = 6, .top = 3 }, gs.place(4).?);
    try testing.expectEqual(Place{ .root = 1, .row = 3, .col = 8, .top = 3 }, gs.place(5).?);
    var buf: [max_floats]Placed = undefined;
    try testing.expectEqual(0, gs.floatsOver(1, true, &.{3}, &buf).len);
}
