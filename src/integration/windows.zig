//! windows.lua in a real Neovim: what it tells the daemon, and what the
//! grids show.

const std = @import("std");
const testing = std.testing;
const Nvim = @import("../nvim/Nvim.zig");
const windows = @import("../nvim/windows.zig");
const Options = @import("../nvim/Options.zig");
const Grids = @import("../screen/Grids.zig");
const Grid = @import("../screen/Grid.zig");

const msgpack = @import("msgpack");

/// A Neovim running windows.lua, and what it has said.
const Harness = struct {
    nvim: Nvim,
    grids: Grids = .{},
    notes: std.ArrayList(windows.Note) = .empty,
    /// Each window's last title, copied: a note's points into the read buffer.
    titles: std.AutoArrayHashMapUnmanaged(i64, []u8) = .empty,
    setup_id: u32 = 0,
    chan_id: u32 = 0,
    wins: [2]i64 = .{ 0, 0 },
    /// The windows a check waits for.
    want: i64 = 0,
    gone: i64 = 0,
    /// The last options sent, how many have been, and their problems.
    options: Options = .default,
    options_sent: u32 = 0,
    problems_buf: [512]u8 = undefined,
    problems: []const u8 = "",

    fn deinit(h: *Harness) void {
        h.grids.deinit(testing.allocator);
        h.notes.deinit(testing.allocator);
        for (h.titles.values()) |t| testing.allocator.free(t);
        h.titles.deinit(testing.allocator);
        h.nvim.deinit(testing.allocator);
    }

    /// Reads until `done`, or false if Neovim exits.
    fn until(h: *Harness, comptime done: fn (*Harness) bool) !bool {
        const gpa = testing.allocator;
        for (0..200) |_| {
            if (done(h)) return true;
            var fds = [_]std.c.pollfd{.{ .fd = h.nvim.readFd(), .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 3000) <= 0) return error.TestTimedOut;
            if (!try h.nvim.read(gpa)) return false;
            while (try h.nvim.next()) |msg| switch (msg) {
                .notification => |n| {
                    var params = n.params;
                    if (std.mem.eql(u8, n.method, "redraw")) {
                        _ = try h.grids.applyRedraw(gpa, &params);
                    } else if (std.mem.eql(u8, n.method, Options.method)) {
                        var problems: std.Io.Writer = .fixed(&h.problems_buf);
                        h.options = try Options.decode(&params, &problems);
                        h.problems = problems.buffered();
                        h.options_sent += 1;
                    } else if (try windows.parseNote(n.method, &params)) |note| switch (note) {
                        .title => |t| {
                            const name = try gpa.dupe(u8, t.name);
                            if (try h.titles.fetchPut(gpa, t.win, name)) |old| gpa.free(old.value);
                        },
                        else => try h.notes.append(gpa, note),
                    };
                },
                .response => |r| {
                    if (r.err) |e| {
                        std.debug.print("neovim: {s}\n", .{e});
                        return error.NvimError;
                    }
                    var result = r.result;
                    if (r.id == h.chan_id) {
                        h.setup_id = try windows.setup(&h.nvim, try windows.parseChannel(&result), 40, 9);
                        try h.nvim.flush();
                    } else if (r.id == h.setup_id) h.wins = try windows.parseSetup(&result);
                },
                .request => |r| try h.nvim.respondError(r.id, "test"),
            };
        }
        return error.TestTimedOut;
    }

    fn input(h: *Harness, keys: []const u8) !void {
        _ = try h.nvim.request("nvim_input", 1);
        try msgpack.writeStr(h.nvim.writer(), keys);
        try h.nvim.flush();
    }

    fn lastCurrent(h: *const Harness) i64 {
        var i = h.notes.items.len;
        while (i > 0) {
            i -= 1;
            if (h.notes.items[i] == .current) return h.notes.items[i].current;
        }
        return 0;
    }

    fn splitNote(h: *const Harness, win: i64) ?windows.Note {
        for (h.notes.items) |n| if (n == .split and n.split.win == win) return n;
        return null;
    }

    fn isCurrent(h: *Harness) bool {
        return h.lastCurrent() == h.want;
    }

    fn kind(h: *const Harness, win: i64) ?Grids.Win.Kind {
        const grid = h.grids.gridOf(win) orelse return null;
        return h.grids.winOn(grid).?.kind;
    }
};

