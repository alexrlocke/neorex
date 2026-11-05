//! Where Rex last put tool windows' panes, so the next one of a kind opens
//! there. Rex owns the layout: Neovim only says what kind of window a pane
//! shows (nvim-tree, help, quickfix, grug-far), never where it goes or how
//! big it is. A window showing a file has no kind and opens where Neovim
//! put it, splitting evenly. Kept for the daemon's life.
//!
//! A kind remembers the tool pane it sat directly beside, if any: Grug FAR
//! stacked above nvim-tree reopens above nvim-tree, with the same split.
//! Failing that, its share of the Rex window, used where Neovim put it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = @import("../nvim/windows.zig");

const PanePlaces = @This();

/// Each tool window's kind, as the Lua last said; owned. Files aren't here.
kinds: std.AutoArrayHashMapUnmanaged(i64, []u8) = .empty,
/// What each kind remembers; keys owned.
places: std.StringArrayHashMapUnmanaged(Place) = .empty,

pub const Direction = enum {
    /// Side by side.
    horizontal,
    /// One above the other.
    vertical,
};

pub const Beside = struct {
    /// The tool pane's kind it sat beside; owned once kept.
    kind: []const u8,
    direction: Direction,
    /// Left of or above it.
    before: bool,
    /// Rex's ratio for their split: the before part's share.
    ratio: f64,
};

pub const Place = struct {
    /// Its width and height as fractions of the Rex window.
    size: ?[2]f64 = null,
    beside: ?Beside = null,
};

pub fn deinit(self: *PanePlaces, gpa: Allocator) void {
    for (self.kinds.values()) |k| gpa.free(k);
    self.kinds.deinit(gpa);
    for (self.places.keys(), self.places.values()) |k, p| {
        gpa.free(k);
        if (p.beside) |b| gpa.free(b.kind);
    }
    self.places.deinit(gpa);
    self.* = undefined;
}

/// Window `k.win` is now of kind `k.name`; empty for a file.
pub fn setKind(self: *PanePlaces, gpa: Allocator, k: windows.Kind) !void {
    if (k.name.len == 0) return self.forget(gpa, k.win);
    if (self.kinds.get(k.win)) |old| if (std.mem.eql(u8, old, k.name)) return;
    const name = try gpa.dupe(u8, k.name);
    if (try self.kinds.fetchPut(gpa, k.win, name)) |old| gpa.free(old.value);
}

/// Window `win` closed, or shows a file now.
pub fn forget(self: *PanePlaces, gpa: Allocator, win: i64) void {
    if (self.kinds.fetchSwapRemove(win)) |old| gpa.free(old.value);
}

/// A tool window's kind, or null for a file.
pub fn kindOf(self: *const PanePlaces, win: i64) ?[]const u8 {
    return self.kinds.get(win);
}

/// Where a pane of `win`'s kind last was, if anywhere.
pub fn placeFor(self: *const PanePlaces, win: i64) ?Place {
    return self.places.get(self.kindOf(win) orelse return null);
}

fn placeOf(self: *PanePlaces, gpa: Allocator, kind: []const u8) !*Place {
    const entry = try self.places.getOrPut(gpa, kind);
    if (!entry.found_existing) {
        entry.key_ptr.* = gpa.dupe(u8, kind) catch |err| {
            self.places.swapRemoveAt(entry.index);
            return err;
        };
        entry.value_ptr.* = .{};
    }
    return entry.value_ptr;
}

/// Rex laid out the pane showing `win` at `w` x `h` of its window.
pub fn recordSize(self: *PanePlaces, gpa: Allocator, win: i64, w: f64, h: f64) !void {
    const kind = self.kindOf(win) orelse return;
    (try self.placeOf(gpa, kind)).size = .{ w, h };
}

/// Rex laid out the pane showing `win` directly beside a tool pane: `b`,
/// whose kind is copied. Null: beside nothing to remember.
pub fn recordBeside(self: *PanePlaces, gpa: Allocator, win: i64, b: ?Beside) !void {
    const kind = self.kindOf(win) orelse return;
    const p = try self.placeOf(gpa, kind);
    const kept: ?Beside = if (b) |new| blk: {
        var copy = new;
        copy.kind = try gpa.dupe(u8, new.kind);
        break :blk copy;
    } else null;
    if (p.beside) |old| gpa.free(old.kind);
    p.beside = kept;
}

/// A pane in Rex's layout, and the split it's directly in, if any.
pub const Leaf = struct {
    /// Points into the view: valid until the next read.
    block: []const u8,
    rect: [4]f64,
    split: ?Split,

    pub const Split = struct {
        direction: Direction,
        /// This pane is the before part.
        before: bool,
        ratio: f64,
        /// The other part, if it's one pane, not a split.
        sibling: ?[]const u8,
    };
};

/// The panes under layout node `node`, as Rex's view gives it, into `out`.
pub fn leaves(node: std.json.Value, out: []Leaf) []Leaf {
    var n: usize = 0;
    walk(node, null, out, &n);
    return out[0..n];
}

fn walk(node: std.json.Value, split: ?Leaf.Split, out: []Leaf, n: *usize) void {
    if (node != .object) return;
    const o = node.object;
    if (str(o.get("block_id"))) |block| {
        if (n.* == out.len) return;
        out[n.*] = .{ .block = block, .rect = rect4(o.get("rect")) orelse return, .split = split };
        n.* += 1;
        return;
    }
    const s = o.get("split") orelse return;
    if (s != .object) return;
    const direction = std.meta.stringToEnum(Direction, str(s.object.get("direction")) orelse return) orelse return;
    const ratio = num(s.object.get("ratio")) orelse 0.5;
    const before = s.object.get("before") orelse return;
    const after = s.object.get("after") orelse return;
    walk(before, .{ .direction = direction, .before = true, .ratio = ratio, .sibling = blockOf(after) }, out, n);
    walk(after, .{ .direction = direction, .before = false, .ratio = ratio, .sibling = blockOf(before) }, out, n);
}

