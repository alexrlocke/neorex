//! Neovim windows partway through a change: asked to become external,
//! closing, reopening, or just split. `Daemon.reconcile` asks it what to do.

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = @import("../nvim/windows.zig");
const Grids = @import("../screen/Grids.zig");

const WindowChanges = @This();

/// Windows asked to become external and not seen external since.
asked: std.AutoArrayHashMapUnmanaged(i64, void) = .empty,
/// Windows we asked Neovim to close because their pane went away.
closing: std.AutoArrayHashMapUnmanaged(i64, void) = .empty,
/// Windows closing to reopen (`:close` on the last one): their panes wait
/// for the new window instead of hanging up.
reopening: std.AutoArrayHashMapUnmanaged(i64, void) = .empty,
/// New windows without panes yet, and where Neovim put them.
splits: std.AutoArrayHashMapUnmanaged(i64, PendingSplit) = .empty,

const PendingSplit = struct {
    split: windows.Split,
    /// Whether Neovim has drawn the window yet. Some take a few flushes to
    /// appear (neo-tree's), so a split is kept until its window has been
    /// drawn and then gone.
    drawn: bool = false,
};

pub fn deinit(self: *WindowChanges, gpa: Allocator) void {
    self.asked.deinit(gpa);
    self.closing.deinit(gpa);
    self.reopening.deinit(gpa);
    self.splits.deinit(gpa);
    self.* = undefined;
}

/// Forgets windows Neovim no longer has.
pub fn forgetGone(self: *WindowChanges, grids: *const Grids) void {
    for ([_]*std.AutoArrayHashMapUnmanaged(i64, void){ &self.asked, &self.closing, &self.reopening }) |set| {
        var j = set.count();
        while (j > 0) {
            j -= 1;
            if (grids.gridOf(set.keys()[j]) == null) set.swapRemoveAt(j);
        }
    }
    // one that's never drawn is kept until the daemon ends; that's rare
    var j = self.splits.count();
    while (j > 0) {
        j -= 1;
        const pending = &self.splits.values()[j];
        if (grids.gridOf(self.splits.keys()[j]) != null) {
            pending.drawn = true;
        } else if (pending.drawn) {
            self.splits.swapRemoveAt(j);
        }
    }
}

/// True the first time for `win`: ask Neovim to make it external.
pub fn shouldAdopt(self: *WindowChanges, gpa: Allocator, win: i64) !bool {
    if (self.asked.contains(win)) return false;
    try self.asked.put(gpa, win, {});
    return true;
}

/// `win` is external now, so it's no longer waiting on our request.
pub fn becameExternal(self: *WindowChanges, win: i64) void {
    _ = self.asked.swapRemove(win);
}

pub fn markClosing(self: *WindowChanges, gpa: Allocator, win: i64) !void {
    try self.closing.put(gpa, win, {});
}

pub fn isClosing(self: *const WindowChanges, win: i64) bool {
    return self.closing.contains(win);
}

pub fn markReopening(self: *WindowChanges, gpa: Allocator, win: i64) !void {
    try self.reopening.put(gpa, win, {});
}

/// True if `win` was closing to reopen; forgets it.
pub fn takeReopening(self: *WindowChanges, win: i64) bool {
    return self.reopening.swapRemove(win);
}

pub fn noteSplit(self: *WindowChanges, gpa: Allocator, sp: windows.Split) !void {
    try self.splits.put(gpa, sp.win, .{ .split = sp });
}

/// `win` has a fixed size, if it's still waiting for a pane.
pub fn noteFixed(self: *WindowChanges, fx: windows.Fixed) void {
    if (self.splits.getPtr(fx.win)) |pending| pending.split.fixed_cells = fx.cells;
}

/// Where Neovim put `win`; beside the current window if it didn't say.
pub fn splitOf(self: *const WindowChanges, win: i64) windows.Split {
    return if (self.splits.get(win)) |pending| pending.split else .{ .win = win, .side_by_side = true, .before = false, .from = 0 };
}

