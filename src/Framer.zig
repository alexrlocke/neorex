//! Splits a byte stream back into whole msgpack messages.

const std = @import("std");
const msgpack = @import("msgpack.zig");

const Framer = @This();

/// Bytes received: handed-out messages, then ones not yet handed out.
buf: std.ArrayList(u8) = .empty,
/// Offset of the first byte not yet handed out.
start: usize = 0,

/// Adds bytes read from the stream. Invalidates messages from `next`.
pub fn feed(self: *Framer, gpa: std.mem.Allocator, bytes: []const u8) !void {
    // drop handed-out messages
    const rest: usize = self.buf.items.len - self.start;
    @memmove(self.buf.items[0..rest], self.buf.items[self.start..]);
    self.buf.shrinkRetainingCapacity(rest);
    self.start = 0;

    try self.buf.appendSlice(gpa, bytes);
}

/// The next whole message, or null until more is fed. Valid until `feed`.
pub fn next(self: *Framer) !?[]const u8 {
    const rest: []const u8 = self.buf.items[self.start..];
    if (rest.len == 0) return null;
    const end: usize = try messageEnd(rest) orelse return null;
    const msg: []const u8 = rest[0..end];
    self.start += end;
    return msg;
}

pub fn deinit(self: *Framer, gpa: std.mem.Allocator) void {
    self.buf.deinit(gpa);
    self.* = undefined;
}

/// Length of the first whole msgpack value in `bytes`, or null if it's cut off.
fn messageEnd(bytes: []const u8) !?usize {
    var d: msgpack.Decoder = .{};
    d.feed(bytes);

    // values still owed at each open level; the message itself is one
    var stack: [32]u64 = undefined;
    stack[0] = 1;
    var depth: usize = 1;
    // bytes still owed for the current str, bin or ext
    var owed: u32 = 0;

    while (try d.next()) |token| {
        if (token == .chunk) {
            owed -= @intCast(token.chunk.len);
        } else {
            stack[depth - 1] -= 1;
            switch (token) {
                .array => |n| if (n > 0) try push(&stack, &depth, n),
                // u64 so n * 2 can't overflow
                .map => |n| if (n > 0) try push(&stack, &depth, @as(u64, n) * 2),
                .str, .bin => |len| owed = len,
                .ext => |e| owed = e.len,
                else => {},
            }
        }
        while (depth > 0 and stack[depth - 1] == 0) depth -= 1;
        if (depth == 0 and owed == 0) return bytes.len - d.input.len;
    }
    return null;
}

/// Opens a level owing `n` values.
fn push(stack: *[32]u64, depth: *usize, n: u64) !void {
    if (depth.* == stack.len) return error.TooDeep;
    stack[depth.*] = n;
    depth.* += 1;
}

fn expectNext(f: *Framer, expected: ?[]const u8) !void {
    const got = try f.next();
    if (expected) |e| {
        try std.testing.expectEqualStrings(e, got orelse return error.TestExpectedMessage);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), got);
    }
}

test "nothing fed" {
    var f: Framer = .{};
    defer f.deinit(std.testing.allocator);
    try expectNext(&f, null);
}

test "two messages split across feeds" {
    const gpa = std.testing.allocator;
    var f: Framer = .{};
    defer f.deinit(gpa);
    try f.feed(gpa, "\x94\x01\x01"); // half of message 1
    try expectNext(&f, null);
    try f.feed(gpa, "\xc0\x03\x94\x01"); // rest of 1, start of 2
    try expectNext(&f, "\x94\x01\x01\xc0\x03");
    try expectNext(&f, null);
    try f.feed(gpa, "\x01\xc0\x03"); // rest of 2
    try expectNext(&f, "\x94\x01\x01\xc0\x03");
    try expectNext(&f, null);
}

test "split inside a string" {
    // ["hi"] cut after "h": complete only once "i" arrives
    const gpa = std.testing.allocator;
    var f: Framer = .{};
    defer f.deinit(gpa);
    try f.feed(gpa, "\x91\xa2h");
    try expectNext(&f, null);
    try f.feed(gpa, "i");
    try expectNext(&f, "\x91\xa2hi");
}

test "several messages in one feed" {
    // [1, ["hi"], nil], then 5, [] and {}
    const gpa = std.testing.allocator;
    var f: Framer = .{};
    defer f.deinit(gpa);
    try f.feed(gpa, "\x93\x01\x91\xa2hi\xc0\x05\x90\x80");
    try expectNext(&f, "\x93\x01\x91\xa2hi\xc0");
    try expectNext(&f, "\x05");
    try expectNext(&f, "\x90");
    try expectNext(&f, "\x80");
    try expectNext(&f, null);
}

test "maps owe keys and values" {
    // {1: [2, 3]} then 4
    const gpa = std.testing.allocator;
    var f: Framer = .{};
    defer f.deinit(gpa);
    try f.feed(gpa, "\x81\x01\x92\x02\x03\x04");
    try expectNext(&f, "\x81\x01\x92\x02\x03");
    try expectNext(&f, "\x04");
}

test "leftover bytes survive compaction" {
    const gpa = std.testing.allocator;
    var f: Framer = .{};
    defer f.deinit(gpa);
    try f.feed(gpa, "\x05\x92\x01");
    try expectNext(&f, "\x05");
    try expectNext(&f, null);
    try f.feed(gpa, "\x02");
    try expectNext(&f, "\x92\x01\x02");
    // the handed-out 0x05 was dropped by the second feed
    try std.testing.expectEqual(@as(usize, 3), f.buf.items.len);
}

test "neovim's api info in random pieces" {
    const gpa = std.testing.allocator;
    const data = @embedFile("testdata/nvim_get_api_info.mpack");
    var prng = std.Random.DefaultPrng.init(1);
    for (0..50) |_| {
        var f: Framer = .{};
        defer f.deinit(gpa);
        var off: usize = 0;
        while (off < data.len) {
            const n = @min(data.len - off, prng.random().intRangeAtMost(usize, 1, 500));
            try f.feed(gpa, data[off..][0..n]);
            off += n;
            if (off < data.len) try expectNext(&f, null);
        }
        try expectNext(&f, data);
        try expectNext(&f, null);
    }
}

test "errors" {
    const gpa = std.testing.allocator;
    var f: Framer = .{};
    defer f.deinit(gpa);
    try f.feed(gpa, "\xc1");
    try std.testing.expectError(error.InvalidByte, f.next());

    var g: Framer = .{};
    defer g.deinit(gpa);
    const deep: [40]u8 = @splat(0x91); // [[[[...]]]]
    try g.feed(gpa, &deep);
    try std.testing.expectError(error.TooDeep, g.next());
}
