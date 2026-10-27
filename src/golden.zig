//! Golden tests: the renderer's output, fed to Ghostty's terminal emulator,
//! must produce the screen the `Grid` describes.

const std = @import("std");
const vt = @import("ghostty-vt");
const Grid = @import("Grid.zig");
const render = @import("render.zig");
const msgpack = @import("msgpack.zig");
const Nvim = @import("Nvim.zig");

const testing = std.testing;
const gpa = testing.allocator;

/// How a cell looks, from either side.
const Look = struct {
    fg: ?u24 = null,
    bg: ?u24 = null,
    ul_color: ?u24 = null,
    underline: u3 = 0,
    bold: bool = false,
    italic: bool = false,
    dim: bool = false,
    blink: bool = false,
    reverse: bool = false,
    conceal: bool = false,
    strikethrough: bool = false,
    overline: bool = false,

    /// A blank has no glyph, so only what draws without one counts.
    fn blank(self: Look) Look {
        return .{
            .fg = if (self.reverse) self.fg else null,
            .bg = self.bg,
            .reverse = self.reverse,
            .underline = self.underline,
            .ul_color = self.ul_color,
            .strikethrough = self.strikethrough,
            .overline = self.overline,
        };
    }
};

fn gridLook(g: *const Grid, hl: u32) Look {
    const a: Grid.Attr = if (hl < g.attrs.items.len) g.attrs.items[hl] else .{};
    const underline: u3 = switch (a.underline) {
        .none => 0,
        .single => 1,
        .double => 2,
        .curl => 3,
        .dotted => 4,
        .dashed => 5,
    };
    return .{
        .fg = a.fg orelse g.default_fg,
        .bg = a.bg orelse g.default_bg,
        .ul_color = if (underline != 0) a.sp orelse g.default_sp else null,
        .underline = underline,
        .bold = a.bold,
        .italic = a.italic,
        .dim = a.dim,
        .blink = a.blink,
        .reverse = a.reverse,
        .conceal = a.conceal,
        .strikethrough = a.strikethrough,
        .overline = a.overline,
    };
}

fn termLook(pc: anytype) !Look {
    const s = pc.style();
    const underline: u3 = @intCast(@intFromEnum(s.flags.underline));
    // EL leaves blanks that carry only a background
    const bg = if (pc.cell.content_tag == .bg_color_rgb) rgb(pc.cell.content.color_rgb) else try color(s.bg_color);
    return .{
        .fg = try color(s.fg_color),
        .bg = bg,
        .ul_color = if (underline != 0) try color(s.underline_color) else null,
        .underline = underline,
        .bold = s.flags.bold,
        .italic = s.flags.italic,
        .dim = s.flags.faint,
        .blink = s.flags.blink,
        .reverse = s.flags.inverse,
        .conceal = s.flags.invisible,
        .strikethrough = s.flags.strikethrough,
        .overline = s.flags.overline,
    };
}

fn color(c: anytype) !?u24 {
    return switch (c) {
        .none => null,
        .rgb => |v| rgb(v),
        // the renderer only sends RGB
        .palette => error.PaletteColor,
    };
}

fn rgb(v: anytype) u24 {
    return @as(u24, v.r) << 16 | @as(u24, v.g) << 8 | v.b;
}

/// Fails if Ghostty's screen differs from the grid anywhere.
fn expectScreen(t: *vt.Terminal, g: *const Grid) !void {
    const screen = t.screens.active;
    for (0..g.height) |r| for (0..g.width) |c| {
        const cell = g.row(@intCast(r))[c];
        const pc = screen.pages.getCell(.{ .active = .{ .x = @intCast(c), .y = @intCast(r) } }) orelse return error.NoCell;
        expectCell(pc, g, cell) catch |err| {
            std.debug.print("golden: cell {d},{d} ({s}): {t}\n", .{ r, c, cell.str(), err });
            try dump(t, g);
            return err;
        };
    };
    if (screen.cursor.y != g.cursor_row or screen.cursor.x != g.cursor_col) {
        std.debug.print("golden: cursor at {d},{d}, want {d},{d}\n", .{ screen.cursor.y, screen.cursor.x, g.cursor_row, g.cursor_col });
        return error.CursorMismatch;
    }
    if (t.modes.get(.cursor_visible) == g.busy) return error.CursorVisibility;
    if (g.cursorMode()) |m| {
        const want: @TypeOf(screen.cursor.cursor_style) = switch (m.shape) {
            .block => .block,
            .horizontal => .underline,
            .vertical => .bar,
        };
        if (screen.cursor.cursor_style != want) return error.CursorShape;
        if (t.modes.get(.cursor_blinking) != m.blink) return error.CursorBlink;
    }
}

fn expectCell(pc: anytype, g: *const Grid, cell: Grid.Cell) !void {
    if (cell.len == 0) {
        if (pc.cell.wide != .spacer_tail) return error.WantSpacer;
        return;
    }
    if (pc.cell.wide == .spacer_tail) return error.UnwantedSpacer;

    // text: Ghostty keeps a cluster's first codepoint in the cell
    var want: [Grid.Cell.max_text]u21 = undefined;
    var n: usize = 0;
    var it = (try std.unicode.Utf8View.init(cell.str())).iterator();
    while (it.nextCodepoint()) |cp| : (n += 1) want[n] = cp;
    var got: [Grid.Cell.max_text]u21 = undefined;
    var m: usize = 1;
    got[0] = pc.cell.codepoint();
    if (got[0] == 0) got[0] = ' ';
    if (pc.cell.hasGrapheme()) if (pc.node.page().lookupGrapheme(pc.cell)) |rest| {
        @memcpy(got[1..][0..rest.len], rest);
        m += rest.len;
    };
    if (!std.mem.eql(u21, want[0..n], got[0..m])) return error.TextMismatch;

    var expected = gridLook(g, cell.hl);
    var actual = try termLook(pc);
    if (n == 1 and want[0] == ' ') {
        expected = expected.blank();
        actual = actual.blank();
    }
    if (!std.meta.eql(expected, actual)) {
        std.debug.print("want {any}\n got {any}\n", .{ expected, actual });
        return error.LookMismatch;
    }
}

