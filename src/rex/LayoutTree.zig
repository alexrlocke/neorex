//! A mirror of one Rex window's tiled layout, in the shape `session.view`
//! gives it: a binary tree where each node is either a block or a split of
//! two nodes, and every node has its rect. Read again from each view, so
//! Rex's layout is the only one there is; nothing here is neorex's own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Client = @import("Client.zig");
const ids = @import("ids.zig");
const layout = @import("layout.zig");

const LayoutTree = @This();

/// Where a node sits, as fractions of the window: x, y, w, h.
pub const Rect = layout.Rect;

/// A node's place in `nodes`.
pub const Index = u32;

/// How a split divides its space, as Rex names it.
pub const Direction = enum {
    /// `before` on the left, `after` on the right.
    horizontal,
    /// `before` above `after`.
    vertical,
};

pub const Side = enum { before, after };

pub const Node = struct {
    rect: Rect,
    kind: union(enum) {
        /// Null when Rex sends no id.
        block: ?ids.Block,
        split: Split,
    },
};

pub const Split = struct {
    /// Null when Rex sends no id.
    id: ?ids.Split,
    direction: Direction,
    /// The fraction of the split's space that `before` gets.
    ratio: f64,
    before: Index,
    after: Index,
};

window_id: ?[43]u8 = null,
/// The block zoomed to fill the window, if any. The layout keeps its sizes.
zoomed_block: ?ids.Block = null,
/// The tiled layer's id.
layer_id: ?ids.Layer = null,
/// The tiled layer's layout. Null when the layer is empty, or when the
/// view's layout was malformed.
root: ?Index = null,
nodes: std.ArrayList(Node) = .empty,

pub fn deinit(self: *LayoutTree, gpa: Allocator) void {
    self.nodes.deinit(gpa);
    self.* = undefined;
}

/// Replaces the mirror with window `window` of a session view. A malformed
/// layout leaves the tree empty.
pub fn read(self: *LayoutTree, gpa: Allocator, window: Value) Allocator.Error!void {
    self.nodes.clearRetainingCapacity();
    self.root = null;
    self.window_id = fixed(43, Client.getStr(window, "window_id"));
    self.zoomed_block = fixed(42, Client.getStr(window, "zoomed_block_id"));
    self.layer_id = null;
    const layer = tiledLayer(window) orelse return;
    self.layer_id = fixed(42, Client.getStr(layer, "layer_id"));
    const top = Client.get(layer, "layout") orelse return;
    if (top == .null) return;
    self.root = self.add(gpa, top) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => {
            self.nodes.clearRetainingCapacity();
            return;
        },
    };
}

/// The tiled layer: Rex lists it first, and names its kind.
fn tiledLayer(window: Value) ?Value {
    const layers = Client.get(window, "layers") orelse return null;
    if (layers != .array) return null;
    for (layers.array.items) |l| {
        if (std.mem.eql(u8, Client.getStr(l, "kind") orelse "", "tiled")) return l;
    }
    return null;
}

/// Adds layout node `v` and everything under it, parents first.
fn add(self: *LayoutTree, gpa: Allocator, v: Value) (Allocator.Error || error{Malformed})!Index {
    if (v != .object) return error.Malformed;
    const rect = layout.asRect(v.object.get("rect")) orelse return error.Malformed;
    const at: Index = @intCast(self.nodes.items.len);
    try self.nodes.append(gpa, .{ .rect = rect, .kind = .{ .block = null } });
    const sp = v.object.get("split") orelse Value.null;
    if (sp == .null) {
        self.nodes.items[at].kind = .{ .block = fixed(42, Client.str(v.object.get("block_id"))) };
        return at;
    }
    if (sp != .object) return error.Malformed;
    const ratio = layout.asNumber(sp.object.get("ratio") orelse return error.Malformed) orelse return error.Malformed;
    const before = try self.add(gpa, sp.object.get("before") orelse return error.Malformed);
    const after = try self.add(gpa, sp.object.get("after") orelse return error.Malformed);
    self.nodes.items[at].kind = .{ .split = .{
        .id = fixed(42, Client.str(sp.object.get("split_id"))),
        // Rex: draw a direction you don't know as horizontal
        .direction = Client.getEnum(Direction, sp, "direction") orelse .horizontal,
        .ratio = ratio,
        .before = before,
        .after = after,
    } };
    return at;
}