test "windows become external; the anchor stays hidden" {
    var buf: [1024]u8 = undefined;
    var h: Harness = .{ .nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    } };
    defer h.deinit();
    try h.nvim.uiAttach(40, 10, .{ .ext_multigrid = true });
    h.chan_id = try windows.askChannel(&h.nvim);
    try h.nvim.flush();

    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.wins[0] != 0 and x.lastCurrent() == x.wins[0] and x.kind(x.wins[0]) == .external;
        }
    }.f));
    const first, const anchor = h.wins;
    try testing.expectEqual(Grids.Win.Kind.ordinary, h.kind(anchor).?);

    // a split is ordinary until the daemon adopts it
    h.notes.clearRetainingCapacity();
    try h.input(":split<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            const cur = x.lastCurrent();
            return cur != 0 and x.kind(cur) == .ordinary;
        }
    }.f));
    const split = h.lastCurrent();
    try testing.expect(split != first and split != anchor);
    try testing.expectEqual(windows.Note{ .split = .{ .win = split, .side_by_side = false, .before = true, .from = first } }, h.splitNote(split).?);
    try windows.adopt(&h.nvim, split, 20, 9);
    // the anchor never becomes external
    try windows.adopt(&h.nvim, anchor, 20, 9);
    try h.nvim.flush();
    h.want = split;
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.kind(x.want) == .external;
        }
    }.f));

    // <C-w>w wraps through the anchor to the first window, <C-w>W back
    h.notes.clearRetainingCapacity();
    try h.input("<C-w>w");
    h.want = first;
    try testing.expect(try h.until(Harness.isCurrent));
    h.notes.clearRetainingCapacity();
    try h.input("<C-w>W");
    h.want = split;
    try testing.expect(try h.until(Harness.isCurrent));
    try testing.expectEqual(Grids.Win.Kind.ordinary, h.kind(anchor).?);

    // :vsplit with splitright: beside, after
    h.notes.clearRetainingCapacity();
    try h.input(":set splitright | vsplit<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            const cur = x.lastCurrent();
            return cur != 0 and x.kind(cur) == .ordinary;
        }
    }.f));
    const vsplit = h.lastCurrent();
    try testing.expectEqual(windows.Note{ .split = .{ .win = vsplit, .side_by_side = true, .before = false, .from = split } }, h.splitNote(vsplit).?);
    try windows.close(&h.nvim, vsplit);
    try h.nvim.flush();
    h.gone = vsplit;
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.kind(x.gone) == null;
        }
    }.f));
    // back to `split`, wherever Neovim went
    h.notes.clearRetainingCapacity();
    _ = try windows.setCurrent(&h.nvim, first);
    _ = try windows.setCurrent(&h.nvim, split);
    try h.nvim.flush();
    h.want = split;
    try testing.expect(try h.until(Harness.isCurrent));

    // its pane went away
    h.notes.clearRetainingCapacity();
    try windows.close(&h.nvim, split);
    try h.nvim.flush();
    h.want = first;
    h.gone = split;
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.isCurrent() and x.kind(x.gone) == null;
        }
    }.f));

    // :close on the last window reopens it
    h.notes.clearRetainingCapacity();
    try h.input(":close<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            const cur = x.lastCurrent();
            return cur != 0 and cur != x.want and x.kind(cur) == .external and x.kind(x.want) == null;
        }
    }.f));
    try testing.expectEqual(windows.Note{ .reopen = first }, h.notes.items[0]);

    // :q on the last window quits
    try h.input(":q<CR>");
    try testing.expect(!try h.until(struct {
        fn f(_: *Harness) bool {
            return false;
        }
    }.f));
}

