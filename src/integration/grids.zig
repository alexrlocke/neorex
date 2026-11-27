//! Grids built from a real Neovim's redraws.

const std = @import("std");
const testing = std.testing;
const Grids = @import("screen").Grids;
const Grid = @import("screen").Grid;
const nvim = @import("nvim");

const msgpack = @import("msgpack");

const pumpUntil = @import("../testing/redraws.zig").pumpUntil;
const testing_nvim = @import("../testing/nvim.zig");

test "neovim draws windows into their own grids" {
    const gpa = testing.allocator;
    var buf: [512]u8 = undefined;
    var nvim_client = try testing_nvim.spawn(&buf);
    defer nvim_client.deinit(gpa);
    try nvim_client.uiAttach(20, 6, .{ .ext_multigrid = true });
    _ = try nvim_client.request("nvim_input", 1);
    try msgpack.writeStr(nvim_client.writer(), "ihello<Esc>");
    try nvim_client.flush();

    var gs: Grids = .{};
    defer gs.deinit(gpa);
    try pumpUntil(&nvim_client, &gs, struct {
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
    _ = try nvim_client.execLua(
        \\vim.cmd.split()
        \\vim.api.nvim_win_set_config(1000, { external = true, width = 12, height = 3 })
    , 0);
    try nvim_client.flush();
    try pumpUntil(&nvim_client, &gs, struct {
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