/// `id` as a fixed-size id, or null if it's missing or the wrong length.
fn fixed(comptime n: usize, id: ?[]const u8) ?[n]u8 {
    const s = id orelse return null;
    if (s.len != n) return null;
    return s[0..n].*;
}

pub fn node(self: *const LayoutTree, i: Index) *const Node {
    return &self.nodes.items[i];
}

/// Node `i`'s id, a block's or a split's: what `new_split` takes as an anchor.
pub fn idOf(self: *const LayoutTree, i: Index) ?[]const u8 {
    return switch (self.node(i).kind) {
        .block => |*b| if (b.* != null) &b.*.? else null,
        .split => |*s| if (s.id != null) &s.id.? else null,
    };
}

// lookups

/// The smallest node holding every block that `ours.isOurs(block_id)`
/// claims, or null if the tree holds none. A fixed-size window opens beside it, at the
/// edge of our blocks, leaving Rex blocks that aren't ours outside.
pub fn edgeAround(self: *const LayoutTree, ours: anytype) ?Index {
    var at = self.root orelse return null;
    const total = self.count(at, ours);
    if (total == 0) return null;
    descend: while (true) {
        const sp = switch (self.node(at).kind) {
            .split => |s| s,
            .block => break,
        };
        for ([_]Index{ sp.before, sp.after }) |child| {
            if (self.count(child, ours) == total) {
                at = child;
                continue :descend;
            }
        }
        break;
    }
    return at;
}

fn count(self: *const LayoutTree, i: Index, ours: anytype) usize {
    return switch (self.node(i).kind) {
        .block => |b| if (b) |id| @intFromBool(ours.isOurs(&id)) else 0,
        .split => |s| self.count(s.before, ours) + self.count(s.after, ours),
    };
}

/// A border beside a block: the split whose ratio moves, and a block on each
/// side of it, as `resize_pane` takes them.
pub const Border = struct {
    split: Index,
    before_block: ids.Block,
    after_block: ids.Block,
    /// Which side of the border the block asked about is on.
    side: Side,
};

/// The border beside `block` across `direction`: the innermost split that
/// way with `block` before it, so its right or bottom edge moves, else the
/// innermost with `block` after it. Null if no split that way holds it.
pub fn border(self: *const LayoutTree, block: []const u8, direction: Direction) ?Border {
    const id = ids.block(block) catch return null;
    var buf: [64]Step = undefined;
    const path = self.pathTo(id, &buf) orelse return null;
    for ([_]Side{ .before, .after }) |want| {
        var i = path.len;
        while (i > 0) {
            i -= 1;
            const step = path[i];
            const sp = self.node(step.split).kind.split;
            if (sp.direction != direction or step.side != want) continue;
            // the block across the border nearest it
            const other = switch (want) {
                .before => self.endBlock(sp.after, .before),
                .after => self.endBlock(sp.before, .after),
            } orelse return null;
            return switch (want) {
                .before => .{ .split = step.split, .before_block = id, .after_block = other, .side = .before },
                .after => .{ .split = step.split, .before_block = other, .after_block = id, .side = .after },
            };
        }
    }
    return null;
}

const Step = struct { split: Index, side: Side };

/// The splits from the root down to `block`, and which side of each it's on.
fn pathTo(self: *const LayoutTree, block: ids.Block, buf: []Step) ?[]Step {
    const root = self.root orelse return null;
    var len: usize = 0;
    if (!self.find(root, block, buf, &len)) return null;
    return buf[0..len];
}

