//! The share of the Rex window that tool windows' panes were given, so the
//! next one of a kind opens at it. Rex owns the layout: Neovim only says
//! what kind of window a pane shows (nvim-tree, help, quickfix), never how
//! big it should be. A window showing a file has no kind and splits evenly.
//! Kept for the daemon's life.

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = @import("../nvim/windows.zig");

const PaneSizes = @This();

/// Each tool window's kind, as the Lua last said; owned. Files aren't here.
kinds: std.AutoArrayHashMapUnmanaged(i64, []u8) = .empty,
/// Each kind's pane width and height as fractions of the Rex window, as
/// Rex last laid it out; keys owned.
sizes: std.StringArrayHashMapUnmanaged([2]f64) = .empty,

pub fn deinit(self: *PaneSizes, gpa: Allocator) void {
    for (self.kinds.values()) |k| gpa.free(k);
    self.kinds.deinit(gpa);
    for (self.sizes.keys()) |k| gpa.free(k);
    self.sizes.deinit(gpa);
    self.* = undefined;
}

/// Window `k.win` is now of kind `k.name`; empty for a file.
pub fn setKind(self: *PaneSizes, gpa: Allocator, k: windows.Kind) !void {
    if (k.name.len == 0) return self.forget(gpa, k.win);
    if (self.kinds.get(k.win)) |old| if (std.mem.eql(u8, old, k.name)) return;
    const name = try gpa.dupe(u8, k.name);
    if (try self.kinds.fetchPut(gpa, k.win, name)) |old| gpa.free(old.value);
}

/// Window `win` closed, or shows a file now.
pub fn forget(self: *PaneSizes, gpa: Allocator, win: i64) void {
    if (self.kinds.fetchSwapRemove(win)) |old| gpa.free(old.value);
}

/// Rex laid out the pane showing `win` at `w` x `h` of its window.
pub fn record(self: *PaneSizes, gpa: Allocator, win: i64, w: f64, h: f64) !void {
    const kind = self.kinds.get(win) orelse return;
    const entry = try self.sizes.getOrPut(gpa, kind);
    if (!entry.found_existing) {
        entry.key_ptr.* = gpa.dupe(u8, kind) catch |err| {
            self.sizes.swapRemoveAt(entry.index);
            return err;
        };
    }
    entry.value_ptr.* = .{ w, h };
}

/// The share of its window Rex last gave a pane of `win`'s kind, width
/// and height, if any.
pub fn sizeFor(self: *const PaneSizes, win: i64) ?[2]f64 {
    return self.sizes.get(self.kinds.get(win) orelse return null);
}

const testing = std.testing;

test "a tool window opens at the size its kind last had" {
    var s: PaneSizes = .{};
    defer s.deinit(testing.allocator);
    try s.setKind(testing.allocator, .{ .win = 1000, .name = "NvimTree" });
    try testing.expectEqual(null, s.sizeFor(1000));
    try s.record(testing.allocator, 1000, 0.25, 1);
    try s.record(testing.allocator, 1000, 0.2, 1);
    s.forget(testing.allocator, 1000);

    try s.setKind(testing.allocator, .{ .win = 1001, .name = "NvimTree" });
    try testing.expectEqual([2]f64{ 0.2, 1 }, s.sizeFor(1001).?);
    // another kind starts afresh
    try s.setKind(testing.allocator, .{ .win = 1002, .name = "help" });
    try testing.expectEqual(null, s.sizeFor(1002));
}

test "files have no kind and aren't remembered" {
    var s: PaneSizes = .{};
    defer s.deinit(testing.allocator);
    try s.setKind(testing.allocator, .{ .win = 1000, .name = "qf" });
    // the window now shows a file
    try s.setKind(testing.allocator, .{ .win = 1000, .name = "" });
    try s.record(testing.allocator, 1000, 0.2, 1);
    try testing.expectEqual(null, s.sizeFor(1000));
    try testing.expectEqual(@as(usize, 0), s.sizes.count());
}
