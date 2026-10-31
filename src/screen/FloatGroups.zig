//! Floats big enough to show in a Rex floating pane. A group is an editor
//! float with every float hanging from it, as a picker builds its box,
//! input, list and preview; groups that touch, as Telescope's do, are one.
//! It goes native when something in it takes focus and it's big enough.

const std = @import("std");
const Grids = @import("Grids.zig");

pub const min_cols = 20;
pub const min_rows = 5;
pub const max_groups = 4;
const max_tops = 16;

pub const Group = struct {
    /// The editor floats in it, by grid.
    tops: [max_tops]u32 = undefined,
    tops_len: u8 = 0,
    /// Names the group while it's open: its lowest window handle.
    key: i64 = 0,
    /// Where it sits on grid 1.
    row: i32 = 0,
    col: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    focusable: bool = false,

    pub fn topGrids(g: *const Group) []const u32 {
        return g.tops[0..g.tops_len];
    }

    pub fn hasTop(g: *const Group, top: u32) bool {
        return std.mem.indexOfScalar(u32, g.topGrids(), top) != null;
    }

    fn bottom(g: Group) i64 {
        return @as(i64, g.row) + g.height;
    }

    fn right(g: Group) i64 {
        return @as(i64, g.col) + g.width;
    }

    /// Overlapping or a cell apart.
    fn touches(a: Group, b: Group) bool {
        return a.row <= b.bottom() + 1 and b.row <= a.bottom() + 1 and a.col <= b.right() + 1 and b.col <= a.right() + 1;
    }

    fn merge(a: *Group, b: Group) void {
        a.unite(b.row, b.col, b.width, b.height);
        a.focusable = a.focusable or b.focusable;
        a.key = @min(a.key, b.key);
        for (b.topGrids()) |t| if (a.tops_len < max_tops) {
            a.tops[a.tops_len] = t;
            a.tops_len += 1;
        };
    }

    /// Grows to cover the rect too.
    fn unite(g: *Group, row: i32, col: i32, width: u32, height: u32) void {
        if (g.width == 0) {
            g.* = .{ .tops = g.tops, .tops_len = g.tops_len, .key = g.key, .focusable = g.focusable, .row = row, .col = col, .width = width, .height = height };
            return;
        }
        const top = @min(g.row, row);
        const left = @min(g.col, col);
        g.height = @intCast(@max(g.bottom(), @as(i64, row) + height) - top);
        g.width = @intCast(@max(g.right(), @as(i64, col) + width) - left);
        g.row = top;
        g.col = left;
    }
};

/// The groups to show natively.
pub fn find(grids: *const Grids, out: *[max_groups]Group) []Group {
    var all: [max_tops]Group = undefined;
    var n: usize = 0;
    // each editor float, with the floats hanging from it
    for (grids.wins.keys(), grids.wins.values()) |id, w| {
        if (w.kind != .float or w.win < 0 or n == all.len) continue;
        const p = grids.place(id) orelse continue;
        if (p.top != id) continue;
        var g: Group = .{ .key = w.win };
        g.tops[0] = id;
        g.tops_len = 1;
        for (grids.wins.keys(), grids.wins.values()) |mid, m| {
            if (m.kind != .float) continue;
            const mp = grids.place(mid) orelse continue;
            if (mp.top != id) continue;
            const grid = grids.get(mid) orelse continue;
            if (grid.width == 0 or grid.height == 0) continue;
            g.unite(mp.row, mp.col, grid.width, grid.height);
            g.focusable = g.focusable or m.float.focusable;
        }
        if (g.width == 0) continue;
        all[n] = g;
        n += 1;
    }
    // focusable groups that touch become one
    var merged = true;
    while (merged) {
        merged = false;
        outer: for (0..n) |i| for (i + 1..n) |j| {
            if (!all[i].focusable or !all[j].focusable or !all[i].touches(all[j])) continue;
            all[i].merge(all[j]);
            all[j] = all[n - 1];
            n -= 1;
            merged = true;
            break :outer;
        };
    }
    var k: usize = 0;
    for (all[0..n]) |g| {
        if (!g.focusable or g.width < min_cols or g.height < min_rows or k == out.len) continue;
        out[k] = g;
        k += 1;
    }
    return out[0..k];
}

