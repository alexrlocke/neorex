//! Golden tests: the renderer's output, fed to Ghostty's terminal emulator,
//! must produce the screen the `Grid` describes.

const std = @import("std");
const vt = @import("ghostty-vt");
const Grid = @import("screen/Grid.zig");
const Grids = @import("screen/Grids.zig");
const Style = @import("screen/Style.zig");
const render = @import("screen/render.zig");
const msgpack = @import("nvim/msgpack.zig");
const Nvim = @import("nvim/Nvim.zig");

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

fn gridLook(g: *const Style, hl: u32) Look {
    const a = g.attr(hl);
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
    const underline: u3 = @intCast(@backingInt(s.flags.underline));
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

/// Fails if Ghostty's screen differs from the grid anywhere, or the cursor
/// isn't on the grid's.
fn expectScreen(t: *vt.Terminal, g: *const Grid, style: *const Style) !void {
    try expectRows(t, g, style, 0, 0, g.height, g.width);
    try expectCursor(t, style, .{ .row = g.cursor_row, .col = g.cursor_col });
}

/// Grid rows `first..first + n`, cut at `cols`, must show at terminal rows
/// from `top`.
fn expectRows(t: *vt.Terminal, g: *const Grid, style: *const Style, first: u32, top: u32, n: u32, cols: u32) !void {
    const screen = t.screens.active;
    for (0..n) |i| for (0..@min(g.width, cols)) |c| {
        const r: u32 = @intCast(first + i);
        const cell = g.row(r)[c];
        const pc = screen.pages.getCell(.{ .active = .{ .x = @intCast(c), .y = @intCast(top + i) } }) orelse return error.NoCell;
        // a wide char cut at the edge is drawn as a blank
        const cut = c + 1 == cols and c + 1 < g.width and g.row(r)[c + 1].len == 0;
        expectCell(pc, style, if (cut) .init(" ", cell.hl) else cell) catch |err| {
            std.debug.print("golden: grid row {d} col {d} ({s}) at terminal row {d}: {t}\n", .{ r, c, cell.str(), top + i, err });
            try dump(t, g);
            return err;
        };
    };
}

/// The cursor must be at `want` and showing, or hidden if null.
fn expectCursor(t: *vt.Terminal, style: *const Style, want: ?render.Cursor) !void {
    const screen = t.screens.active;
    const c = want orelse {
        if (t.modes.get(.cursor_visible)) return error.CursorVisibility;
        return;
    };
    if (screen.cursor.y != c.row or screen.cursor.x != c.col) {
        std.debug.print("golden: cursor at {d},{d}, want {d},{d}\n", .{ screen.cursor.y, screen.cursor.x, c.row, c.col });
        return error.CursorMismatch;
    }
    if (t.modes.get(.cursor_visible) == style.busy) return error.CursorVisibility;
    if (style.cursorMode()) |m| {
        const shape: @TypeOf(screen.cursor.cursor_style) = switch (m.shape) {
            .block => .block,
            .horizontal => .underline,
            .vertical => .bar,
        };
        if (screen.cursor.cursor_style != shape) return error.CursorShape;
        if (t.modes.get(.cursor_blinking) != m.blink) return error.CursorBlink;
    }
}

fn expectCell(pc: anytype, style: *const Style, cell: Grid.Cell) !void {
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

    var expected = gridLook(style, cell.hl);
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
fn check(t: *vt.Terminal, g: *Grid, style: *const Style) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try render.frame(g, style, &out.writer);
    feed(t, out.written());
    try expectScreen(t, g, style);
}

fn feed(t: *vt.Terminal, bytes: []const u8) void {
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
}

fn testTerminal(cols: u16, rows: u16) !vt.Terminal {
    return .init(testing.io, gpa, .{ .cols = cols, .rows = rows });
}

test "styles, wide chars and blanks" {
    var t = try testTerminal(8, 3);
    defer t.deinit(gpa);
    var style: Style = .{ .default_fg = 0xeeeeee, .default_bg = 0x111111 };
    defer style.deinit(gpa);
    var g: Grid = .{};
    defer g.deinit(gpa);
    try g.resize(gpa, 8, 3);
    try style.attrs.appendSlice(gpa, &.{
        .{},
        .{ .bold = true, .fg = 0xff0000 },
        .{ .bg = 0x0000ff },
        .{ .reverse = true },
        .{ .underline = .curl, .sp = 0x00ff00, .italic = true },
        .{ .strikethrough = true, .overline = true, .dim = true },
    });
    const text = [_]struct { []const u8, u32 }{
        .{ "h", 1 }, .{ "i", 1 },
        .{ "界", 0 },
        .{ "", 0 },  .{ "u", 4 },
        .{ "s", 5 }, .{ " ", 2 },
        .{ " ", 2 },
    };
    for (text, 0..) |c, i| g.cells[i] = .init(c[0], c[1]);
    // a reverse line, as cursorline can make
    g.cells[8] = .init("x", 3);
    for (g.cells[9..16]) |*c| c.* = .init(" ", 3);
    for (g.cells[16..24]) |*c| c.* = .init(" ", 4);
    g.cursor_row = 1;
    g.cursor_col = 1;
    try check(&t, &g, &style);

    // a second frame redraws only what changed
    g.cells[0] = .init("H", 0);
    g.dirty.set(0);
    try check(&t, &g, &style);
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
    var gs: Grids = .{};
    defer gs.deinit(gpa);

    var stats: Stats = .{};
    try settle(&nvim, &t, &gs, &stats);
    for (steps) |keys| {
        _ = try nvim.request("nvim_input", 1);
        try msgpack.writeStr(nvim.writer(), keys);
        try nvim.flush();
        settle(&nvim, &t, &gs, &stats) catch |err| {
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
fn settle(nvim: *Nvim, t: *vt.Terminal, gs: *Grids, stats: *Stats) !void {
    while (true) {
        var fds = [_]std.c.pollfd{.{ .fd = nvim.readFd(), .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 150) <= 0) return;
        if (!try nvim.read(gpa)) return error.NvimExited;
        while (try nvim.next()) |msg| switch (msg) {
            .notification => |n| if (std.mem.eql(u8, n.method, "redraw")) {
                var params = n.params;
                if (try gs.applyRedraw(gpa, &params)) {
                    const g = gs.get(1) orelse continue;
                    stats.scrolls += g.pendingScrolls().len;
                    try check(t, g, &gs.style);
                    stats.frames += 1;
                    if (gs.style.cursorMode()) |m| stats.bar_cursor += @intFromBool(m.shape == .vertical);
                }
            },
            .response => |r| if (r.err != null) return error.NvimError,
            .request => |r| try nvim.respondError(r.id, "golden test"),
        };
    }
}

const PaneView = @import("screen/PaneView.zig");
const windows = @import("nvim/windows.zig");

/// A pane for the multigrid test: what it shows and Ghostty's screen of it.
const TestPane = struct {
    view: PaneView,
    t: vt.Terminal,
    win: i64 = 0,
};

/// Neovim with windows.lua, two panes, and the daemon's part played here.
const Multi = struct {
    nvim: Nvim,
    gs: Grids = .{},
    panes: [2]TestPane,
    current: i64 = 0,
    anchor: i64 = 0,
    chan_req: u32 = 0,
    setup_req: u32 = 0,
    stats: struct { frames: usize = 0, msg_rows: usize = 0, scrolls: usize = 0, cursors: [2]usize = .{ 0, 0 }, floats: usize = 0, float_cursor: usize = 0 } = .{},

    fn deinit(m: *Multi) void {
        for (&m.panes) |*p| p.t.deinit(gpa);
        m.gs.deinit(gpa);
        m.nvim.deinit(gpa);
    }

    fn input(m: *Multi, keys: []const u8) !void {
        _ = try m.nvim.request("nvim_input", 1);
        try msgpack.writeStr(m.nvim.writer(), keys);
        try m.nvim.flush();
    }

    /// Applies messages until Neovim goes quiet, checking every frame.
    fn settle(m: *Multi) !void {
        while (true) {
            var fds = [_]std.c.pollfd{.{ .fd = m.nvim.readFd(), .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 200) <= 0) return;
            if (!try m.nvim.read(gpa)) return error.NvimExited;
            while (try m.nvim.next()) |msg| switch (msg) {
                .notification => |n| {
                    var params = n.params;
                    if (std.mem.eql(u8, n.method, "redraw")) {
                        if (try m.gs.applyRedraw(gpa, &params)) try m.flushed();
                    } else if (try windows.parseNote(n.method, &params)) |note| switch (note) {
                        .current => |w| m.current = w,
                        .reopen, .split, .float => {},
                    };
                },
                .response => |r| {
                    if (r.err) |e| {
                        std.debug.print("neovim: {s}\n", .{e});
                        return error.NvimError;
                    }
                    var result = r.result;
                    if (r.id == m.chan_req) {
                        const v = m.panes[0].view;
                        m.setup_req = try windows.setup(&m.nvim, try windows.parseChannel(&result), v.cols, v.rows - 1);
                        try m.nvim.flush();
                    } else if (r.id == m.setup_req) {
                        const wins = try windows.parseSetup(&result);
                        m.panes[0].win = wins[0];
                        m.anchor = wins[1];
                    }
                },
                .request => |r| try m.nvim.respondError(r.id, "golden test"),
            };
        }
    }

    /// The daemon's part: adopt new windows into the free pane, then draw
    /// and check both panes.
    fn flushed(m: *Multi) !void {
        if (m.anchor == 0) return;
        for (m.gs.wins.values()) |w| if (w.kind == .ordinary and w.win != m.anchor and m.panes[1].win == 0) {
            const v = m.panes[1].view;
            try windows.adopt(&m.nvim, w.win, v.cols, v.rows - 1);
            try m.nvim.flush();
            m.panes[1].win = w.win;
        };
        for (&m.panes, 0..) |*p, i| try m.check(p, i);
        if (m.gs.msg_grid) |id| m.gs.get(id).?.dirty.unsetAll();
        for (m.gs.wins.keys(), m.gs.wins.values()) |id, w| if (w.kind == .float) if (m.gs.get(id)) |f| {
            f.dirty.unsetAll();
            f.scrolls_len = 0;
        };
        m.stats.frames += 1;
    }

    fn check(m: *Multi, p: *TestPane, i: usize) !void {
        const grid = if (p.win != 0) m.gs.gridOf(p.win) else null;
        const focused = p.win != 0 and p.win == m.current;
        if (grid) |id| m.stats.scrolls += m.gs.get(id).?.pendingScrolls().len;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try p.view.frame(&m.gs, grid, .{ .focused = focused }, &out.writer);
        feed(&p.t, out.written());

        const v = &p.view;
        const style = &m.gs.style;
        const msg_total = if (focused) m.gs.msgRows() else 0;
        const msg_n = @min(msg_total, v.rows);
        const msg_top = v.rows - msg_n;
        var grid_rows: u32 = 0;
        var placed_buf: [Grids.max_floats]Grids.Placed = undefined;
        var placed: []Grids.Placed = placed_buf[0..0];
        if (grid) |id| {
            const g = m.gs.get(id).?;
            grid_rows = @min(g.height, msg_top);
            placed = m.gs.floatsOver(id, focused, &.{}, &placed_buf);
            m.stats.floats += placed.len;
            var shown = try overlay(&m.gs, g, placed, grid_rows, v.cols);
            defer shown.deinit(gpa);
            try expectRows(&p.t, &shown, style, 0, 0, grid_rows, v.cols);
        }
        if (msg_n > 0) {
            try expectRows(&p.t, m.gs.get(m.gs.msg_grid.?).?, style, msg_total - msg_n, msg_top, msg_n, v.cols);
            m.stats.msg_rows += msg_n;
        } else {
            // the message line of a pane without focus stays blank
            try expectBlank(&p.t, v.rows - 1, v.cols);
        }

        // the cursor shows on its grid only, or on the messages of the focused pane
        var want: ?render.Cursor = null;
        if (grid) |id| if (m.gs.cursor_grid == id) {
            const g = m.gs.get(id).?;
            if (g.cursor_row < grid_rows) want = .{ .row = g.cursor_row, .col = g.cursor_col };
        };
        for (placed) |f| if (m.gs.cursor_grid == f.grid) {
            const fg = m.gs.get(f.grid).?;
            const row = f.row + @as(i32, @intCast(fg.cursor_row));
            const col = f.col + @as(i32, @intCast(fg.cursor_col));
            if (row >= 0 and row < grid_rows and col >= 0 and col < v.cols) {
                want = .{ .row = @intCast(row), .col = @intCast(col) };
                m.stats.float_cursor += 1;
            }
        };
        if (msg_n > 0 and m.gs.cursor_grid == m.gs.msg_grid.?) {
            const mg = m.gs.get(m.gs.msg_grid.?).?;
            want = .{ .row = msg_top + mg.cursor_row - (msg_total - msg_n), .col = mg.cursor_col };
        }
        if (want != null) m.stats.cursors[i] += 1;
        try expectCursor(&p.t, style, want);
    }
};

/// Grid `g` with `placed` floats laid over it, cell by cell, as wide as
/// the floats reach within `cols`.
fn overlay(gs: *const Grids, g: *const Grid, placed: []const Grids.Placed, rows: u32, cols: u32) !Grid {
    var width = g.width;
    for (placed) |f| width = @max(width, @as(u32, @intCast(std.math.clamp(f.col + @as(i32, @intCast(gs.get(f.grid).?.width)), 0, @as(i32, @intCast(cols))))));
    var out: Grid = .{};
    try out.resize(gpa, width, g.height);
    for (0..g.height) |r| @memcpy(out.cells[r * width ..][0..g.width], g.row(@intCast(r)));
    for (placed) |f| {
        const fg = gs.get(f.grid).?;
        for (0..fg.height) |fr| for (0..fg.width) |fc| {
            const r = f.row + @as(i32, @intCast(fr));
            const c = f.col + @as(i32, @intCast(fc));
            if (r < 0 or r >= rows or c < 0 or c >= width) continue;
            const line = out.cells[@as(usize, @intCast(r)) * width ..][0..width];
            const x: usize = @intCast(c);
            // half a wide char under the float's edge shows as a blank
            if (fc == 0 and x > 0 and line[x].len == 0) line[x - 1] = .{ .hl = line[x - 1].hl };
            line[x] = fg.row(@intCast(fr))[fc];
            if (fc == 0 and line[x].len == 0) line[x] = .{ .hl = line[x].hl };
            if (fc + 1 == fg.width and x + 1 < width and line[x + 1].len == 0) line[x + 1] = .{ .hl = line[x + 1].hl };
        };
    }
    return out;
}

fn expectBlank(t: *vt.Terminal, row: u32, cols: u32) !void {
    for (0..cols) |c| {
        const pc = t.screens.active.pages.getCell(.{ .active = .{ .x = @intCast(c), .y = row } }) orelse return error.NoCell;
        const cp = pc.cell.codepoint();
        if (cp != 0 and cp != ' ') return error.NotBlank;
    }
}

const multi_steps = [_][]const u8{
    "ihello<Esc>",
    ":split<CR>",
    "othere<Esc>",
    ":echo 'one line'<CR>",
    ":echo \"a\\nb\\nc\"<CR>",
    "<CR>",
    "<C-w>w",
    ":call setline(1, map(range(1, 60), '\"row \" . v:val'))<CR>",
    "<C-d>",
    "<C-e><C-e>",
    "<C-w>w",
    ":set number<CR>",
    "G",
    ":ec",
    "<Esc>",
    // floats: over a window, over the screen, then the popup menu
    ":lua B=vim.api.nvim_create_buf(false,true) vim.api.nvim_buf_set_lines(B,0,-1,false,{'float one','x'})<CR>",
    ":lua F1=vim.api.nvim_open_win(B,false,{relative='win',row=1,col=3,width=12,height=2,border='single'})<CR>",
    ":lua F2=vim.api.nvim_open_win(B,false,{relative='editor',anchor='SE',row=6,col=28,width=9,height=1,zindex=60})<CR>",
    "<C-e>",
    "<C-y>",
    "oapple apricot<CR>ap<C-n>",
    "<C-n>",
    "<Esc>",
    ":lua vim.api.nvim_win_set_config(F1,{relative='win',row=3,col=0})<CR>",
    ":lua vim.api.nvim_set_current_win(F1)<CR>",
    "Afloat text<Esc>",
    ":lua vim.api.nvim_win_close(F1,true) vim.api.nvim_win_close(F2,true)<CR>",
};

test "live neovim with a pane per window" {
    var buf: [1024]u8 = undefined;
    var m: Multi = .{
        .nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, &buf) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        },
        .panes = .{
            .{ .view = .init(30, 8), .t = try testTerminal(30, 8) },
            .{ .view = .init(24, 6), .t = try testTerminal(24, 6) },
        },
    };
    defer m.deinit();
    try m.nvim.uiAttach(30, 8, .{ .ext_multigrid = true });
    m.chan_req = try windows.askChannel(&m.nvim);
    try m.nvim.flush();
    try m.settle();
    for (multi_steps) |keys| {
        try m.input(keys);
        m.settle() catch |err| {
            std.debug.print("golden: after step {s}\n", .{keys});
            return err;
        };
    }
    try testing.expect(m.panes[1].win != 0);
    try testing.expect(m.stats.frames > multi_steps.len);
    // three message rows, so the scrolled-up message was drawn
    try testing.expect(m.stats.msg_rows > 3);
    try testing.expect(m.stats.scrolls > 0);
    try testing.expect(m.stats.cursors[0] > 0 and m.stats.cursors[1] > 0);
    try testing.expect(m.stats.floats > 0);
    try testing.expect(m.stats.float_cursor > 0);
    // all closed
    var placed_buf: [Grids.max_floats]Grids.Placed = undefined;
    for (m.panes) |p| try testing.expectEqual(0, m.gs.floatsOver(m.gs.gridOf(p.win).?, true, &.{}, &placed_buf).len);
}
