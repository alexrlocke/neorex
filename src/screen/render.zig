//! Draws a `Grid`'s dirty rows to a terminal as escape sequences.
//! Follows Neovim's own TUI (`tui_flush` in src/nvim/tui/tui.c): trailing
//! blanks are cleared with EL instead of printed, and scrolls are repeated
//! with a scroll region (DECSTBM) instead of redrawing every moved row.

const std = @import("std");
const Writer = std.Io.Writer;
const Grid = @import("Grid.zig");
const Style = @import("Style.zig");

pub const Cursor = struct { row: u32, col: u32 };

/// One frame of `grid` filling the terminal: the dirty rows, then the
/// cursor, inside synchronized output so the terminal shows it all at once.
/// Clears `grid.dirty`.
pub fn frame(grid: *Grid, style: *const Style, w: *Writer) Writer.Error!void {
    try begin(w);
    try replayScrolls(grid, w);
    var current: ?u32 = null;
    var it = grid.dirty.iterator(.{});
    while (it.next()) |r| try drawRow(grid.row(@intCast(r)), style, @intCast(r), grid.width, w, &current);
    grid.dirty.unsetAll();
    try end(style, .{ .row = grid.cursor_row, .col = grid.cursor_col }, w);
}

/// Starts a frame: synchronized output on, cursor hidden while drawing.
pub fn begin(w: *Writer) Writer.Error!void {
    try w.writeAll("\x1b[?2026h\x1b[?25l");
}

/// Repeats the grid's pending scrolls with scroll regions, then forgets them.
/// The grid must sit at the terminal's top left.
pub fn replayScrolls(grid: *Grid, w: *Writer) Writer.Error!void {
    const scrolls = grid.pendingScrolls();
    if (scrolls.len == 0) return;
    // SU and SD fill with the current background
    try w.writeAll("\x1b[0m");
    for (scrolls) |s| {
        try w.print("\x1b[{d};{d}r", .{ s.top + 1, s.bot });
        if (s.rows > 0) {
            try w.print("\x1b[{d}S", .{s.rows});
        } else {
            try w.print("\x1b[{d}T", .{-s.rows});
        }
    }
    try w.writeAll("\x1b[r");
    grid.scrolls_len = 0;
}

/// Ends a frame: the cursor where it belongs, or left hidden if null.
pub fn end(style: *const Style, cursor: ?Cursor, w: *Writer) Writer.Error!void {
    if (cursor) |c| {
        if (style.cursorMode()) |m| try writeCursorStyle(m, w);
        try w.print("\x1b[0m\x1b[{d};{d}H", .{ c.row + 1, c.col + 1 });
        if (!style.busy) try w.writeAll("\x1b[?25h");
    } else {
        try w.writeAll("\x1b[0m");
    }
    try w.writeAll("\x1b[?2026l");
}

/// DECSCUSR: 1 block, 3 underline, 5 bar; one more for steady.
fn writeCursorStyle(m: Style.CursorMode, w: *Writer) Writer.Error!void {
    const shape: u8 = switch (m.shape) {
        .block => 1,
        .horizontal => 3,
        .vertical => 5,
    };
    try w.print("\x1b[{d} q", .{shape + @intFromBool(!m.blink)});
}

/// Draws `row` at terminal row `r`, cut at `cols` columns. `current` is the
/// SGR the terminal has, null if unknown.
pub fn drawRow(row: []const Grid.Cell, style: *const Style, r: u32, cols: u32, w: *Writer, current: *?u32) Writer.Error!void {
    const cells = row[0..@min(row.len, cols)];
    try w.print("\x1b[{d};1H", .{r + 1});
    if (cells.len == 0) return clearToEnd(style, w, current);

    // trailing blanks in the last cell's highlight are cleared, not printed
    const clear_hl = cells[cells.len - 1].hl;
    var clear_col = cells.len;
    if (canClear(style, clear_hl)) {
        while (clear_col > 0 and isBlank(cells[clear_col - 1], clear_hl)) clear_col -= 1;
    }

    for (cells[0..clear_col], 0..) |*cell, c| {
        // the right half of a wide char: the terminal already moved past it
        if (cell.len == 0) continue;
        try setHl(style, cell.hl, w, current);
        // a wide char cut in half at the edge would wrap
        const cut = c + 1 == cells.len and cells.len < row.len and row[c + 1].len == 0;
        try w.writeAll(if (cut) " " else cell.str());
    }
    if (clear_col < cells.len) {
        // EL fills with the current background
        try setHl(style, clear_hl, w, current);
        try w.writeAll("\x1b[K");
    } else if (cells.len < cols) {
        // past a grid narrower than the terminal
        try clearToEnd(style, w, current);
    }
}