fn find(self: *const LayoutTree, i: Index, block: ids.Block, buf: []Step, len: *usize) bool {
    switch (self.node(i).kind) {
        .block => |b| return if (b) |id| ids.sameBlock(id, block) else false,
        .split => |sp| {
            if (len.* == buf.len) return false;
            for ([_]Side{ .before, .after }, [_]Index{ sp.before, sp.after }) |side, child| {
                buf[len.*] = .{ .split = i, .side = side };
                len.* += 1;
                if (self.find(child, block, buf, len)) return true;
                len.* -= 1;
            }
            return false;
        },
    }
}

/// The block at one end of node `i`: following `before` sides, or `after`.
fn endBlock(self: *const LayoutTree, i: Index, end: Side) ?ids.Block {
    var at = i;
    while (true) switch (self.node(at).kind) {
        .block => |b| return b,
        .split => |sp| at = if (end == .before) sp.before else sp.after,
    };
}

const testing = std.testing;

fn uuid(comptime n: u8) []const u8 {
    return comptime "01a1a8ac-0000-7000-8000-00000000000" ++ [_]u8{n};
}

fn blockId(comptime n: u8) []const u8 {
    return comptime "block:" ++ uuid(n);
}

fn splitId(comptime n: u8) []const u8 {
    return comptime "split:" ++ uuid(n);
}

fn blockJson(comptime n: u8, comptime rect: []const u8) []const u8 {
    return comptime "{\"rect\":" ++ rect ++ ",\"block_id\":\"" ++ blockId(n) ++ "\"}";
}

fn splitJson(comptime n: u8, comptime dir: []const u8, comptime ratio: []const u8, comptime rect: []const u8, comptime before: []const u8, comptime after: []const u8) []const u8 {
    return comptime "{\"rect\":" ++ rect ++ ",\"split\":{\"split_id\":\"" ++ splitId(n) ++ "\",\"direction\":\"" ++ dir ++
        "\",\"ratio\":" ++ ratio ++ ",\"before\":" ++ before ++ ",\"after\":" ++ after ++ "}}";
}

fn windowJson(comptime layout_json: []const u8) []const u8 {
    return comptime "{\"window_id\":\"window:" ++ uuid('w') ++ "\",\"zoomed_block_id\":null,\"layers\":[" ++
        "{\"layer_id\":\"layer:" ++ uuid('l') ++ "\",\"kind\":\"tiled\",\"bounds\":[0,0,1,1],\"layout\":" ++ layout_json ++ ",\"blocks\":[]}," ++
        "{\"layer_id\":\"layer:" ++ uuid('f') ++ "\",\"kind\":\"floating\",\"bounds\":[0.2,0.2,0.5,0.5],\"layout\":" ++ blockJson('9', "[0.2,0.2,0.5,0.5]") ++ ",\"blocks\":[]}]}";
}

/// A (1 | (2 / 3)): 1 on the left, 2 above 3 on the right.
const nested = windowJson(splitJson('a', "horizontal", "0.5", "[0,0,1,1]", blockJson('1', "[0,0,0.5,1]"), splitJson('b', "vertical", "0.25", "[0.5,0,0.5,1]", blockJson('2', "[0.5,0,0.5,0.25]"), blockJson('3', "[0.5,0.25,0.5,0.75]"))));

/// 1 | 2 | 3 as Rex nests it: (1 | (2 | 3)).
const row = windowJson(splitJson('a', "horizontal", "0.5", "[0,0,1,1]", blockJson('1', "[0,0,0.5,1]"), splitJson('b', "horizontal", "0.5", "[0.5,0,0.5,1]", blockJson('2', "[0.5,0,0.25,1]"), blockJson('3', "[0.75,0,0.25,1]"))));

