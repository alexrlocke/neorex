//! Grids built from a real Neovim's redraws.

const std = @import("std");
const testing = std.testing;
const Nvim = @import("../nvim/Nvim.zig");
const Grids = @import("../screen/Grids.zig");
const Grid = @import("../screen/Grid.zig");

const msgpack = @import("msgpack");

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
            return std.mem.startsWith(u8, Grid.rowText(g.get(id).?, 0, &b), "hello");
        }
    }.f);
    const first = gs.gridOf(1000).?;
    try testing.expect(first != 1);
    try testing.expectEqual(Grids.Win.Kind.ordinary, gs.winOn(first).?.kind);
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
                std.mem.startsWith(u8, Grid.rowText(g.get(id).?, 0, &b), "hello");
        }
    }.f);
    var text: [32]u8 = undefined;
    try testing.expectEqualStrings("hello       ", Grid.rowText(gs.get(gs.gridOf(1000).?).?, 0, &text));
    try testing.expectEqual(Grids.Win.Kind.ordinary, gs.winOn(gs.gridOf(1001).?).?.kind);
    try testing.expect(gs.msg_grid != null);
}
