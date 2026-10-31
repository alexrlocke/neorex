//! Windows as panes, Neovim's side: `windows.lua` keeps every window except
//! a hidden anchor external and reports the current window. These calls
//! write requests; the caller flushes.

const std = @import("std");
const msgpack = @import("msgpack.zig");
const rpc = @import("rpc.zig");
const Nvim = @import("Nvim.zig");

const lua = @embedFile("windows.lua");

/// Installs the Lua on our channel `chan` and makes the current window
/// external at `cols` x `rows`. Its response is `[first window, anchor]`.
pub fn setup(nvim: *Nvim, chan: i64, cols: u32, rows: u32) !u32 {
    const id = try nvim.execLua(lua, 3);
    try msgpack.writeInt(nvim.writer(), chan);
    try msgpack.writeInt(nvim.writer(), cols);
    try msgpack.writeInt(nvim.writer(), rows);
    return id;
}

/// Makes ordinary window `win` external at `cols` x `rows`; anchors stay.
pub fn adopt(nvim: *Nvim, win: i64, cols: u32, rows: u32) !void {
    _ = try nvim.execLua("neorex.adopt(...)", 3);
    try msgpack.writeInt(nvim.writer(), win);
    try msgpack.writeInt(nvim.writer(), @max(cols, 1));
    try msgpack.writeInt(nvim.writer(), @max(rows, 1));
}

/// Sizes external window `win` to fill `cols` x `rows`, its statusline included.
pub fn size(nvim: *Nvim, win: i64, cols: u32, rows: u32) !void {
    _ = try nvim.execLua("neorex.size(...)", 3);
    try msgpack.writeInt(nvim.writer(), win);
    try msgpack.writeInt(nvim.writer(), @max(cols, 1));
    try msgpack.writeInt(nvim.writer(), @max(rows, 1));
}

/// Fits the floats hanging from editor floats `tops` to `w` x `h` at `row`,
/// `col`; `cur` is where they are now: row, col, width, height.
pub fn placeGroup(nvim: *Nvim, tops: []const i64, row: i32, col: i32, w: u32, h: u32, cur: [4]i64) !void {
    _ = try nvim.execLua("neorex.place_group(...)", 6);
    const wr = nvim.writer();
    try msgpack.writeArrayHeader(wr, @intCast(tops.len));
    for (tops) |t| try msgpack.writeInt(wr, t);
    try msgpack.writeInt(wr, row);
    try msgpack.writeInt(wr, col);
    try msgpack.writeInt(wr, @max(w, 1));
    try msgpack.writeInt(wr, @max(h, 1));
    try msgpack.writeArrayHeader(wr, 4);
    for (cur) |v| try msgpack.writeInt(wr, v);
}

/// Closes `win`, keeping unsaved changes in its buffer.
pub fn close(nvim: *Nvim, win: i64) !void {
    _ = try nvim.execLua("neorex.close(...)", 1);
    try msgpack.writeInt(nvim.writer(), win);
}

/// Returns the request's id.
pub fn setCurrent(nvim: *Nvim, win: i64) !u32 {
    const id = try nvim.request("nvim_set_current_win", 1);
    try msgpack.writeInt(nvim.writer(), win);
    return id;
}

/// Asks for our channel id: the response to the returned id starts with it.
pub fn askChannel(nvim: *Nvim) !u32 {
    return nvim.request("nvim_get_api_info", 0);
}

/// What the Lua tells the daemon.
pub const Note = union(enum) {
    /// The current window is now this one.
    current: i64,
    /// This window is closing and reopening; keep its pane for the new one.
    reopen: i64,
    /// A new window, and where Neovim put it.
    split: Split,
    /// The current window is now this float.
    float: i64,
};

/// Where a new window sits in Neovim's layout.
pub const Split = struct {
    win: i64,
    /// Side by side (`:vsplit`), else one above the other.
    side_by_side: bool,
    /// Left of or above the window beside it.
    before: bool,
    /// The window it was split from, or 0.
    from: i64,
};

