//! A Neovim running windows.lua, and what it has said: for tests that drive a
//! real Neovim and check what it tells the daemon and what its grids show.

const std = @import("std");
const testing = std.testing;
const Grids = @import("screen").Grids;
const nvim = @import("nvim");

const msgpack = @import("msgpack");

const NvimHarness = @This();

nvim_client: nvim.Nvim,
grids: Grids = .{},
notes: std.ArrayList(nvim.windows.Note) = .empty,
/// Each window's last title, copied: a note's points into the read buffer.
titles: std.AutoArrayHashMapUnmanaged(i64, []u8) = .empty,
setup_id: u32 = 0,
chan_id: u32 = 0,
wins: [2]i64 = .{ 0, 0 },
/// The windows a check waits for.
want: i64 = 0,
gone: i64 = 0,
/// The last options sent, how many have been, and their problems.
options: nvim.Options = .default,
options_sent: u32 = 0,
problems_buf: [512]u8 = undefined,
problems: []const u8 = "",

pub fn deinit(h: *NvimHarness) void {
    h.grids.deinit(testing.allocator);
    h.notes.deinit(testing.allocator);
    for (h.titles.values()) |t| testing.allocator.free(t);
    h.titles.deinit(testing.allocator);
    h.nvim_client.deinit(testing.allocator);
}

/// Reads until `done`, or false if Neovim exits.
pub fn until(h: *NvimHarness, comptime done: fn (*NvimHarness) bool) !bool {
    const gpa = testing.allocator;
    for (0..200) |_| {
        if (done(h)) return true;
        var fds = [_]std.c.pollfd{.{ .fd = h.nvim_client.readFd(), .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 3000) <= 0) return error.TestTimedOut;
        if (!try h.nvim_client.read(gpa)) return false;
        while (try h.nvim_client.next()) |msg| switch (msg) {
            .notification => |n| {
                var params = n.params;
                if (std.mem.eql(u8, n.method, "redraw")) {
                    _ = try h.grids.applyRedraw(gpa, &params);
                } else if (std.mem.eql(u8, n.method, nvim.Options.method)) {
                    var problems: std.Io.Writer = .fixed(&h.problems_buf);
                    h.options = try nvim.Options.decode(&params, &problems);
                    h.problems = problems.buffered();
                    h.options_sent += 1;
                } else if (try nvim.windows.parseNote(n.method, &params)) |note| switch (note) {
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
                    h.setup_id = try nvim.windows.setup(&h.nvim_client, try nvim.windows.parseChannel(&result), 40, 9);
                    try h.nvim_client.flush();
                } else if (r.id == h.setup_id) h.wins = try nvim.windows.parseSetup(&result);
            },
            .request => |r| try h.nvim_client.respondError(r.id, "test"),
        };
    }
    return error.TestTimedOut;
}

pub fn input(h: *NvimHarness, keys: []const u8) !void {
    _ = try h.nvim_client.request("nvim_input", 1);
    try msgpack.writeStr(h.nvim_client.writer(), keys);
    try h.nvim_client.flush();
}

pub fn lastCurrent(h: *const NvimHarness) i64 {
    var i = h.notes.items.len;
    while (i > 0) {
        i -= 1;
        if (h.notes.items[i] == .current) return h.notes.items[i].current;
    }
    return 0;
}

pub fn splitNote(h: *const NvimHarness, win: i64) ?nvim.windows.Note {
    for (h.notes.items) |n| if (n == .split and n.split.win == win) return n;
    return null;
}

pub fn isCurrent(h: *NvimHarness) bool {
    return h.lastCurrent() == h.want;
}

pub fn kind(h: *const NvimHarness, win: i64) ?Grids.Win.Kind {
    const grid = h.grids.gridOf(win) orelse return null;
    return h.grids.winOn(grid).?.kind;
}
