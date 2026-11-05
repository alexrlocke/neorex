//! Sizes for panes and their windows, including guesses for new splits
//! until their terminals say how big they are.

const std = @import("std");
const Pane = @import("Pane.zig");

/// A new Rex terminal's size, cols x rows, until the app lays it out.
pub const rex_default_size = [2]u32{ 80, 24 };

/// A guess at a new split's terminal size, cols x rows: half of `from`,
/// the pane it splits, across if `side_by_side`, else down.
pub fn newPaneSize(from: ?*const Pane, side_by_side: bool) [2]u32 {
    const p = from orelse return rex_default_size;
    const s = p.terminal_surface orelse return rex_default_size;
    const cols = @max(s.view.cols, 1);
    const rows = @max(s.view.rows, 2);
    if (side_by_side) return .{ @max(cols / 2, 1), rows };
    return .{ cols, @max(rows / 2, 2) };
}

/// A guess at a new split's window size: its pane's guess, less the rows
/// kept for the command line.
pub fn newWindowSize(from: ?*const Pane, side_by_side: bool, cmd_rows: u32) [2]u32 {
    const size = newPaneSize(from, side_by_side);
    return .{ size[0], @max(size[1] -| cmd_rows, 1) };
}

/// The window size pane `p` holds. No terminal yet: the smallest window, as
/// Neovim allows.
pub fn windowSize(p: *const Pane, cmd_rows: u32) [2]u32 {
    return if (p.terminal_surface) |s| s.windowSize(cmd_rows) else .{ 1, 1 };
}

/// Where a fixed-size window (a sidebar, the quickfix list) opens: the part
/// of the Rex window it opens beside, in cells, and the share of it the
/// window takes across the split.
pub const Fixed = struct {
    /// The space it opens beside, cols x rows.
    space: [2]u32,
    share: f64,
};

/// A fixed-size window `cells` across its split (columns if `side_by_side`, else rows
/// with its statusline) opening beside the part of the window at `rect`,
/// fractions of a `window` cells big. A pane keeps `cmd_rows` for the command
/// line under its window, so one below needs those too. Kept clear of
/// the edges so neither side vanishes.
pub fn fixed(window: [2]u32, rect: [4]f64, cells: u32, side_by_side: bool, cmd_rows: u32) Fixed {
    const space = [2]u32{ @max(scaled(window[0], rect[2]), 1), @max(scaled(window[1], rect[3]), 1) };
    const want = if (side_by_side) cells else cells + cmd_rows;
    const across = if (side_by_side) space[0] else space[1];
    const share = @as(f64, @floatFromInt(want)) / @as(f64, @floatFromInt(across));
    return .{ .space = space, .share = std.math.clamp(share, 0.05, 0.95) };
}

/// A guess at a fixed-size window's terminal size, cols x rows: its share of the space
/// across the split, all of it along.
pub fn fixedPaneSize(fx: Fixed, side_by_side: bool) [2]u32 {
    if (side_by_side) return .{ @max(scaled(fx.space[0], fx.share), 1), @max(fx.space[1], 2) };
    return .{ @max(fx.space[0], 1), @max(scaled(fx.space[1], fx.share), 2) };
}

/// Rex's `ratio` for a new split whose new pane takes `share`: the part
/// before the border, which is the new pane only if it goes `before`.
pub fn splitRatio(share: f64, before: bool) f64 {
    return if (before) share else 1 - share;
}

fn scaled(n: u32, f: f64) u32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(n)) * f));
}

const testing = std.testing;
const Surface = @import("Surface.zig");

/// A surface that only has a size: the sizes only read `view`.
fn sized(cols: u32, rows: u32) Surface {
    return .{ .helper_socket = undefined, .terminal = undefined, .view = .init(cols, rows) };
}

test "a new split is half the pane it splits" {
    var s = sized(80, 24);
    const from: Pane = .{ .id = 1, .terminal_surface = &s };
    try testing.expectEqual([2]u32{ 40, 24 }, newPaneSize(&from, true));
    try testing.expectEqual([2]u32{ 80, 12 }, newPaneSize(&from, false));
}