/// The floats in group `g`, lowest first.
pub fn members(grids: *const Grids, g: *const Group, out: *[Grids.max_floats]Grids.Placed) []Grids.Placed {
    var n: usize = 0;
    for (grids.wins.keys(), grids.wins.values()) |id, w| {
        if (w.kind != .float or n == out.len) continue;
        const p = grids.place(id) orelse continue;
        if (p.top == 0 or !g.hasTop(p.top)) continue;
        out[n] = .{ .grid = id, .row = p.row, .col = p.col, .zindex = w.float.zindex, .compindex = w.float.compindex, .on_screen = true, .top = p.top };
        n += 1;
    }
    const placed = out[0..n];
    Grids.sortPlaced(placed);
    return placed;
}

const testing = std.testing;

fn addFloat(gs: *Grids, grid: u32, win: i64, w: u32, h: u32, f: Grids.Float) !void {
    try gs.grids.put(testing.allocator, grid, .{});
    try gs.grids.getPtr(grid).?.resize(testing.allocator, w, h);
    try gs.wins.put(testing.allocator, grid, .{ .win = win, .kind = .float, .float = f });
}

test "a picker's floats are one group; small or unfocusable ones aren't" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    // a picker as snacks makes it: an unfocusable box, input and list on it
    try addFloat(&gs, 3, 1002, 60, 20, .{ .focusable = false, .screen = .{ 4, 10 } });
    try addFloat(&gs, 4, 1004, 58, 1, .{ .anchor_grid = 3, .row = 1, .col = 1 });
    try addFloat(&gs, 5, 1005, 58, 16, .{ .anchor_grid = 3, .row = 3, .col = 1 });
    // a notification: unfocusable
    try addFloat(&gs, 6, 1006, 30, 6, .{ .focusable = false, .screen = .{ 0, 100 } });
    // a small focusable input
    try addFloat(&gs, 7, 1007, 30, 1, .{ .screen = .{ 40, 0 } });
    // the popup menu
    try addFloat(&gs, 8, -1, 30, 10, .{ .screen = .{ 40, 40 } });

    var buf: [max_groups]Group = undefined;
    const groups = find(&gs, &buf);
    try testing.expectEqual(1, groups.len);
    const g = groups[0];
    try testing.expectEqualSlices(u32, &.{3}, g.topGrids());
    try testing.expectEqual(@as(i64, 1002), g.key);
    try testing.expectEqual(@as(i32, 4), g.row);
    try testing.expectEqual(@as(i32, 10), g.col);
    try testing.expectEqual(@as(u32, 60), g.width);
    try testing.expectEqual(@as(u32, 20), g.height);

    var mbuf: [Grids.max_floats]Grids.Placed = undefined;
    const ms = members(&gs, &g, &mbuf);
    try testing.expectEqual(3, ms.len);
}

test "editor floats side by side, as Telescope's, are one group" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    // prompt over results, preview to the right with a gap of a cell
    try addFloat(&gs, 3, 1010, 40, 3, .{ .screen = .{ 2, 2 } });
    try addFloat(&gs, 4, 1011, 40, 20, .{ .screen = .{ 5, 2 } });
    try addFloat(&gs, 5, 1012, 40, 23, .{ .screen = .{ 2, 43 } });
    var buf: [max_groups]Group = undefined;
    const groups = find(&gs, &buf);
    try testing.expectEqual(1, groups.len);
    try testing.expectEqual(@as(usize, 3), groups[0].tops_len);
    try testing.expectEqual(@as(i64, 1010), groups[0].key);
    try testing.expectEqual(@as(u32, 81), groups[0].width);
    try testing.expectEqual(@as(u32, 23), groups[0].height);
}
