//! Floats to show in a Rex floating pane. A group is an editor
//! float with every float hanging from it, as a picker builds its box,
//! input, list and preview; groups that touch, as Telescope's do, are one.
//!
//! A popup is drawn in the focused pane or in a Rex floating pane, never
//! anything in between. Floats anchored to a window or the cursor are the
//! pane's, and never form a group. An editor float goes in a floating pane
//! when something in its group has taken focus (a picker), or when nothing
//! in it can (which-key, notifications): those belong to the editor, which
//! is the whole Rex window, not to one pane. Being focusable isn't enough,
//! since completion menus are and are never entered. Those stay drawn in
//! their pane, beside what they complete.

const std = @import("std");
const Grids = @import("Grids.zig");

pub const max_groups = 8;
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
    /// A float in it has been Neovim's current window.
    entered: bool = false,
    /// Shown in a Rex floating pane: entered, or with nothing to focus. Kept
    /// through a merge, so a completion menu joining an unfocusable command
    /// line popup goes with it.
    native: bool = false,
    /// Where its editor floats sit, without those hanging from them: row,
    /// col, width, height. What the plugin placed, so what its floating
    /// pane is sized to, and where it starts. A footer or scrollbar hanging
    /// from them is inside it, as the plugin's own detail, even when it
    /// sticks out for a moment.
    box: [4]i64 = .{ 0, 0, 0, 0 },

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

    /// Shown together: groups that touch, one of them focusable, as
    /// Telescope's prompt, list, preview and their border windows, or a
    /// completion menu and the command line popup it completes. Unfocusable
    /// groups alone stay apart, so stacked notifications each keep their own.
    fn joins(a: Group, b: Group) bool {
        return (a.focusable or b.focusable) and a.touches(b);
    }

    fn merge(a: *Group, b: Group) void {
        a.unite(b.row, b.col, b.width, b.height);
        a.box = uniteBox(a.box, b.box);
        a.key = @min(a.key, b.key);
        a.focusable = a.focusable or b.focusable;
        a.entered = a.entered or b.entered;
        a.native = a.native or b.native;
        for (b.topGrids()) |t| if (a.tops_len < max_tops) {
            a.tops[a.tops_len] = t;
            a.tops_len += 1;
        };
    }

    /// Grows to cover the rect too.
    fn unite(g: *Group, row: i32, col: i32, width: u32, height: u32) void {
        if (g.width == 0) {
            g.row = row;
            g.col = col;
            g.width = width;
            g.height = height;
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

/// The box covering both, as `Group.box` holds them; an empty one adds nothing.
fn uniteBox(a: [4]i64, b: [4]i64) [4]i64 {
    if (a[2] == 0 or a[3] == 0) return b;
    if (b[2] == 0 or b[3] == 0) return a;
    const top = @min(a[0], b[0]);
    const left = @min(a[1], b[1]);
    return .{ top, left, @max(a[1] + a[2], b[1] + b[2]) - left, @max(a[0] + a[3], b[0] + b[3]) - top };
}

/// The groups to show natively: those with a float in `entered`, the
/// float windows that have been current, and those nothing in can focus.
pub fn find(grids: *const Grids, entered: []const i64, out: *[max_groups]Group) []Group {
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
            if (mid == id) g.box = .{ mp.row, mp.col, grid.width, grid.height };
            g.focusable = g.focusable or m.float.focusable;
            g.entered = g.entered or std.mem.indexOfScalar(i64, entered, m.win) != null;
        }
        if (g.width == 0) continue;
        g.native = g.entered or !g.focusable;
        all[n] = g;
        n += 1;
    }
    // groups shown together become one
    var merged = true;
    while (merged) {
        merged = false;
        outer: for (0..n) |i| for (i + 1..n) |j| {
            if (!all[i].joins(all[j])) continue;
            all[i].merge(all[j]);
            all[j] = all[n - 1];
            n -= 1;
            merged = true;
            break :outer;
        };
    }
    var k: usize = 0;
    for (all[0..n]) |g| {
        if (!g.native or k == out.len) continue;
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

test "a picker's floats are one group; focusable ones never entered aren't" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    // a picker as snacks makes it: an unfocusable box, input and list on it
    try addFloat(&gs, 3, 1002, 60, 20, .{ .focusable = false, .screen = .{ 4, 10 } });
    try addFloat(&gs, 4, 1004, 58, 1, .{ .anchor_grid = 3, .row = 1, .col = 1 });
    try addFloat(&gs, 5, 1005, 58, 16, .{ .anchor_grid = 3, .row = 3, .col = 1 });
    // a notification: unfocusable
    try addFloat(&gs, 6, 1006, 30, 6, .{ .focusable = false, .screen = .{ 0, 100 } });
    // a small focusable input: its own group
    try addFloat(&gs, 7, 1007, 30, 1, .{ .screen = .{ 40, 0 } });
    // the popup menu
    try addFloat(&gs, 8, -1, 30, 10, .{ .screen = .{ 40, 40 } });
    // a focusable float nobody went into
    try addFloat(&gs, 9, 1009, 20, 4, .{ .screen = .{ 30, 100 } });

    var buf: [max_groups]Group = undefined;
    const groups = find(&gs, &.{ 1004, 1007 }, &buf);
    // the picker, the notification (nothing in it can take focus), the input
    try testing.expectEqual(3, groups.len);
    try testing.expectEqualSlices(u32, &.{6}, groups[1].topGrids());
    try testing.expect(!groups[1].entered);
    try testing.expectEqualSlices(u32, &.{7}, groups[2].topGrids());
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
    // only the prompt takes focus
    const groups = find(&gs, &.{1010}, &buf);
    try testing.expectEqual(1, groups.len);
    try testing.expectEqual(@as(usize, 3), groups[0].tops_len);
    try testing.expectEqual(@as(i64, 1010), groups[0].key);
    try testing.expectEqual(@as(u32, 81), groups[0].width);
    try testing.expectEqual(@as(u32, 23), groups[0].height);
}

test "an editor completion menu nobody entered stays in the pane" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    // a menu opened relative to the editor, as nvim-cmp's: focusable, never entered
    try addFloat(&gs, 4, 1021, 30, 8, .{ .screen = .{ 7, 41 } });
    // and its scrollbar, on the menu
    try addFloat(&gs, 5, 1022, 1, 3, .{ .anchor_grid = 4, .col = 29 });
    var buf: [max_groups]Group = undefined;
    try testing.expectEqual(0, find(&gs, &.{}, &buf).len);
    // a float elsewhere was entered: still not these
    try testing.expectEqual(0, find(&gs, &.{1000}, &buf).len);
}

