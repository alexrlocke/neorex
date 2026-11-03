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