/// Grid row `r` of window `win` starts with `want`.
fn rowStarts(h: *const Harness, win: i64, r: u32, want: []const u8) bool {
    const g = h.grids.get(h.grids.gridOf(win) orelse return false) orelse return false;
    if (r >= g.height) return false;
    var buf: [256]u8 = undefined;
    return std.mem.startsWith(u8, Grid.rowText(g, r, &buf), want);
}

fn gridHeight(h: *const Harness, win: i64) u32 {
    const g = h.grids.get(h.grids.gridOf(win) orelse return 0) orelse return 0;
    return g.height;
}

fn gridWidth(h: *const Harness, win: i64) u32 {
    const g = h.grids.get(h.grids.gridOf(win) orelse return 0) orelse return 0;
    return g.width;
}

/// Runs Lua `code` in Neovim, then waits until a note sent `ms` later arrives:
/// by then anything the Lua scheduled has run and been drawn.
fn luaThenSettle(h: *Harness, comptime code: []const u8, comptime ms: []const u8) !void {
    try h.input(":lua " ++ code ++ "<CR>");
    // 'cmdheight' notes are the harness's to read; 99 marks this one
    try h.input(":lua vim.defer_fn(function() vim.rpcnotify(0, 'neorex_cmdheight', 99) end, " ++ ms ++ ")<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return lastCmdheight(x) == 99;
        }
    }.f));
    h.notes.clearRetainingCapacity();
}

test "a window Neovim resizes itself snaps back to its pane's size" {
    var buf: [1024]u8 = undefined;
    var h: Harness = .{ .nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    } };
    defer h.deinit();
    try h.nvim.uiAttach(40, 10, .{ .ext_multigrid = true });
    h.chan_id = try windows.askChannel(&h.nvim);
    try h.nvim.flush();
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.wins[0] != 0 and x.kind(x.wins[0]) == .external;
        }
    }.f));
    const win = h.wins[0];
    const cols = gridWidth(&h, win);
    const rows = gridHeight(&h, win);
    try testing.expect(cols > 20 and rows > 3);

    // as a plugin widening or shrinking its window would
    try luaThenSettle(&h, "vim.api.nvim_win_set_width(0, 20)", "200");
    try testing.expectEqual(cols, gridWidth(&h, win));
    try luaThenSettle(&h, "vim.api.nvim_win_set_height(0, 3)", "200");
    try testing.expectEqual(rows, gridHeight(&h, win));
    // as :vertical resize does
    try luaThenSettle(&h, "vim.cmd('vertical resize 30')", "200");
    try testing.expectEqual(cols, gridWidth(&h, win));
}

fn resizeOf(h: *const Harness, win: i64) ?windows.Resize {
    for (h.notes.items) |n| if (n == .resize and n.resize.win == win) return n.resize;
    return null;
}

test "a window Neovim resizes asks for its pane to be resized" {
    var buf: [1024]u8 = undefined;
    var h: Harness = .{ .nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    } };
    defer h.deinit();
    try h.nvim.uiAttach(40, 10, .{ .ext_multigrid = true });
    h.chan_id = try windows.askChannel(&h.nvim);
    try h.nvim.flush();
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.wins[0] != 0 and x.kind(x.wins[0]) == .external;
        }
    }.f));
    const win = h.wins[0];
    const cols: i32 = @intCast(gridWidth(&h, win));
    const rows: i32 = @intCast(gridHeight(&h, win));

    // narrower, as :vertical resize does: the pane is asked to shrink by the
    // difference, and the window snaps back meanwhile
    h.notes.clearRetainingCapacity();
    try h.input(":vertical resize 30<CR>");
    h.want = win;
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return resizeOf(x, x.want) != null;
        }
    }.f));
    try testing.expectEqual(windows.Resize{ .win = win, .cols = 30 - cols, .rows = 0 }, resizeOf(&h, win).?);
    try testing.expectEqual(@as(u32, @intCast(cols)), gridWidth(&h, win));

    // shorter, as a plugin setting its height would
    h.notes.clearRetainingCapacity();
    try h.input(":lua vim.api.nvim_win_set_height(0, 3)<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return resizeOf(x, x.want) != null;
        }
    }.f));
    // the grid has the statusline too; the text had a row less
    try testing.expectEqual(windows.Resize{ .win = win, .cols = 0, .rows = 3 - (rows - 1) }, resizeOf(&h, win).?);

    // our own resize, and <C-w>_ / <C-w>| (Rex zooms instead), ask for nothing
    try luaThenSettle(&h, "", "200");
    try h.input(":lua neorex.size(vim.api.nvim_get_current_win(), 20, 5)<CR>");
    try h.input("<C-w>_<C-w>|");
    try h.input(":lua vim.defer_fn(function() vim.rpcnotify(0, 'neorex_cmdheight', 99) end, 200)<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return lastCmdheight(x) == 99;
        }
    }.f));
    try testing.expectEqual(@as(?windows.Resize, null), resizeOf(&h, win));
    try testing.expectEqual(@as(u32, 20), gridWidth(&h, win));
}