test "without a pane to split, or its terminal, a new split is Rex's default" {
    const no_terminal: Pane = .{ .id = 1 };
    try testing.expectEqual(rex_default_size, newPaneSize(null, true));
    try testing.expectEqual(rex_default_size, newPaneSize(&no_terminal, false));
}

test "a split of a tiny pane keeps a column and two rows" {
    var s = sized(1, 1);
    const from: Pane = .{ .id = 1, .terminal_surface = &s };
    try testing.expectEqual([2]u32{ 1, 2 }, newPaneSize(&from, true));
    try testing.expectEqual([2]u32{ 1, 2 }, newPaneSize(&from, false));
}

test "a new window leaves the command line's rows, and keeps one" {
    var s = sized(80, 24);
    const from: Pane = .{ .id = 1, .terminal_surface = &s };
    try testing.expectEqual([2]u32{ 80, 11 }, newWindowSize(&from, false, 1));
    try testing.expectEqual([2]u32{ 40, 24 }, newWindowSize(&from, true, 0));
    try testing.expectEqual([2]u32{ 80, 1 }, newWindowSize(&from, false, 20));
}

test "a pane's window, with and without its terminal" {
    var s = sized(80, 24);
    const with: Pane = .{ .id = 1, .terminal_surface = &s };
    const without: Pane = .{ .id = 2 };
    try testing.expectEqual([2]u32{ 80, 23 }, windowSize(&with, 1));
    try testing.expectEqual([2]u32{ 1, 1 }, windowSize(&without, 1));
}

test "a fixed-size window takes its cells of the space it opens beside" {
    // 40 columns at the edge of a 200-column window
    const whole = fixed(.{ 200, 50 }, .{ 0, 0, 1, 1 }, 40, true, 1);
    try testing.expectEqual([2]u32{ 200, 50 }, whole.space);
    try testing.expectEqual(@as(f64, 0.2), whole.share);
    try testing.expectEqual([2]u32{ 40, 50 }, fixedPaneSize(whole, true));
    // beside our panes, which take 0.6 of it: 40 of 120 columns
    const part = fixed(.{ 200, 50 }, .{ 0.4, 0, 0.6, 1 }, 40, true, 1);
    try testing.expectEqual([2]u32{ 120, 50 }, part.space);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), part.share, 1e-9);
    try testing.expectEqual([2]u32{ 40, 50 }, fixedPaneSize(part, true));
}

test "a fixed-size window below keeps the command line's rows" {
    // 9 rows with its statusline, and 1 for the command line, of 50
    const below = fixed(.{ 200, 50 }, .{ 0, 0, 1, 1 }, 9, false, 1);
    try testing.expectEqual(@as(f64, 0.2), below.share);
    try testing.expectEqual([2]u32{ 200, 10 }, fixedPaneSize(below, false));
    try testing.expectEqual(@as(f64, 0.18), fixed(.{ 200, 50 }, .{ 0, 0, 1, 1 }, 9, false, 0).share);
}

test "a fixed-size window's share stays clear of the edges" {
    try testing.expectEqual(@as(f64, 0.05), fixed(.{ 200, 50 }, .{ 0, 0, 1, 1 }, 1, true, 0).share);
    try testing.expectEqual(@as(f64, 0.95), fixed(.{ 200, 50 }, .{ 0, 0, 1, 1 }, 500, true, 0).share);
    // an empty rect still has a cell
    try testing.expectEqual([2]u32{ 1, 1 }, fixed(.{ 200, 50 }, .{ 0, 0, 0, 0 }, 40, true, 0).space);
}

test "Rex's ratio is the part before the border" {
    try testing.expectEqual(@as(f64, 0.2), splitRatio(0.2, true));
    try testing.expectEqual(@as(f64, 0.8), splitRatio(0.2, false));
}
