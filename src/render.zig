//! Draws a `Grid`'s dirty rows to a terminal as escape sequences.
//! Follows Neovim's own TUI (`tui_flush` in src/nvim/tui/tui.c): trailing
//! blanks are cleared with EL instead of printed, and scrolls are repeated
//! with a scroll region (DECSTBM) instead of redrawing every moved row.

const std = @import("std");
const Writer = std.Io.Writer;
const Grid = @import("Grid.zig");

/// One frame: the dirty rows, then the cursor, inside synchronized output so
/// the terminal shows it all at once. Clears `grid.dirty`.
pub fn frame(grid: *Grid, w: *Writer) Writer.Error!void {
    try w.writeAll("\x1b[?2026h\x1b[?25l");
    // the SGR the terminal has now; null means unknown
    var current: ?u32 = null;

    const scrolls = grid.pendingScrolls();
    if (scrolls.len > 0) {
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

    var it = grid.dirty.iterator(.{});
    while (it.next()) |r| try drawRow(grid, @intCast(r), w, &current);
    grid.dirty.unsetAll();

    if (grid.cursorMode()) |m| try writeCursorStyle(m, w);
    try w.print("\x1b[0m\x1b[{d};{d}H", .{ grid.cursor_row + 1, grid.cursor_col + 1 });
    if (!grid.busy) try w.writeAll("\x1b[?25h");
    try w.writeAll("\x1b[?2026l");
}

/// DECSCUSR: 1 block, 3 underline, 5 bar; one more for steady.
fn writeCursorStyle(m: Grid.CursorMode, w: *Writer) Writer.Error!void {
    const shape: u8 = switch (m.shape) {
        .block => 1,
        .horizontal => 3,
        .vertical => 5,
    };
    try w.print("\x1b[{d} q", .{shape + @intFromBool(!m.blink)});
}

fn drawRow(grid: *const Grid, r: u32, w: *Writer, current: *?u32) Writer.Error!void {
    const cells = grid.row(r);
    if (cells.len == 0) return;

    // trailing blanks in the last cell's highlight are cleared, not printed
    const clear_hl = cells[cells.len - 1].hl;
    var clear_col = cells.len;
    if (canClear(grid, clear_hl)) {
        while (clear_col > 0 and isBlank(cells[clear_col - 1], clear_hl)) clear_col -= 1;
    }

    try w.print("\x1b[{d};1H", .{r + 1});
    for (cells[0..clear_col]) |*cell| {
        // the right half of a wide char: the terminal already moved past it
        if (cell.len == 0) continue;
        try setHl(grid, cell.hl, w, current);
        try w.writeAll(cell.str());
    }
    if (clear_col < cells.len) {
        // EL fills with the current background
        try setHl(grid, clear_hl, w, current);
        try w.writeAll("\x1b[K");
    }
}

/// EL keeps only the background, so nothing else may show on a blank.
fn canClear(grid: *const Grid, hl: u32) bool {
    const a: Grid.Attr = if (hl < grid.attrs.items.len) grid.attrs.items[hl] else .{};
    return !a.reverse and !a.strikethrough and !a.overline and a.underline == .none;
}

fn isBlank(cell: Grid.Cell, hl: u32) bool {
    return cell.hl == hl and std.mem.eql(u8, cell.str(), " ");
}

fn setHl(grid: *const Grid, hl: u32, w: *Writer, current: *?u32) Writer.Error!void {
    if (current.* == hl) return;
    current.* = hl;
    const attr: Grid.Attr = if (hl < grid.attrs.items.len) grid.attrs.items[hl] else .{};
    try writeSgr(attr, grid, w);
}

/// One SGR sequence that resets, then sets everything in `attr`. Colors an
/// `attr` leaves null use the grid's defaults; if those are null too, the
/// terminal's own (from ext_termcolors).
pub fn writeSgr(attr: Grid.Attr, grid: *const Grid, w: *Writer) Writer.Error!void {
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
    try writeColor(w, 38, attr.fg orelse grid.default_fg);
    try writeColor(w, 48, attr.bg orelse grid.default_bg);
    if (attr.underline != .none) try writeColor(w, 58, attr.sp orelse grid.default_sp);
    try w.writeByte('m');
}

/// `;38;2;r;g;b` and friends; nothing for null, which the reset covers.
fn writeColor(w: *Writer, prefix: u8, color: ?u24) Writer.Error!void {
    const c = color orelse return;
    try w.print(";{d};2;{d};{d};{d}", .{ prefix, c >> 16, (c >> 8) & 0xff, c & 0xff });
}

const testing = std.testing;

fn testGrid(w: u32, h: u32) !Grid {
    var g: Grid = .{};
    try g.resize(testing.allocator, w, h);
    try g.attrs.appendNTimes(testing.allocator, .{}, 3);
    g.attrs.items[1] = .{ .bold = true, .fg = 0xff0000 };
    g.attrs.items[2] = .{ .bg = 0x0000ff };
    return g;
}

fn expectFrame(g: *Grid, expected: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try frame(g, &w);
    try testing.expectEqualStrings(expected, w.buffered());
}

const begin = "\x1b[?2026h\x1b[?25l";
const end = "\x1b[?25h\x1b[?2026l";

test "blank rows are just cleared" {
    var g = try testGrid(4, 2);
    defer g.deinit(testing.allocator);
    try expectFrame(&g, begin ++ "\x1b[1;1H\x1b[0m\x1b[K" ++ "\x1b[2;1H\x1b[K" ++ "\x1b[0m\x1b[1;1H" ++ end);
    try testing.expectEqual(@as(usize, 0), g.dirty.count());
}

test "only dirty rows, styles change once, cursor last" {
    var g = try testGrid(5, 3);
    defer g.deinit(testing.allocator);
    g.dirty.unsetAll();
    const row = g.cells[5..10];
    row[0] = .init("h", 1);
    row[1] = .init("i", 1);
    row[2] = .init("!", 0);
    g.dirty.set(1);
    g.cursor_row = 1;
    g.cursor_col = 3;
    try expectFrame(&g, begin ++
        "\x1b[2;1H" ++ "\x1b[0;1;38;2;255;0;0mhi" ++ "\x1b[0m!" ++ "\x1b[K" ++
        "\x1b[0m\x1b[2;4H" ++ end);
}

test "colored trailing blanks keep their background" {
    var g = try testGrid(4, 1);
    defer g.deinit(testing.allocator);
    g.cells[0] = .init("x", 0);
    for (g.cells[1..]) |*c| c.* = .init(" ", 2);
    try expectFrame(&g, begin ++
        "\x1b[1;1H\x1b[0mx" ++ "\x1b[0;48;2;0;0;255m\x1b[K" ++
        "\x1b[0m\x1b[1;1H" ++ end);
}

test "wide chars skip their right half" {
    var g = try testGrid(4, 1);
    defer g.deinit(testing.allocator);
    g.cells[0] = .init("界", 0);
    g.cells[1] = .init("", 0);
    g.cells[2] = .init("a", 0);
    try expectFrame(&g, begin ++ "\x1b[1;1H\x1b[0m界a\x1b[K" ++ "\x1b[0m\x1b[1;1H" ++ end);
}

test "scrolls go first, inside a scroll region" {
    var g = try testGrid(2, 4);
    defer g.deinit(testing.allocator);
    g.dirty.unsetAll();
    g.scrolls[0] = .{ .top = 1, .bot = 4, .rows = 2 };
    g.scrolls[1] = .{ .top = 0, .bot = 4, .rows = -1 };
    g.scrolls_len = 2;
    try expectFrame(&g, begin ++
        "\x1b[0m\x1b[2;4r\x1b[2S\x1b[1;4r\x1b[1T\x1b[r" ++
        "\x1b[0m\x1b[1;1H" ++ end);
    try testing.expectEqual(@as(usize, 0), g.pendingScrolls().len);
}

test "cursor style, and busy hides the cursor" {
    var g = try testGrid(2, 1);
    defer g.deinit(testing.allocator);
    g.dirty.unsetAll();
    try g.cursor_modes.append(testing.allocator, .{ .shape = .vertical, .blink = true });
    g.cursor_style_enabled = true;
    g.busy = true;
    try expectFrame(&g, begin ++ "\x1b[5 q\x1b[0m\x1b[1;1H\x1b[?2026l");
}

test "sgr uses defaults for null colors" {
    var g: Grid = .{ .default_fg = 0x010203 };
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeSgr(.{ .italic = true, .underline = .curl, .sp = 0x00ff00 }, &g, &w);
    try testing.expectEqualStrings("\x1b[0;3;4:3;38;2;1;2;3;58;2;0;255;0m", w.buffered());
}