/// A notification from the Lua, or null for any other.
pub fn parseNote(method: []const u8, params: *msgpack.Decoder) !?Note {
    const tag: std.meta.Tag(Note) = if (std.mem.eql(u8, method, "neorex_win"))
        .current
    else if (std.mem.eql(u8, method, "neorex_reopen"))
        .reopen
    else if (std.mem.eql(u8, method, "neorex_split"))
        .split
    else if (std.mem.eql(u8, method, "neorex_float"))
        .float
    else
        return null;
    if (try rpc.expectArray(params) < if (tag == .split) @as(u32, 4) else 1) return error.BadMessage;
    const win = try rpc.expectHandle(params);
    return switch (tag) {
        .current => .{ .current = win },
        .reopen => .{ .reopen = win },
        .float => .{ .float = win },
        .split => .{ .split = .{
            .win = win,
            .side_by_side = try rpc.expectBool(params),
            .before = try rpc.expectBool(params),
            .from = try rpc.expectHandle(params),
        } },
    };
}

/// `[first, anchor]` from `setup`'s response.
pub fn parseSetup(result: *msgpack.Decoder) ![2]i64 {
    if (try rpc.expectArray(result) < 2) return error.BadMessage;
    return .{ try rpc.expectHandle(result), try rpc.expectHandle(result) };
}

/// Our channel id from `askChannel`'s response.
pub fn parseChannel(result: *msgpack.Decoder) !i64 {
    if (try rpc.expectArray(result) < 1) return error.BadMessage;
    return rpc.expectInt(result);
}

const testing = std.testing;
const Grids = @import("../screen/Grids.zig");
const Grid = @import("../screen/Grid.zig");

/// A Neovim running windows.lua, and what it has said.
const Harness = struct {
    nvim: Nvim,
    grids: Grids = .{},
    notes: std.ArrayList(Note) = .empty,
    setup_id: u32 = 0,
    chan_id: u32 = 0,
    wins: [2]i64 = .{ 0, 0 },
    /// The windows a check waits for.
    want: i64 = 0,
    gone: i64 = 0,

    fn deinit(h: *Harness) void {
        h.grids.deinit(testing.allocator);
        h.notes.deinit(testing.allocator);
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
                    } else if (try parseNote(n.method, &params)) |note| try h.notes.append(gpa, note);
                },
                .response => |r| {
                    if (r.err) |e| {
                        std.debug.print("neovim: {s}\n", .{e});
                        return error.NvimError;
                    }
                    var result = r.result;
                    if (r.id == h.chan_id) {
                        h.setup_id = try setup(&h.nvim, try parseChannel(&result), 40, 9);
                        try h.nvim.flush();
                    } else if (r.id == h.setup_id) h.wins = try parseSetup(&result);
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

    fn splitNote(h: *const Harness, win: i64) ?Note {
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
    h.chan_id = try askChannel(&h.nvim);
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
    try testing.expectEqual(Note{ .split = .{ .win = split, .side_by_side = false, .before = true, .from = first } }, h.splitNote(split).?);
    try adopt(&h.nvim, split, 20, 9);
    // the anchor never becomes external
    try adopt(&h.nvim, anchor, 20, 9);
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
    try testing.expectEqual(Note{ .split = .{ .win = vsplit, .side_by_side = true, .before = false, .from = split } }, h.splitNote(vsplit).?);
    try close(&h.nvim, vsplit);
    try h.nvim.flush();
    h.gone = vsplit;
    try testing.expect(try h.until(struct {
        fn f(x: *Harness) bool {
            return x.kind(x.gone) == null;
        }
    }.f));
    // back to `split`, wherever Neovim went
    h.notes.clearRetainingCapacity();
    _ = try setCurrent(&h.nvim, first);
    _ = try setCurrent(&h.nvim, split);
    try h.nvim.flush();
    h.want = split;
    try testing.expect(try h.until(Harness.isCurrent));

    // its pane went away
    h.notes.clearRetainingCapacity();
    try close(&h.nvim, split);
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
    try testing.expectEqual(Note{ .reopen = first }, h.notes.items[0]);

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

test "each window shows a statusline inside its pane" {
    var buf: [1024]u8 = undefined;
    var h: Harness = .{ .nvim = Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    } };
    defer h.deinit();
    try h.nvim.uiAttach(40, 10, .{ .ext_multigrid = true });
    h.chan_id = try askChannel(&h.nvim);
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
}