pub fn forgetSplit(self: *WindowChanges, win: i64) void {
    _ = self.splits.swapRemove(win);
}

const testing = std.testing;

test "asks to adopt a window once, until it's external" {
    var changes: WindowChanges = .{};
    defer changes.deinit(testing.allocator);
    try testing.expect(try changes.shouldAdopt(testing.allocator, 1000));
    try testing.expect(!try changes.shouldAdopt(testing.allocator, 1000));
    changes.becameExternal(1000);
    try testing.expect(try changes.shouldAdopt(testing.allocator, 1000));
}

test "a reopening window is taken once" {
    var changes: WindowChanges = .{};
    defer changes.deinit(testing.allocator);
    try changes.markReopening(testing.allocator, 1000);
    try testing.expect(changes.takeReopening(1000));
    try testing.expect(!changes.takeReopening(1000));
}

test "split defaults to beside the current window" {
    var changes: WindowChanges = .{};
    defer changes.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 0), changes.splitOf(1000).from);
    try changes.noteSplit(testing.allocator, .{ .win = 1000, .side_by_side = false, .before = true, .from = 999 });
    try testing.expectEqual(@as(i64, 999), changes.splitOf(1000).from);
    changes.forgetSplit(1000);
    try testing.expectEqual(@as(i64, 0), changes.splitOf(1000).from);
}

test "a split remembers its fixed size" {
    var changes: WindowChanges = .{};
    defer changes.deinit(testing.allocator);
    // no split noted: nothing to keep it on
    changes.noteFixed(.{ .win = 1000, .cells = 30 });
    try testing.expectEqual(@as(u32, 0), changes.splitOf(1000).fixed_cells);
    try changes.noteSplit(testing.allocator, .{ .win = 1000, .side_by_side = true, .before = true, .from = 999 });
    changes.noteFixed(.{ .win = 1000, .cells = 30 });
    try testing.expectEqual(@as(u32, 30), changes.splitOf(1000).fixed_cells);
}

test "forgets windows Neovim no longer has" {
    var grids: Grids = .{};
    defer grids.deinit(testing.allocator);
    try grids.wins.put(testing.allocator, 2, .{ .win = 1000, .kind = .external });
    var changes: WindowChanges = .{};
    defer changes.deinit(testing.allocator);
    for ([_]i64{ 1000, 1001 }) |win| {
        _ = try changes.shouldAdopt(testing.allocator, win);
        try changes.markClosing(testing.allocator, win);
        try changes.markReopening(testing.allocator, win);
        try changes.noteSplit(testing.allocator, .{ .win = win, .side_by_side = true, .before = false, .from = 0 });
    }
    changes.forgetGone(&grids);
    try testing.expect(changes.isClosing(1000));
    try testing.expect(!changes.isClosing(1001));
    try testing.expect(!try changes.shouldAdopt(testing.allocator, 1000));
    try testing.expect(changes.takeReopening(1000));
    try testing.expect(!changes.takeReopening(1001));
}

test "a split is kept until its window has been drawn and gone" {
    var grids: Grids = .{};
    defer grids.deinit(testing.allocator);
    var changes: WindowChanges = .{};
    defer changes.deinit(testing.allocator);
    try changes.noteSplit(testing.allocator, .{ .win = 1000, .side_by_side = true, .before = true, .from = 0 });
    // not drawn yet, as neo-tree's isn't on its first flush
    changes.forgetGone(&grids);
    try testing.expect(changes.splitOf(1000).before);
    // drawn
    try grids.wins.put(testing.allocator, 2, .{ .win = 1000, .kind = .ordinary });
    changes.forgetGone(&grids);
    try testing.expect(changes.splitOf(1000).before);
    // gone
    _ = grids.wins.swapRemove(2);
    changes.forgetGone(&grids);
    try testing.expect(!changes.splitOf(1000).before);
}
