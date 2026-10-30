//! The daemon's panes, found by id, Neovim window or Rex block. Pointers
//! into it are only good until a pane is added or removed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Pane = @import("Pane.zig");

const Panes = @This();

list: std.ArrayList(Pane) = .empty,
/// Never reused, so a stale token can't reach a newer pane. 0 is the startup pane.
next_id: u32 = 1,

/// Hangs up every pane still open.
pub fn deinit(self: *Panes, gpa: Allocator, io: std.Io) void {
    for (self.list.items) |*p| {
        if (p.closing == null) p.closing = .shutdown;
        p.deinit(gpa, io);
    }
    self.list.deinit(gpa);
    self.* = undefined;
}

/// Adds a pane that already has its id, such as the startup pane.
pub fn add(self: *Panes, gpa: Allocator, pane: Pane) !*Pane {
    try self.list.append(gpa, pane);
    return &self.list.items[self.list.items.len - 1];
}

/// Adds a pane for `win`, with the next id.
pub fn addForWindow(self: *Panes, gpa: Allocator, win: Pane.NeovimWindowHandle) !*Pane {
    const p = try self.add(gpa, Pane.fromNeovimWindow(self.next_id, win));
    self.next_id += 1;
    return p;
}

/// Hangs up pane `i` and forgets it. Set its `closing` first.
pub fn remove(self: *Panes, gpa: Allocator, io: std.Io, i: usize) void {
    var p = self.list.orderedRemove(i);
    p.deinit(gpa, io);
}

pub fn indexOf(self: *const Panes, id: u32) ?usize {
    for (self.list.items, 0..) |p, i| if (p.id == id) return i;
    return null;
}

pub fn byId(self: *const Panes, id: u32) ?*Pane {
    for (self.list.items) |*p| if (p.id == id) return p;
    return null;
}

pub fn byWin(self: *const Panes, win: i64) ?*Pane {
    if (win == 0) return null;
    for (self.list.items) |*p| if (p.neovim_window_handle == win) return p;
    return null;
}

pub fn byBlock(self: *const Panes, block: []const u8) ?*Pane {
    for (self.list.items) |*p| if (p.rex_block) |*b| if (std.mem.eql(u8, b, block)) return p;
    return null;
}

const testing = std.testing;

test "ids are never reused" {
    var panes: Panes = .{};
    defer panes.deinit(testing.allocator, testing.io);
    const a = (try panes.addForWindow(testing.allocator, 1000)).id;
    panes.remove(testing.allocator, testing.io, panes.indexOf(a).?);
    const b = (try panes.addForWindow(testing.allocator, 1001)).id;
    try testing.expect(b != a);
    try testing.expectEqual(null, panes.byId(a));
}

test "finds a pane by id, window or block" {
    var panes: Panes = .{};
    defer panes.deinit(testing.allocator, testing.io);
    const block = try Pane.rexBlock("block:01a1891d-7ec1-77ef-b35e-a77e39f0e0e1");
    const p = try panes.addForWindow(testing.allocator, 1000);
    p.rex_block = block;
    const id = p.id;
    try testing.expectEqual(id, panes.byId(id).?.id);
    try testing.expectEqual(id, panes.byWin(1000).?.id);
    try testing.expectEqual(id, panes.byBlock(&block).?.id);
    try testing.expectEqual(null, panes.byWin(0));
    try testing.expectEqual(null, panes.byWin(1001));
}