fn fixedOf(h: *const Harness, win: i64) ?u32 {
    for (h.notes.items) |n| if (n == .fixed and n.fixed.win == win) return n.fixed.cells;
    return null;
}

fn newOrdinary(x: *Harness) bool {
    const cur = x.lastCurrent();
    return cur != 0 and x.kind(cur) == .ordinary;
}

fn wantExternal(x: *Harness) bool {
    return x.kind(x.want) == .external;
}

/// Opens a window with `cmd`, adopts it, and returns it and what it
/// reported as its fixed size. The note comes before the redraw that shows it
/// external, so once it's external there's none to wait for.
fn openAdopted(h: *Harness, cmd: []const u8) !struct { i64, ?u32 } {
    h.notes.clearRetainingCapacity();
    try h.input(cmd);
    try testing.expect(try h.until(newOrdinary));
    const win = h.lastCurrent();
    try windows.adopt(&h.nvim, win, 20, 9);
    try h.nvim.flush();
    h.want = win;
    try testing.expect(try h.until(wantExternal));
    return .{ win, fixedOf(h, win) };
}

fn closeAndWait(h: *Harness, win: i64) !void {
    try windows.close(&h.nvim, win);
    try h.nvim.flush();
    h.gone = win;
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.kind(x.gone) == null;
        }
    }.f));
}

test "fixed-size windows report their size" {
    var buf: [1024]u8 = undefined;
    var h: Harness = .{ .nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    } };
    defer h.deinit();
    try h.nvim.uiAttach(40, 10, .{ .ext_multigrid = true });
    h.chan_id = try windows.askChannel(&h.nvim);
    try h.nvim.flush();
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.wins[0] != 0 and x.kind(x.wins[0]) == .external;
        }
    }.f));

    // a plain :vsplit isn't fixed
    const plain = try openAdopted(&h, ":vsplit<CR>");
    try testing.expectEqual(@as(?u32, null), plain[1]);
    try closeAndWait(&h, plain[0]);

    // nor is a sized split that isn't fixed
    const sized = try openAdopted(&h, ":vertical 10split<CR>");
    try testing.expectEqual(@as(?u32, null), sized[1]);
    try closeAndWait(&h, sized[0]);

    // like nvim-tree: at the left, 10 columns, fixed
    const tree = try openAdopted(&h, ":topleft vsplit | vertical resize 10 | setlocal winfixwidth<CR>");
    try testing.expectEqual(@as(?u32, 10), tree[1]);
    try testing.expect(h.splitNote(tree[0]).?.split.before);
    try closeAndWait(&h, tree[0]);

    // like the quickfix list: below, 3 rows and Neovim's default statusline
    const panel = try openAdopted(&h, ":botright 3split | setlocal winfixheight<CR>");
    try testing.expectEqual(@as(?u32, 4), panel[1]);
    try testing.expect(!h.splitNote(panel[0]).?.split.side_by_side);
}

fn titleIs(h: *const Harness, win: i64, want: []const u8) bool {
    return if (h.titles.get(win)) |t| std.mem.eql(u8, t, want) else false;
}