const Mirror = struct {
    parsed: std.json.Parsed(Value),
    tree: LayoutTree = .{},

    fn init(json: []const u8) !Mirror {
        var m: Mirror = .{ .parsed = try std.json.parseFromSlice(Value, testing.allocator, json, .{}) };
        errdefer m.parsed.deinit();
        try m.tree.read(testing.allocator, m.parsed.value);
        return m;
    }

    fn deinit(m: *Mirror) void {
        m.tree.deinit(testing.allocator);
        m.parsed.deinit();
    }
};

/// Claims the blocks whose ids end in one of `ends`.
const Ours = struct {
    ends: []const []const u8,
    fn isOurs(self: Ours, id: []const u8) bool {
        for (self.ends) |e| if (std.mem.endsWith(u8, id, e)) return true;
        return false;
    }
};

test "mirrors the tiled layer's tree as Rex gives it" {
    var m: Mirror = try .init(nested);
    defer m.deinit();
    const t = &m.tree;
    try testing.expectEqualStrings("window:" ++ comptime uuid('w'), &t.window_id.?);
    try testing.expectEqualStrings("layer:" ++ comptime uuid('l'), &t.layer_id.?);
    try testing.expectEqual(@as(?ids.Block, null), t.zoomed_block);

    const root = t.node(t.root.?);
    try testing.expectEqual(Rect{ 0, 0, 1, 1 }, root.rect);
    const a = root.kind.split;
    try testing.expectEqualStrings(splitId('a'), &a.id.?);
    try testing.expectEqual(Direction.horizontal, a.direction);
    try testing.expectEqual(@as(f64, 0.5), a.ratio);
    try testing.expectEqualStrings(blockId('1'), &t.node(a.before).kind.block.?);
    try testing.expectEqual(Rect{ 0, 0, 0.5, 1 }, t.node(a.before).rect);

    const b = t.node(a.after).kind.split;
    try testing.expectEqualStrings(splitId('b'), &b.id.?);
    try testing.expectEqual(Direction.vertical, b.direction);
    try testing.expectEqual(@as(f64, 0.25), b.ratio);
    try testing.expectEqualStrings(blockId('2'), &t.node(b.before).kind.block.?);
    try testing.expectEqualStrings(blockId('3'), &t.node(b.after).kind.block.?);
    try testing.expectEqual(Rect{ 0.5, 0.25, 0.5, 0.75 }, t.node(b.after).rect);
    // the floating layer's block isn't in it
    try testing.expectEqual(@as(usize, 5), t.nodes.items.len);
}

test "a zoomed block, an empty layer, and a lone block" {
    {
        var m: Mirror = try .init("{\"window_id\":\"w\",\"zoomed_block_id\":\"" ++ comptime blockId('1') ++ "\",\"layers\":[{\"kind\":\"tiled\",\"layout\":null}]}");
        defer m.deinit();
        try testing.expectEqualStrings(blockId('1'), &m.tree.zoomed_block.?);
        try testing.expectEqual(@as(?Index, null), m.tree.root);
        // not a window id Rex would send
        try testing.expectEqual(@as(?[43]u8, null), m.tree.window_id);
    }
    {
        var m: Mirror = try .init(comptime windowJson(blockJson('1', "[0,0,1,1]")));
        defer m.deinit();
        try testing.expectEqualStrings(blockId('1'), m.tree.idOf(m.tree.root.?).?);
    }
}

test "an unknown direction reads as horizontal; integer rects and ratios read" {
    var m: Mirror = try .init(comptime windowJson(splitJson('a', "diagonal", "1", "[0,0,1,1]", blockJson('1', "[0,0,1,1]"), blockJson('2', "[1,0,0,1]"))));
    defer m.deinit();
    const sp = m.tree.node(m.tree.root.?).kind.split;
    try testing.expectEqual(Direction.horizontal, sp.direction);
    try testing.expectEqual(@as(f64, 1), sp.ratio);
}