/// Blanks terminal row `r` in the default colors.
pub fn clearRow(style: *const Style, r: u32, w: *Writer, current: *?u32) Writer.Error!void {
    try w.print("\x1b[{d};1H", .{r + 1});
    try clearToEnd(style, w, current);
}

fn clearToEnd(style: *const Style, w: *Writer, current: *?u32) Writer.Error!void {
    try setHl(style, 0, w, current);
    try w.writeAll("\x1b[K");
}

/// EL keeps only the background, so nothing else may show on a blank.
fn canClear(style: *const Style, hl: u32) bool {
    const a = style.attr(hl);
    return !a.reverse and !a.strikethrough and !a.overline and a.underline == .none;
}

fn isBlank(cell: Grid.Cell, hl: u32) bool {
    return cell.hl == hl and std.mem.eql(u8, cell.str(), " ");
}

pub fn setHl(style: *const Style, hl: u32, w: *Writer, current: *?u32) Writer.Error!void {
    if (current.* == hl) return;
    current.* = hl;
    try writeSgr(style.attr(hl), style, w);
}

/// One SGR sequence that resets, then sets everything in `attr`. Colors an
/// `attr` leaves null use the style's defaults; if those are null too, the
/// terminal's own (from ext_termcolors).
pub fn writeSgr(attr: Style.Attr, style: *const Style, w: *Writer) Writer.Error!void {
    try w.writeAll("\x1b[0");
    if (attr.bold) try w.writeAll(";1");
    if (attr.dim) try w.writeAll(";2");
    if (attr.italic) try w.writeAll(";3");
    if (attr.blink) try w.writeAll(";5");
    if (attr.reverse) try w.writeAll(";7");
    if (attr.conceal) try w.writeAll(";8");
    if (attr.strikethrough) try w.writeAll(";9");
    if (attr.overline) try w.writeAll(";53");
    try w.writeAll(switch (attr.underline) {
        .none => "",
        .single => ";4",
        .double => ";4:2",
        .curl => ";4:3",
        .dotted => ";4:4",
        .dashed => ";4:5",
    });
    try writeColor(w, 38, attr.fg orelse style.default_fg);
    try writeColor(w, 48, attr.bg orelse style.default_bg);
    if (attr.underline != .none) try writeColor(w, 58, attr.sp orelse style.default_sp);
    try w.writeByte('m');
}

/// `;38;2;r;g;b` and friends; nothing for null, which the reset covers.
fn writeColor(w: *Writer, prefix: u8, color: ?u24) Writer.Error!void {
    const c = color orelse return;
    try w.print(";{d};2;{d};{d};{d}", .{ prefix, c >> 16, (c >> 8) & 0xff, c & 0xff });
}

const testing = std.testing;

/// A grid and the style it's drawn with.
const Fixture = struct {
    g: Grid = .{},
    s: Style = .{},

    fn init(w: u32, h: u32) !Fixture {
        var f: Fixture = .{};
        try f.g.resize(testing.allocator, w, h);
        try f.s.attrs.appendNTimes(testing.allocator, .{}, 3);
        f.s.attrs.items[1] = .{ .bold = true, .fg = 0xff0000 };
        f.s.attrs.items[2] = .{ .bg = 0x0000ff };
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.g.deinit(testing.allocator);
        f.s.deinit(testing.allocator);
    }

    fn expectFrame(f: *Fixture, expected: []const u8) !void {
        var buf: [512]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try frame(&f.g, &f.s, &w);
        try testing.expectEqualStrings(expected, w.buffered());
    }
};

const begin_s = "\x1b[?2026h\x1b[?25l";
const end_s = "\x1b[?25h\x1b[?2026l";