test "each window's title is its file name" {
    var buf: [1024]u8 = undefined;
    var h: Harness = .{ .nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    } };
    defer h.deinit();
    try h.nvim.uiAttach(40, 10, .{ .ext_multigrid = true });
    h.chan_id = try windows.askChannel(&h.nvim);
    try h.nvim.flush();

    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.wins[0] != 0 and titleIs(x, x.wins[0], "[No Name]");
        }
    }.f));
    const first, const anchor = h.wins;
    // a new buffer in the same window
    try h.input(":edit /tmp/neorex-dir/some file.txt<CR>");
    h.want = first;
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return titleIs(x, x.want, "some file.txt");
        }
    }.f));
    // a split onto another file: its own title, the first keeps its own
    h.notes.clearRetainingCapacity();
    try h.input(":split other.zig<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            const cur = x.lastCurrent();
            return cur != 0 and cur != x.want and titleIs(x, cur, "other.zig");
        }
    }.f));
    try testing.expect(titleIs(&h, first, "some file.txt"));
    // a directory goes by its own name
    try h.input(":file /tmp/neorex-dir/<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return titleIs(x, x.lastCurrent(), "neorex-dir");
        }
    }.f));
    try testing.expect(titleIs(&h, first, "some file.txt"));
    // the anchor is never named
    try testing.expect(h.titles.get(anchor) == null);
}

test "each window shows a statusline inside its pane" {
    var buf: [1024]u8 = undefined;
    var h: Harness = .{ .nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    } };
    defer h.deinit();
    try h.nvim.uiAttach(40, 10, .{ .ext_multigrid = true });
    h.chan_id = try windows.askChannel(&h.nvim);
    try h.nvim.flush();

    // setup sizes the first window to 40 x 9: 8 rows of text and the statusline
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.wins[0] != 0 and gridHeight(x, x.wins[0]) == 9 and rowStarts(x, x.wins[0], 8, "[No Name]");
        }
    }.f));

    // :set statusline reaches the window
    try h.input(":set statusline=GLOBAL<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return rowStarts(x, x.wins[0], 8, "GLOBAL");
        }
    }.f));

    // a buffer new to the window starts with an empty local statusline:
    // it's given back
    try h.input(":set statusline=GLOBAL\\ %f<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return rowStarts(x, x.wins[0], 8, "GLOBAL ");
        }
    }.f));
    try h.input(":edit one | edit two | put! =&l:statusline<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return rowStarts(x, x.wins[0], 0, "GLOBAL %f") and rowStarts(x, x.wins[0], 8, "GLOBAL two");
        }
    }.f));

    // no statusline: the text gets the row back
    try h.input(":set laststatus=0<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return gridHeight(x, x.wins[0]) == 9 and rowStarts(x, x.wins[0], 8, "~");
        }
    }.f));

    // the user's own statusline for a window stays
    try h.input(":set laststatus=2 | setlocal statusline=MINE | lua vim.go.statusline = 'OTHER'<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return gridHeight(x, x.wins[0]) == 9 and rowStarts(x, x.wins[0], 8, "MINE");
        }
    }.f));

    // laststatus=3 would draw no statusline in any pane: it becomes 2
    try h.input(":setlocal statusline= | set laststatus=0<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return gridHeight(x, x.wins[0]) == 9 and rowStarts(x, x.wins[0], 8, "~");
        }
    }.f));
    try h.input(":set laststatus=3<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return gridHeight(x, x.wins[0]) == 9 and rowStarts(x, x.wins[0], 8, "OTHER");
        }
    }.f));
    try h.input(":put! =&laststatus<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return rowStarts(x, x.wins[0], 0, "2 ");
        }
    }.f));
}