test "a malformed layout leaves the tree empty" {
    // the second block has no rect
    var m: Mirror = try .init(comptime windowJson("{\"rect\":[0,0,1,1],\"split\":{\"split_id\":null,\"direction\":\"horizontal\",\"ratio\":0.5,\"before\":" ++
        blockJson('1', "[0,0,0.5,1]") ++ ",\"after\":{\"block_id\":\"" ++ blockId('2') ++ "\"}}}"));
    defer m.deinit();
    try testing.expectEqual(@as(?Index, null), m.tree.root);
    try testing.expectEqual(@as(usize, 0), m.tree.nodes.items.len);
}

test "re-reading replaces the tree" {
    var m: Mirror = try .init(nested);
    defer m.deinit();
    const again = try std.json.parseFromSlice(Value, testing.allocator, comptime windowJson(blockJson('1', "[0,0,1,1]")), .{});
    defer again.deinit();
    try m.tree.read(testing.allocator, again.value);
    try testing.expectEqual(@as(usize, 1), m.tree.nodes.items.len);
}

test "the edge around our blocks" {
    var m: Mirror = try .init(row);
    defer m.deinit();
    const t = &m.tree;
    // all ours: the top split
    try testing.expectEqualStrings(splitId('a'), t.idOf(t.edgeAround(Ours{ .ends = &.{ "1", "2", "3" } }).?).?);
    // a shell on the left stays outside
    try testing.expectEqualStrings(splitId('b'), t.idOf(t.edgeAround(Ours{ .ends = &.{ "2", "3" } }).?).?);
    // one block of ours: just it
    try testing.expectEqualStrings(blockId('3'), t.idOf(t.edgeAround(Ours{ .ends = &.{"3"} }).?).?);
    // a shell between ours is inside
    try testing.expectEqualStrings(splitId('a'), t.idOf(t.edgeAround(Ours{ .ends = &.{ "1", "3" } }).?).?);
    // none of ours
    try testing.expectEqual(@as(?Index, null), t.edgeAround(Ours{ .ends = &.{"9"} }));
}

fn expectBorder(t: *const LayoutTree, block: []const u8, dir: Direction, split: []const u8, before: []const u8, after: []const u8, side: Side) !void {
    const b = t.border(block, dir).?;
    try testing.expectEqualStrings(split, t.idOf(b.split).?);
    try testing.expectEqualStrings(before, &b.before_block);
    try testing.expectEqualStrings(after, &b.after_block);
    try testing.expectEqual(side, b.side);
}

test "the border beside a block" {
    {
        var m: Mirror = try .init(row);
        defer m.deinit();
        const t = &m.tree;
        // 1's right edge
        try expectBorder(t, blockId('1'), .horizontal, splitId('a'), blockId('1'), blockId('2'), .before);
        // 2's right edge is the inner split, the innermost one
        try expectBorder(t, blockId('2'), .horizontal, splitId('b'), blockId('2'), blockId('3'), .before);
        // 3 is last: its left edge
        try expectBorder(t, blockId('3'), .horizontal, splitId('b'), blockId('2'), blockId('3'), .after);
        // nothing above or below
        try testing.expectEqual(@as(?Border, null), t.border(blockId('1'), .vertical));
    }
    {
        var m: Mirror = try .init(nested);
        defer m.deinit();
        const t = &m.tree;
        // 3 sits in a vertical split inside a horizontal one: across, its
        // left edge is the outer split, with 1 the block across it
        try expectBorder(t, blockId('3'), .horizontal, splitId('a'), blockId('1'), blockId('3'), .after);
        // 1's right edge: the block across it is the nearest, 2
        try expectBorder(t, blockId('1'), .horizontal, splitId('a'), blockId('1'), blockId('2'), .before);
        // up and down, 3 has its top edge
        try expectBorder(t, blockId('3'), .vertical, splitId('b'), blockId('2'), blockId('3'), .after);
        // not in the tree
        try testing.expectEqual(@as(?Border, null), t.border(blockId('7'), .horizontal));
    }
}