test "blank rows are just cleared" {
    var f = try Fixture.init(4, 2);
    defer f.deinit();
    try f.expectFrame(begin_s ++ "\x1b[1;1H\x1b[0m\x1b[K" ++ "\x1b[2;1H\x1b[K" ++ "\x1b[0m\x1b[1;1H" ++ end_s);
    try testing.expectEqual(@as(usize, 0), f.g.dirty.count());
}

test "only dirty rows, styles change once, cursor last" {
    var f = try Fixture.init(5, 3);
    defer f.deinit();
    const g = &f.g;
    g.dirty.unsetAll();
    const row = g.cells[5..10];
    row[0] = .init("h", 1);
    row[1] = .init("i", 1);
    row[2] = .init("!", 0);
    g.dirty.set(1);
    g.cursor_row = 1;
    g.cursor_col = 3;
    try f.expectFrame(begin_s ++
        "\x1b[2;1H" ++ "\x1b[0;1;38;2;255;0;0mhi" ++ "\x1b[0m!" ++ "\x1b[K" ++
        "\x1b[0m\x1b[2;4H" ++ end_s);
}

test "colored trailing blanks keep their background" {
    var f = try Fixture.init(4, 1);
    defer f.deinit();
    f.g.cells[0] = .init("x", 0);
    for (f.g.cells[1..]) |*c| c.* = .init(" ", 2);
    try f.expectFrame(begin_s ++
        "\x1b[1;1H\x1b[0mx" ++ "\x1b[0;48;2;0;0;255m\x1b[K" ++
        "\x1b[0m\x1b[1;1H" ++ end_s);
}

test "wide chars skip their right half" {
    var f = try Fixture.init(4, 1);
    defer f.deinit();
    f.g.cells[0] = .init("界", 0);
    f.g.cells[1] = .init("", 0);
    f.g.cells[2] = .init("a", 0);
    try f.expectFrame(begin_s ++ "\x1b[1;1H\x1b[0m界a\x1b[K" ++ "\x1b[0m\x1b[1;1H" ++ end_s);
}

test "scrolls go first, inside a scroll region" {
    var f = try Fixture.init(2, 4);
    defer f.deinit();
    const g = &f.g;
    g.dirty.unsetAll();
    g.scrolls[0] = .{ .top = 1, .bot = 4, .rows = 2 };
    g.scrolls[1] = .{ .top = 0, .bot = 4, .rows = -1 };
    g.scrolls_len = 2;
    try f.expectFrame(begin_s ++
        "\x1b[0m\x1b[2;4r\x1b[2S\x1b[1;4r\x1b[1T\x1b[r" ++
        "\x1b[0m\x1b[1;1H" ++ end_s);
    try testing.expectEqual(@as(usize, 0), g.pendingScrolls().len);
}

test "cursor style, and busy hides the cursor" {
    var f = try Fixture.init(2, 1);
    defer f.deinit();
    f.g.dirty.unsetAll();
    try f.s.cursor_modes.append(testing.allocator, .{ .shape = .vertical, .blink = true });
    f.s.cursor_style_enabled = true;
    f.s.busy = true;
    try f.expectFrame(begin_s ++ "\x1b[5 q\x1b[0m\x1b[1;1H\x1b[?2026l");
}

test "rows are cut at the terminal's width; past a narrow grid is cleared" {
    var f = try Fixture.init(4, 1);
    defer f.deinit();
    for ("ab", 0..) |c, i| f.g.cells[i] = .init(&.{c}, 1);
    f.g.cells[2] = .init("界", 1);
    f.g.cells[3] = .init("", 1);
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var current: ?u32 = null;
    // the wide char would straddle the edge, so a blank stands in
    try drawRow(f.g.row(0), &f.s, 0, 3, &w, &current);
    try testing.expectEqualStrings("\x1b[1;1H\x1b[0;1;38;2;255;0;0mab ", w.buffered());
    w.end = 0;
    try drawRow(f.g.row(0), &f.s, 0, 6, &w, &current);
    try testing.expectEqualStrings("\x1b[1;1Hab界\x1b[0m\x1b[K", w.buffered());
}

test "sgr uses defaults for null colors" {
    var s: Style = .{ .default_fg = 0x010203 };
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeSgr(.{ .italic = true, .underline = .curl, .sp = 0x00ff00 }, &s, &w);
    try testing.expectEqualStrings("\x1b[0;3;4:3;38;2;1;2;3;58;2;0;255;0m", w.buffered());
}