test "a completion menu goes with the command line popup it completes" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    // the command line popup, as noice makes it: unfocusable, so a floating pane
    try addFloat(&gs, 3, 1020, 62, 3, .{ .focusable = false, .screen = .{ 4, 40 } });
    // blink's menu right under it: focusable, never entered
    try addFloat(&gs, 4, 1021, 30, 8, .{ .screen = .{ 7, 41 } });
    var buf: [max_groups]Group = undefined;
    const groups = find(&gs, &.{}, &buf);
    try testing.expectEqual(1, groups.len);
    try testing.expectEqual(@as(usize, 2), groups[0].tops_len);
}

test "which-key, across the bottom of the editor, gets a floating pane" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    // as wide as the editor, which is the whole Rex window, not one pane
    try addFloat(&gs, 3, 1030, 200, 8, .{ .focusable = false, .screen = .{ 40, 0 } });
    var buf: [max_groups]Group = undefined;
    const groups = find(&gs, &.{}, &buf);
    try testing.expectEqual(1, groups.len);
    try testing.expectEqual(@as(u32, 200), groups[0].width);
    try testing.expect(!groups[0].focusable);
}

test "a float hanging out of an editor float isn't in its box" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    // which-key's box, just refitted, and its footer line not carried yet
    try addFloat(&gs, 3, 1080, 26, 15, .{ .focusable = false, .screen = .{ 7, 51 } });
    try addFloat(&gs, 4, 1081, 28, 1, .{ .focusable = false, .anchor_grid = 3, .row = 16, .col = 1 });
    var buf: [max_groups]Group = undefined;
    const groups = find(&gs, &.{}, &buf);
    try testing.expectEqual(1, groups.len);
    try testing.expectEqualSlices(i64, &.{ 7, 51, 26, 15 }, &groups[0].box);
    // the footer still counts for what's drawn
    try testing.expectEqual(@as(u32, 29), groups[0].width);
}

test "stacked notifications keep their own groups" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    try addFloat(&gs, 3, 1040, 30, 3, .{ .focusable = false, .screen = .{ 0, 100 } });
    try addFloat(&gs, 4, 1041, 30, 3, .{ .focusable = false, .screen = .{ 3, 100 } });
    var buf: [max_groups]Group = undefined;
    try testing.expectEqual(2, find(&gs, &.{}, &buf).len);
}

test "a picker's unfocusable border windows join it" {
    var gs: Grids = .{};
    defer gs.deinit(testing.allocator);
    // Telescope's prompt and the border window around it, both on the editor
    try addFloat(&gs, 3, 1070, 42, 5, .{ .focusable = false, .screen = .{ 1, 1 } });
    try addFloat(&gs, 4, 1071, 40, 3, .{ .screen = .{ 2, 2 } });
    var buf: [max_groups]Group = undefined;
    const groups = find(&gs, &.{1071}, &buf);
    try testing.expectEqual(1, groups.len);
    try testing.expectEqual(@as(usize, 2), groups[0].tops_len);
}