fn blockOf(node: std.json.Value) ?[]const u8 {
    if (node != .object) return null;
    return str(node.object.get("block_id"));
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const s = v orelse return null;
    return if (s == .string) s.string else null;
}

fn num(v: ?std.json.Value) ?f64 {
    return switch (v orelse return null) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn rect4(v: ?std.json.Value) ?[4]f64 {
    const a = v orelse return null;
    if (a != .array or a.array.items.len != 4) return null;
    var out: [4]f64 = undefined;
    for (a.array.items, &out) |x, *o| o.* = num(x) orelse return null;
    return out;
}

const testing = std.testing;

test "a tool window opens at the size its kind last had" {
    var s: PanePlaces = .{};
    defer s.deinit(testing.allocator);
    try s.setKind(testing.allocator, .{ .win = 1000, .name = "NvimTree" });
    try testing.expectEqual(null, s.placeFor(1000));
    try s.recordSize(testing.allocator, 1000, 0.25, 1);
    try s.recordSize(testing.allocator, 1000, 0.2, 1);
    s.forget(testing.allocator, 1000);

    try s.setKind(testing.allocator, .{ .win = 1001, .name = "NvimTree" });
    try testing.expectEqual([2]f64{ 0.2, 1 }, s.placeFor(1001).?.size.?);
    // another kind starts afresh
    try s.setKind(testing.allocator, .{ .win = 1002, .name = "help" });
    try testing.expectEqual(null, s.placeFor(1002));
}

test "files have no kind and aren't remembered" {
    var s: PanePlaces = .{};
    defer s.deinit(testing.allocator);
    try s.setKind(testing.allocator, .{ .win = 1000, .name = "qf" });
    // the window now shows a file
    try s.setKind(testing.allocator, .{ .win = 1000, .name = "" });
    try s.recordSize(testing.allocator, 1000, 0.2, 1);
    try s.recordBeside(testing.allocator, 1000, .{ .kind = "NvimTree", .direction = .vertical, .before = true, .ratio = 0.4 });
    try testing.expectEqual(null, s.placeFor(1000));
    try testing.expectEqual(@as(usize, 0), s.places.count());
}

test "a kind remembers the tool pane it sat beside, until it's beside none" {
    var s: PanePlaces = .{};
    defer s.deinit(testing.allocator);
    try s.setKind(testing.allocator, .{ .win = 1000, .name = "grug-far" });
    var tree = [_]u8{ 'N', 'v', 'i', 'm', 'T', 'r', 'e', 'e' };
    try s.recordBeside(testing.allocator, 1000, .{ .kind = &tree, .direction = .vertical, .before = true, .ratio = 0.4 });
    // kept as a copy
    tree[0] = 'x';
    const b = s.placeFor(1000).?.beside.?;
    try testing.expectEqualStrings("NvimTree", b.kind);
    try testing.expectEqual(PanePlaces.Direction.vertical, b.direction);
    try testing.expect(b.before);
    try testing.expectEqual(@as(f64, 0.4), b.ratio);
    try s.recordBeside(testing.allocator, 1000, null);
    try testing.expectEqual(null, s.placeFor(1000).?.beside);
}

test "reads each pane and the split it's in from Rex's layout" {
    // a probe of Rex's session.view: one pane on the right; on the left, B above C
    const json =
        \\{"rect":[0,0,1,1],"split":{"split_id":"s1","direction":"horizontal","ratio":0.3,
        \\ "before":{"rect":[0,0,0.3,1],"split":{"split_id":"s2","direction":"vertical","ratio":0.4,
        \\   "before":{"rect":[0,0,0.3,0.4],"block_id":"B"},
        \\   "after":{"rect":[0,0.4,0.3,0.6],"block_id":"C"}}},
        \\ "after":{"rect":[0.3,0,0.7,1],"block_id":"A"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    var buf: [8]Leaf = undefined;
    const got = leaves(parsed.value, &buf);
    try testing.expectEqual(@as(usize, 3), got.len);

    try testing.expectEqualStrings("B", got[0].block);
    const b = got[0].split.?;
    try testing.expectEqual(Direction.vertical, b.direction);
    try testing.expect(b.before);
    try testing.expectEqual(@as(f64, 0.4), b.ratio);
    try testing.expectEqualStrings("C", b.sibling.?);
    try testing.expectEqual([4]f64{ 0, 0, 0.3, 0.4 }, got[0].rect);

    try testing.expectEqualStrings("C", got[1].block);
    try testing.expect(!got[1].split.?.before);
    try testing.expectEqualStrings("B", got[1].split.?.sibling.?);

    // beside a split, not a pane
    try testing.expectEqualStrings("A", got[2].block);
    try testing.expectEqual(Direction.horizontal, got[2].split.?.direction);
    try testing.expectEqual(null, got[2].split.?.sibling);
}

test "a lone pane is in no split" {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"rect":[0,0,1,1],"block_id":"A"}
    , .{});
    defer parsed.deinit();
    var buf: [8]Leaf = undefined;
    const got = leaves(parsed.value, &buf);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(null, got[0].split);
}
