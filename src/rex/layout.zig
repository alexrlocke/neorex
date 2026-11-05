//! Reads where blocks sit in a window of a Rex session view. Knows nothing
//! of which blocks are ours: the caller decides.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Client = @import("Client.zig");

/// Where a block or layer sits in its window, as fractions: x, y, w, h.
pub const Rect = [4]f64;

pub const Placed = struct { block: []const u8, rect: Rect };

/// A window's blocks. The block ids point into the JSON it was read from.
pub const Window = struct {
    /// Every block in a tiled layer, and its rect.
    tiled: std.ArrayList(Placed) = .empty,
    /// Each floating layer's first block, and the layer's bounds.
    floating: std.ArrayList(Placed) = .empty,

    pub fn deinit(self: *Window, gpa: Allocator) void {
        self.tiled.deinit(gpa);
        self.floating.deinit(gpa);
    }
};

/// Reads window `window`'s layers. Skips blocks and layers with missing or
/// malformed fields.
pub fn readWindow(gpa: Allocator, window: Value) Allocator.Error!Window {
    var out: Window = .{};
    errdefer out.deinit(gpa);
    const layers = Client.get(window, "layers") orelse return out;
    if (layers != .array) return out;
    for (layers.array.items) |layer| {
        switch (Kind.of(layer)) {
            .tiled => try readTiled(gpa, layer, &out.tiled),
            .floating => try readFloating(gpa, layer, &out.floating),
        }
    }
    return out;
}

const Kind = enum {
    tiled,
    floating,

    /// A layer's kind. Anything not tiled counts as floating.
    fn of(layer: Value) Kind {
        return Client.getEnum(Kind, layer, "kind") orelse .floating;
    }
};

// tiled layers

/// Adds every block in a tiled layer, and its rect.
fn readTiled(gpa: Allocator, layer: Value, out: *std.ArrayList(Placed)) Allocator.Error!void {
    try findBlocks(gpa, Client.get(layer, "layout") orelse return, out);
}

/// Finds the blocks anywhere under layout node `node`.
fn findBlocks(gpa: Allocator, node: Value, out: *std.ArrayList(Placed)) Allocator.Error!void {
    switch (node) {
        .object => |obj| {
            if (blockAt(obj)) |placed| try out.append(gpa, placed);
            var it = obj.iterator();
            while (it.next()) |entry| try findBlocks(gpa, entry.value_ptr.*, out);
        },
        .array => |arr| for (arr.items) |child| try findBlocks(gpa, child, out),
        else => {},
    }
}

/// The block at layout node `object`, if it is one: it has an id and a valid rect.
fn blockAt(object: std.json.ObjectMap) ?Placed {
    const block = Client.str(object.get("block_id")) orelse return null;
    const rect = asRect(object.get("rect")) orelse return null;
    return .{ .block = block, .rect = rect };
}

// floating layers

/// Adds a floating layer's first block, and the layer's bounds.
fn readFloating(gpa: Allocator, layer: Value, out: *std.ArrayList(Placed)) Allocator.Error!void {
    const bounds = asRect(Client.get(layer, "bounds")) orelse return;
    const blocks = Client.get(layer, "blocks") orelse return;
    if (blocks != .array or blocks.array.items.len == 0) return;
    const block = Client.getStr(blocks.array.items[0], "block_id") orelse return;
    try out.append(gpa, .{ .block = block, .rect = bounds });
}

// values

/// `[x, y, w, h]`, from integers or floats.
pub fn asRect(v: ?Value) ?Rect {
    const items = switch (v orelse return null) {
        .array => |arr| arr.items,
        else => return null,
    };
    if (items.len != 4) return null;
    var rect: Rect = undefined;
    for (items, &rect) |item, *coord| coord.* = asNumber(item) orelse return null;
    return rect;
}

/// A JSON number as a float, whether it's written as an integer or not.
pub fn asNumber(v: Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

const testing = std.testing;

const Read = struct {
    parsed: std.json.Parsed(Value),
    window: Window,

    fn init(json: []const u8) !Read {
        const parsed = try std.json.parseFromSlice(Value, testing.allocator, json, .{});
        errdefer parsed.deinit();
        return .{ .parsed = parsed, .window = try readWindow(testing.allocator, parsed.value) };
    }

    fn deinit(r: *Read) void {
        r.window.deinit(testing.allocator);
        r.parsed.deinit();
    }
};

test "blocks nested in a tiled layout, with integer and float rects" {
    var r: Read = try .init(
        \\{"window_id": "w", "layers": [{"kind": "tiled", "layout":
        \\  {"split": "horizontal", "children": [
        \\    {"block_id": "a", "rect": [0, 0, 0.5, 1]},
        \\    {"split": "vertical", "children": [
        \\      {"block_id": "b", "rect": [0.5, 0, 0.5, 0.5]},
        \\      {"block_id": "c", "rect": [0.5, 0.5, 0.5, 0.5]}
        \\    ]}
        \\  ]}
        \\}]}
    );
    defer r.deinit();
    const tiled = r.window.tiled.items;
    try testing.expectEqual(@as(usize, 3), tiled.len);
    for (tiled, [_][]const u8{ "a", "b", "c" }) |t, want| try testing.expectEqualStrings(want, t.block);
    try testing.expectEqual(Rect{ 0, 0, 0.5, 1 }, tiled[0].rect);
    try testing.expectEqual(Rect{ 0.5, 0.5, 0.5, 0.5 }, tiled[2].rect);
    try testing.expectEqual(@as(usize, 0), r.window.floating.items.len);
}

test "a floating layer gives its first block and bounds" {
    var r: Read = try .init(
        \\{"layers": [
        \\  {"kind": "floating", "bounds": [0.25, 0.25, 0.5, 0.5],
        \\   "blocks": [{"block_id": "first"}, {"block_id": "second"}]},
        \\  {"kind": "floating", "bounds": [0, 0, 1, 1], "blocks": []},
        \\  {"kind": "floating", "blocks": [{"block_id": "no-bounds"}]}
        \\]}
    );
    defer r.deinit();
    const floating = r.window.floating.items;
    try testing.expectEqual(@as(usize, 1), floating.len);
    try testing.expectEqualStrings("first", floating[0].block);
    try testing.expectEqual(Rect{ 0.25, 0.25, 0.5, 0.5 }, floating[0].rect);
    try testing.expectEqual(@as(usize, 0), r.window.tiled.items.len);
}

test "bad rects and missing fields are skipped" {
    var r: Read = try .init(
        \\{"layers": [{"kind": "tiled", "layout": [
        \\  {"block_id": "short", "rect": [0, 0, 1]},
        \\  {"block_id": "text", "rect": [0, "0", 1, 1]},
        \\  {"block_id": "none"},
        \\  {"rect": [0, 0, 1, 1]}
        \\]}]}
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.window.tiled.items.len);
}

test "a window without layers has no blocks" {
    for ([_][]const u8{ "{}", "{\"layers\": \"not a list\"}", "[]" }) |json| {
        var r: Read = try .init(json);
        defer r.deinit();
        try testing.expectEqual(@as(usize, 0), r.window.tiled.items.len);
        try testing.expectEqual(@as(usize, 0), r.window.floating.items.len);
    }
}