test "to Lua, a window a pane shows isn't a popup" {
    var buf: [1024]u8 = undefined;
    var h: Harness = .{ .nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    } };
    defer h.deinit();
    try h.nvim.uiAttach(40, 10, .{ .ext_multigrid = true });
    h.chan_id = try windows.askChannel(&h.nvim);
    try h.nvim.flush();
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.wins[0] != 0 and gridHeight(x, x.wins[0]) == 9;
        }
    }.f));

    // the external window, by no argument, window ID and window number; a
    // float stays a popup
    try h.input(":lua local f = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, " ++
        "{ relative = 'editor', row = 0, col = 0, width = 5, height = 1 }) " ++
        "local t = vim.fn.win_gettype " ++
        "vim.api.nvim_buf_set_lines(0, 0, 0, false, { '[' .. t() .. '|' .. t(vim.api.nvim_get_current_win()) .. " ++
        "'|' .. t(vim.fn.winnr()) .. '|' .. t(f) .. ']' })<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return rowStarts(x, x.wins[0], 0, "[|||popup]");
        }
    }.f));
}

fn lastCmdheight(h: *const Harness) ?u32 {
    var i = h.notes.items.len;
    while (i > 0) {
        i -= 1;
        if (h.notes.items[i] == .cmdheight) return h.notes.items[i].cmdheight;
    }
    return null;
}

test "'cmdheight' is reported at setup and when it changes" {
    var buf: [1024]u8 = undefined;
    var h: Harness = .{ .nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    } };
    defer h.deinit();
    try h.nvim.uiAttach(40, 10, .{ .ext_multigrid = true });
    h.chan_id = try windows.askChannel(&h.nvim);
    try h.nvim.flush();

    // the default, sent during setup
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.wins[0] != 0 and lastCmdheight(x) == 1;
        }
    }.f));

    try h.input(":set cmdheight=0<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return lastCmdheight(x) == 0;
        }
    }.f));

    try h.input(":set cmdheight=2<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return lastCmdheight(x) == 2;
        }
    }.f));
}

/// A Neovim run with `extra` args, its Lua set up.
fn optionsHarness(buf: []u8, comptime extra: []const []const u8) !Harness {
    var h: Harness = .{ .nvim = Nvim.spawn(testing.io, &[_][]const u8{ "nvim", "--clean", "--embed", "-n" } ++ extra, buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    } };
    errdefer h.deinit();
    try h.nvim.uiAttach(60, 10, .{ .ext_multigrid = true });
    h.chan_id = try windows.askChannel(&h.nvim);
    try h.nvim.flush();
    return h;
}

test "options: set before startup, then changed while running" {
    var buf: [1024]u8 = undefined;
    var h = try optionsHarness(&buf, &.{ "--cmd", "lua vim.g.neorex_config = { cmdline = 'rex', ui = { select = 'rex' } }" });
    defer h.deinit();
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.options.cmdline == .rex;
        }
    }.f));
    try testing.expectEqual(Options{ .cmdline = .rex, .ui = .{ .select = .rex } }, h.options);
    try testing.expectEqualStrings("", h.problems);

    // configure replaces the whole table
    try h.input(":lua neorex.configure({ palette = true })<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.options.palette;
        }
    }.f));
    try testing.expectEqual(Options{ .palette = true }, h.options);

    try h.input(":lua neorex.configure(nil)<CR>");
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return !x.options.palette;
        }
    }.f));
    try testing.expectEqual(Options.default, h.options);
    try testing.expectEqualStrings("", h.problems);
}

test "options: set by init, after windows.lua may have run" {
    var buf: [1024]u8 = undefined;
    // -c runs just before VimEnter
    var h = try optionsHarness(&buf, &.{ "-c", "lua vim.g.neorex_config = { confirm = 'rex' }" });
    defer h.deinit();
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.options.confirm == .rex;
        }
    }.f));
    try testing.expectEqual(Options{ .confirm = .rex }, h.options);
}

test "options: what's wrong reaches the daemon" {
    var buf: [1024]u8 = undefined;
    var h = try optionsHarness(&buf, &.{ "--cmd", "lua vim.g.neorex_config = { cmdline = 'tui', palette = true }" });
    defer h.deinit();
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.options.palette;
        }
    }.f));
    try testing.expectEqualStrings("neorex_config.cmdline: expected \"neovim\" or \"rex\", got \"tui\"\n", h.problems);
}