fn dump(t: *vt.Terminal, g: *const Grid) !void {
    const s = try t.plainString(gpa);
    defer gpa.free(s);
    std.debug.print("ghostty:\n{s}\ngrid:\n", .{s});
    for (0..g.height) |r| {
        for (g.row(@intCast(r))) |c| std.debug.print("{s}", .{c.str()});
        std.debug.print("\n", .{});
    }
}

/// Renders a frame of `g` into `t`, then checks them against each other.
fn check(t: *vt.Terminal, g: *Grid) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try render.frame(g, &out.writer);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(out.written());
    try expectScreen(t, g);
}

fn testTerminal(cols: u16, rows: u16) !vt.Terminal {
    return .init(testing.io, gpa, .{ .cols = cols, .rows = rows });
}

test "styles, wide chars and blanks" {
    var t = try testTerminal(8, 3);
    defer t.deinit(gpa);
    var g: Grid = .{ .default_fg = 0xeeeeee, .default_bg = 0x111111 };
    defer g.deinit(gpa);
    try g.resize(gpa, 8, 3);
    try g.attrs.appendSlice(gpa, &.{
        .{},
        .{ .bold = true, .fg = 0xff0000 },
        .{ .bg = 0x0000ff },
        .{ .reverse = true },
        .{ .underline = .curl, .sp = 0x00ff00, .italic = true },
        .{ .strikethrough = true, .overline = true, .dim = true },
    });
    const text = [_]struct { []const u8, u32 }{
        .{ "h", 1 }, .{ "i", 1 }, .{ "界", 0 }, .{ "", 0 }, .{ "u", 4 }, .{ "s", 5 }, .{ " ", 2 }, .{ " ", 2 },
    };
    for (text, 0..) |c, i| g.cells[i] = .init(c[0], c[1]);
    // a reverse line, as cursorline can make
    g.cells[8] = .init("x", 3);
    for (g.cells[9..16]) |*c| c.* = .init(" ", 3);
    for (g.cells[16..24]) |*c| c.* = .init(" ", 4);
    g.cursor_row = 1;
    g.cursor_col = 1;
    try check(&t, &g);

    // a second frame redraws only what changed
    g.cells[0] = .init("H", 0);
    g.dirty.set(0);
    try check(&t, &g);
}

/// Steps of keys for the live test. Each runs once the last has settled.
const steps = [_][]const u8{
    ":set number cursorline<CR>",
    ":call setline(1, map(range(1, 200), '\"line \" . v:val . \" foo 界 bar\"'))<CR>",
    "<C-e>",
    "<C-e><C-e>",
    "<C-y>",
    "<C-d>",
    "<C-u>",
    "G",
    "gg",
    "30j",
    ":hi CursorLine gui=reverse<CR>",
    "<C-e>",
    ":hi Error gui=undercurl,bold guisp=red<CR>:call matchadd('Error', 'foo')<CR>",
    "vjj",
    "<Esc>",
    ":vsplit<CR>",
    "<C-e><C-e>",
    "<C-w>l<C-d>",
    ":split<CR>",
    "<C-y>",
    ":only<CR>",
    ":set nonumber<CR>",
    "ohello",
    "<Esc>",
    "dd",
};

test "live neovim session" {
    const cols = 40;
    const rows = 12;
    var buf: [256]u8 = undefined;
    var nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer nvim.deinit(gpa);
    try nvim.uiAttach(cols, rows, .{});

    var t = try testTerminal(cols, rows);
    defer t.deinit(gpa);
    var g: Grid = .{};
    defer g.deinit(gpa);

    var stats: Stats = .{};
    try settle(&nvim, &t, &g, &stats);
    for (steps) |keys| {
        _ = try nvim.request("nvim_input", 1);
        try msgpack.writeStr(nvim.writer(), keys);
        try nvim.flush();
        settle(&nvim, &t, &g, &stats) catch |err| {
            std.debug.print("golden: after step {s}\n", .{keys});
            return err;
        };
    }
    try testing.expect(stats.frames > steps.len);
    try testing.expect(stats.scrolls > 0);
    try testing.expect(stats.bar_cursor > 0);
}

const Stats = struct { frames: usize = 0, scrolls: usize = 0, bar_cursor: usize = 0 };

/// Applies redraws until Neovim goes quiet, checking every frame.
fn settle(nvim: *Nvim, t: *vt.Terminal, g: *Grid, stats: *Stats) !void {
    while (true) {
        var fds = [_]std.c.pollfd{.{ .fd = nvim.readFd(), .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 150) <= 0) return;
        if (!try nvim.read(gpa)) return error.NvimExited;
        while (try nvim.next()) |msg| switch (msg) {
            .notification => |n| if (std.mem.eql(u8, n.method, "redraw")) {
                var params = n.params;
                if (try g.applyRedraw(gpa, &params)) {
                    stats.scrolls += g.pendingScrolls().len;
                    try check(t, g);
                    stats.frames += 1;
                    if (g.cursorMode()) |m| stats.bar_cursor += @intFromBool(m.shape == .vertical);
                }
            },
            .response => |r| if (r.err != null) return error.NvimError,
            .request => |r| try nvim.respondError(r.id, "golden test"),
        };
    }
}
