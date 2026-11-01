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
splits: std.AutoArrayHashMapUnmanaged(i64, windows.Split) = .empty,

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
    var j = self.splits.count();
    while (j > 0) {
        j -= 1;
        if (grids.gridOf(self.splits.keys()[j]) == null) self.splits.swapRemoveAt(j);
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
    try self.splits.put(gpa, sp.win, sp);
}

/// Where Neovim put `win`; beside the current window if it didn't say.
pub fn splitOf(self: *const WindowChanges, win: i64) windows.Split {
    return self.splits.get(win) orelse .{ .win = win, .side_by_side = true, .before = false, .from = 0 };
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
    try testing.expectEqual(@as(usize, 1), changes.splits.count());
}
