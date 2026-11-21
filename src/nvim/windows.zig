//! Windows as panes, Neovim's side: `windows.lua` keeps every window except
//! a hidden anchor external and reports the current window. These calls
//! write requests; the caller flushes.

const std = @import("std");
const rpc = @import("rpc.zig");
const Nvim = @import("Nvim.zig");

const msgpack = @import("msgpack");

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
/// `col`. Returns the request's id: its answer comes after their redraw.
pub fn placeGroup(nvim: *Nvim, tops: []const i64, row: i32, col: i32, w: u32, h: u32) !u32 {
    const id = try nvim.execLua("neorex.place_group(...)", 5);
    const wr = nvim.writer();
    try msgpack.writeArrayHeader(wr, @intCast(tops.len));
    for (tops) |t| try msgpack.writeInt(wr, t);
    try msgpack.writeInt(wr, row);
    try msgpack.writeInt(wr, col);
    try msgpack.writeInt(wr, @max(w, 1));
    try msgpack.writeInt(wr, @max(h, 1));
    return id;
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
    /// A new window has a fixed size ('winfixwidth' or 'winfixheight'), as
    /// a sidebar or the quickfix list does; sent as it's adopted.
    fixed: Fixed,
    /// Neovim resized a window; it was put back, and wants its pane resized.
    resize: Resize,
    /// The current window is now this float.
    float: i64,
    /// This float was just entered; sent before the redraw that shows it.
    entered: i64,
    /// The file name a window shows, for its pane's label.
    title: Title,
    /// 'cmdheight': the rows each pane keeps for the command line.
    cmdheight: u32,
};

pub const Title = struct {
    win: i64,
    /// Points into the message: valid until the next read.
    name: []const u8,
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
    /// A fixed-size window's size across the split, in cells; 0 for an
    /// ordinary window, or until `fixed` says.
    fixed_cells: u32 = 0,
};

/// A fixed-size window: it keeps its size, and opens at the edge of our
/// panes like Neovim's :topleft.
pub const Fixed = struct {
    win: i64,
    /// Columns beside, or rows above or below, statusline included.
    cells: u32,
};

/// How much Neovim wanted a window to grow: columns and rows, negative to
/// shrink.
pub const Resize = struct {
    win: i64,
    cols: i32,
    rows: i32,
};

/// A notification from the Lua, or null for any other.
pub fn parseNote(method: []const u8, params: *msgpack.Decoder) !?Note {
    const tag: std.meta.Tag(Note) = if (std.mem.eql(u8, method, "neorex_win"))
        .current
    else if (std.mem.eql(u8, method, "neorex_reopen"))
        .reopen
    else if (std.mem.eql(u8, method, "neorex_split"))
        .split
    else if (std.mem.eql(u8, method, "neorex_fixed"))
        .fixed
    else if (std.mem.eql(u8, method, "neorex_resize"))
        .resize
    else if (std.mem.eql(u8, method, "neorex_float"))
        .float
    else if (std.mem.eql(u8, method, "neorex_entered"))
        .entered
    else if (std.mem.eql(u8, method, "neorex_title"))
        .title
    else if (std.mem.eql(u8, method, "neorex_cmdheight"))
        .cmdheight
    else
        return null;
    const want: u32 = switch (tag) {
        .split => 4,
        .resize => 3,
        .title, .fixed => 2,
        else => 1,
    };
    if (try msgpack.expectArray(params) < want) return error.BadMessage;
    // the one note that isn't about a window
    if (tag == .cmdheight) return .{ .cmdheight = std.math.cast(u32, try msgpack.expectInt(params)) orelse return error.BadMessage };
    const win = try msgpack.expectHandle(params);
    return switch (tag) {
        .current => .{ .current = win },
        .reopen => .{ .reopen = win },
        .float => .{ .float = win },
        .entered => .{ .entered = win },
        .title => .{ .title = .{ .win = win, .name = try msgpack.expectStr(params) } },
        .fixed => .{ .fixed = .{ .win = win, .cells = std.math.cast(u32, try msgpack.expectInt(params)) orelse return error.BadMessage } },
        .resize => .{ .resize = .{
            .win = win,
            .cols = std.math.cast(i32, try msgpack.expectInt(params)) orelse return error.BadMessage,
            .rows = std.math.cast(i32, try msgpack.expectInt(params)) orelse return error.BadMessage,
        } },
        .cmdheight => unreachable,
        .split => .{ .split = .{
            .win = win,
            .side_by_side = try msgpack.expectBool(params),
            .before = try msgpack.expectBool(params),
            .from = try msgpack.expectHandle(params),
        } },
    };
}

/// `[first, anchor]` from `setup`'s response.
pub fn parseSetup(result: *msgpack.Decoder) ![2]i64 {
    if (try msgpack.expectArray(result) < 2) return error.BadMessage;
    return .{ try msgpack.expectHandle(result), try msgpack.expectHandle(result) };
}

/// Our channel id from `askChannel`'s response.
pub fn parseChannel(result: *msgpack.Decoder) !i64 {
    if (try msgpack.expectArray(result) < 1) return error.BadMessage;
    return msgpack.expectInt(result);
}
