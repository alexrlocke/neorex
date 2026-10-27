//! MessagePack encoding and decoding.
//! Encoding: each function writes one value. Arrays and maps write only a
//! header; the caller writes the items after.
//! Decoding: `Decoder` turns bytes into tokens, in the design of libmpack.
// needs review

const std = @import("std");
const Writer = std.Io.Writer;

pub const Error = Writer.Error || error{TooLong};

pub fn writeNil(w: *Writer) Error!void {
    try w.writeByte(0xc0);
}

pub fn writeBool(w: *Writer, b: bool) Error!void {
    try w.writeByte(if (b) 0xc3 else 0xc2);
}

/// Smallest encoding that fits.
pub fn writeInt(w: *Writer, n: i64) Error!void {
    if (n >= 0) {
        if (n <= 0x7f) return w.writeByte(@intCast(n)); // positive fixint
        if (n <= std.math.maxInt(u8)) return writeTagged(w, 0xcc, u8, @intCast(n));
        if (n <= std.math.maxInt(u16)) return writeTagged(w, 0xcd, u16, @intCast(n));
        if (n <= std.math.maxInt(u32)) return writeTagged(w, 0xce, u32, @intCast(n));
        return writeTagged(w, 0xcf, u64, @intCast(n));
    }
    if (n >= -32) return w.writeByte(@bitCast(@as(i8, @intCast(n)))); // negative fixint
    if (n >= std.math.minInt(i8)) return writeTagged(w, 0xd0, i8, @intCast(n));
    if (n >= std.math.minInt(i16)) return writeTagged(w, 0xd1, i16, @intCast(n));
    if (n >= std.math.minInt(i32)) return writeTagged(w, 0xd2, i32, @intCast(n));
    return writeTagged(w, 0xd3, i64, n);
}

pub fn writeFloat(w: *Writer, f: f64) Error!void {
    try writeTagged(w, 0xcb, u64, @bitCast(f));
}

pub fn writeStr(w: *Writer, s: []const u8) Error!void {
    try writeStrHeader(w, std.math.cast(u32, s.len) orelse return error.TooLong);
    try w.writeAll(s);
}

/// Follow with `len` bytes of string.
pub fn writeStrHeader(w: *Writer, len: u32) Error!void {
    if (len <= 31) return w.writeByte(0xa0 | @as(u8, @intCast(len))); // fixstr
    if (len <= std.math.maxInt(u8)) return writeTagged(w, 0xd9, u8, @intCast(len));
    if (len <= std.math.maxInt(u16)) return writeTagged(w, 0xda, u16, @intCast(len));
    return writeTagged(w, 0xdb, u32, len);
}

/// Follow with `len` values.
pub fn writeArrayHeader(w: *Writer, len: u32) Error!void {
    if (len <= 15) return w.writeByte(0x90 | @as(u8, @intCast(len))); // fixarray
    if (len <= std.math.maxInt(u16)) return writeTagged(w, 0xdc, u16, @intCast(len));
    return writeTagged(w, 0xdd, u32, len);
}

/// Follow with `len` key-value pairs.
pub fn writeMapHeader(w: *Writer, len: u32) Error!void {
    if (len <= 15) return w.writeByte(0x80 | @as(u8, @intCast(len))); // fixmap
    if (len <= std.math.maxInt(u16)) return writeTagged(w, 0xde, u16, @intCast(len));
    return writeTagged(w, 0xdf, u32, len);
}

/// A type byte, then `value` big-endian.
fn writeTagged(w: *Writer, tag: u8, comptime T: type, value: T) Error!void {
    try w.writeByte(tag);
    try w.writeInt(T, value, .big);
}

fn expectInt(n: i64, expected: []const u8) !void {
    var buf: [16]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeInt(&w, n);
    try std.testing.expectEqualSlices(u8, expected, w.buffered());
}

test "nil and bool" {
    var buf: [3]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeNil(&w);
    try writeBool(&w, true);
    try writeBool(&w, false);
    try std.testing.expectEqualSlices(u8, &.{ 0xc0, 0xc3, 0xc2 }, w.buffered());
}

test "int boundaries" {
    try expectInt(0, &.{0x00});
    try expectInt(127, &.{0x7f});
    try expectInt(128, &.{ 0xcc, 0x80 });
    try expectInt(255, &.{ 0xcc, 0xff });
    try expectInt(256, &.{ 0xcd, 0x01, 0x00 });
    try expectInt(65535, &.{ 0xcd, 0xff, 0xff });
    try expectInt(65536, &.{ 0xce, 0x00, 0x01, 0x00, 0x00 });
    try expectInt(4294967295, &.{ 0xce, 0xff, 0xff, 0xff, 0xff });
    try expectInt(4294967296, &.{ 0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 });
    try expectInt(std.math.maxInt(i64), &.{ 0xcf, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });

    try expectInt(-1, &.{0xff});
    try expectInt(-32, &.{0xe0});
    try expectInt(-33, &.{ 0xd0, 0xdf });
    try expectInt(-128, &.{ 0xd0, 0x80 });
    try expectInt(-129, &.{ 0xd1, 0xff, 0x7f });
    try expectInt(-32768, &.{ 0xd1, 0x80, 0x00 });
    try expectInt(-32769, &.{ 0xd2, 0xff, 0xff, 0x7f, 0xff });
    try expectInt(std.math.minInt(i32), &.{ 0xd2, 0x80, 0x00, 0x00, 0x00 });
    try expectInt(std.math.minInt(i32) - 1, &.{ 0xd3, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff });
    try expectInt(std.math.minInt(i64), &.{ 0xd3, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
}

test "float" {
    var buf: [9]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeFloat(&w, 1.5);
    try std.testing.expectEqualSlices(u8, &.{ 0xcb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0 }, w.buffered());
}

test "str boundaries" {
    const s: [65536]u8 = @splat('x');
    var buf: [65536 + 5]u8 = undefined;
    // length, then the header bytes expected before the data
    const cases = .{
        .{ 0, &[_]u8{0xa0} },
        .{ 31, &[_]u8{0xbf} },
        .{ 32, &[_]u8{ 0xd9, 32 } },
        .{ 255, &[_]u8{ 0xd9, 0xff } },
        .{ 256, &[_]u8{ 0xda, 0x01, 0x00 } },
        .{ 65535, &[_]u8{ 0xda, 0xff, 0xff } },
        .{ 65536, &[_]u8{ 0xdb, 0x00, 0x01, 0x00, 0x00 } },
    };
    inline for (cases) |case| {
        var w: Writer = .fixed(&buf);
        try writeStr(&w, s[0..case[0]]);
        const out = w.buffered();
        try std.testing.expectEqualSlices(u8, case[1], out[0..case[1].len]);
        try std.testing.expectEqual(case[1].len + case[0], out.len);
    }
}

test "array and map header boundaries" {
    var buf: [5]u8 = undefined;
    const cases = .{
        .{ writeArrayHeader, 15, &[_]u8{0x9f} },
        .{ writeArrayHeader, 16, &[_]u8{ 0xdc, 0x00, 0x10 } },
        .{ writeArrayHeader, 65536, &[_]u8{ 0xdd, 0x00, 0x01, 0x00, 0x00 } },
        .{ writeMapHeader, 0, &[_]u8{0x80} },
        .{ writeMapHeader, 15, &[_]u8{0x8f} },
        .{ writeMapHeader, 16, &[_]u8{ 0xde, 0x00, 0x10 } },
        .{ writeMapHeader, 65536, &[_]u8{ 0xdf, 0x00, 0x01, 0x00, 0x00 } },
    };
    inline for (cases) |case| {
        var w: Writer = .fixed(&buf);
        try case[0](&w, case[1]);
        try std.testing.expectEqualSlices(u8, case[2], w.buffered());
    }
}

test "an rpc request" {
    // [0, 1, "nvim_input", ["<C-a>"]]
    var buf: [32]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeArrayHeader(&w, 4);
    try writeInt(&w, 0);
    try writeInt(&w, 1);
    try writeStr(&w, "nvim_input");
    try writeArrayHeader(&w, 1);
    try writeStr(&w, "<C-a>");
    try std.testing.expectEqualSlices(u8, "\x94\x00\x01\xaanvim_input\x91\xa5<C-a>", w.buffered());
}

/// One decoded piece of a value. Containers and blobs are headers: an array
/// is followed by `len` values, a map by `len` key-value pairs, and a str,
/// bin or ext by chunks totalling `len` bytes.
pub const Token = union(enum) {
    nil,
    bool: bool,
    /// Any integer that fits in i64.
    int: i64,
    /// Only integers above maxInt(i64).
    uint: u64,
    float: f64,
    array: u32,
    map: u32,
    str: u32,
    bin: u32,
    ext: Ext,
    /// Bytes of the current str, bin or ext. Points into the fed bytes.
    chunk: []const u8,

    pub const Ext = struct { type: i8, len: u32 };
};

/// Streaming decoder. Feed bytes as they arrive, then call `next` until it
/// returns null. Values may be split anywhere across feeds.
pub const Decoder = struct {
    input: []const u8 = "",
    /// A header split across feeds, kept until it's complete.
    pending: [9]u8 = undefined,
    pending_len: u8 = 0,
    /// Bytes of str, bin or ext data still to hand out as chunks.
    remaining: u32 = 0,

    /// Chunks point into `bytes`, so keep them alive until `next` returns null.
    pub fn feed(self: *Decoder, bytes: []const u8) void {
        std.debug.assert(self.input.len == 0);
        self.input = bytes;
    }

    /// The next token, or null when the fed bytes are used up.
    pub fn next(self: *Decoder) error{InvalidByte}!?Token {
        if (self.input.len == 0) return null;

        if (self.remaining > 0) {
            const n = @min(self.remaining, self.input.len);
            self.remaining -= @intCast(n);
            return .{ .chunk = self.take(n) };
        }

        const first = if (self.pending_len > 0) self.pending[0] else self.input[0];
        const need = headerLen(first) orelse return error.InvalidByte;

        const header = if (self.pending_len == 0 and self.input.len >= need)
            self.take(need)
        else header: {
            // header split across feeds: collect it in `pending`
            const n = @min(need - self.pending_len, self.input.len);
            @memcpy(self.pending[self.pending_len..][0..n], self.take(n));
            self.pending_len += @intCast(n);
            if (self.pending_len < need) return null;
            self.pending_len = 0;
            break :header self.pending[0..need];
        };

        const token = decodeHeader(header);
        switch (token) {
            .str, .bin => |len| self.remaining = len,
            .ext => |e| self.remaining = e.len,
            else => {},
        }
        return token;
    }

    fn take(self: *Decoder, n: usize) []const u8 {
        defer self.input = self.input[n..];
        return self.input[0..n];
    }
};

/// Header size in bytes, including the type byte. Null for 0xc1, which is
/// never used.
fn headerLen(b: u8) ?u8 {
    return switch (b) {
        0x00...0xbf, 0xc0, 0xc2, 0xc3, 0xe0...0xff => 1,
        0xc1 => null,
        0xc4, 0xcc, 0xd0, 0xd9 => 2, // 8-bit length or value
        0xc5, 0xcd, 0xd1, 0xda, 0xdc, 0xde => 3, // 16-bit
        0xc6, 0xca, 0xce, 0xd2, 0xdb, 0xdd, 0xdf => 5, // 32-bit
        0xcb, 0xcf, 0xd3 => 9, // 64-bit
        0xc7 => 3, // ext 8: length, then type
        0xc8 => 4, // ext 16
        0xc9 => 6, // ext 32
        0xd4...0xd8 => 2, // fixext: type only
    };
}

/// Decodes a complete header, as sized by `headerLen`.
fn decodeHeader(h: []const u8) Token {
    return switch (h[0]) {
        0x00...0x7f => .{ .int = h[0] },
        0x80...0x8f => .{ .map = h[0] & 0x0f },
        0x90...0x9f => .{ .array = h[0] & 0x0f },
        0xa0...0xbf => .{ .str = h[0] & 0x1f },
        0xc0 => .nil,
        0xc2 => .{ .bool = false },
        0xc3 => .{ .bool = true },
        0xc4 => .{ .bin = readBig(u8, h) },
        0xc5 => .{ .bin = readBig(u16, h) },
        0xc6 => .{ .bin = readBig(u32, h) },
        0xc7 => .{ .ext = .{ .len = readBig(u8, h), .type = @bitCast(h[2]) } },
        0xc8 => .{ .ext = .{ .len = readBig(u16, h), .type = @bitCast(h[3]) } },
        0xc9 => .{ .ext = .{ .len = readBig(u32, h), .type = @bitCast(h[5]) } },
        0xca => .{ .float = @as(f32, @bitCast(readBig(u32, h))) },
        0xcb => .{ .float = @bitCast(readBig(u64, h)) },
        0xcc => .{ .int = readBig(u8, h) },
        0xcd => .{ .int = readBig(u16, h) },
        0xce => .{ .int = readBig(u32, h) },
        0xcf => uint: {
            const n = readBig(u64, h);
            break :uint if (n <= std.math.maxInt(i64)) .{ .int = @intCast(n) } else .{ .uint = n };
        },
        0xd0 => .{ .int = readBig(i8, h) },
        0xd1 => .{ .int = readBig(i16, h) },
        0xd2 => .{ .int = readBig(i32, h) },
        0xd3 => .{ .int = readBig(i64, h) },
        0xd4...0xd8 => .{ .ext = .{ .len = @as(u32, 1) << @intCast(h[0] - 0xd4), .type = @bitCast(h[1]) } },
        0xd9 => .{ .str = readBig(u8, h) },
        0xda => .{ .str = readBig(u16, h) },
        0xdb => .{ .str = readBig(u32, h) },
        0xdc => .{ .array = readBig(u16, h) },
        0xdd => .{ .array = readBig(u32, h) },
        0xde => .{ .map = readBig(u16, h) },
        0xdf => .{ .map = readBig(u32, h) },
        0xe0...0xff => .{ .int = @as(i8, @bitCast(h[0])) },
        0xc1 => unreachable, // rejected by headerLen
    };
}

/// The big-endian T after the type byte.
fn readBig(comptime T: type, h: []const u8) T {
    return std.mem.readInt(T, h[1..][0..@sizeOf(T)], .big);
}

/// Decodes `parts`, fed one after another, into a line of text. Chunks are
/// written raw, so a str reads the same however its bytes were split.
fn expectDecoded(parts: []const []const u8, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var d: Decoder = .{};
    for (parts) |part| {
        d.feed(part);
        while (try d.next()) |token| switch (token) {
            .nil => try w.writeAll("nil "),
            .bool => |b| try w.print("{} ", .{b}),
            .int => |n| try w.print("{d} ", .{n}),
            .uint => |n| try w.print("u{d} ", .{n}),
            .float => |f| try w.print("{d} ", .{f}),
            .array => |n| try w.print("[{d}] ", .{n}),
            .map => |n| try w.print("{{{d}}} ", .{n}),
            .str => |n| try w.print("str{d}:", .{n}),
            .bin => |n| try w.print("bin{d}:", .{n}),
            .ext => |e| try w.print("ext{d}/{d}:", .{ e.type, e.len }),
            .chunk => |c| try w.writeAll(c),
        };
    }
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "decode scalars" {
    try expectDecoded(&.{"\xc0\xc2\xc3"}, "nil false true ");
    try expectDecoded(&.{"\x00\x7f\xff\xe0"}, "0 127 -1 -32 ");
    try expectDecoded(&.{"\xcc\x80\xcd\x01\x00\xd0\xdf\xd1\xff\x7f"}, "128 256 -33 -129 ");
    try expectDecoded(&.{"\xcf\x7f\xff\xff\xff\xff\xff\xff\xff"}, "9223372036854775807 ");
    try expectDecoded(&.{"\xcf\xff\xff\xff\xff\xff\xff\xff\xff"}, "u18446744073709551615 ");
    try expectDecoded(&.{"\xd3\x80\x00\x00\x00\x00\x00\x00\x00"}, "-9223372036854775808 ");
    try expectDecoded(&.{ "\xca\x3f\xc0\x00\x00", "\xcb\x3f\xf8\x00\x00\x00\x00\x00\x00" }, "1.5 1.5 ");
}

test "decode containers and blobs" {
    try expectDecoded(&.{"\x92\x01\x02"}, "[2] 1 2 ");
    try expectDecoded(&.{"\x81\xa1k\x01"}, "{1} str1:k1 ");
    try expectDecoded(&.{"\xa0\x01"}, "str0:1 ");
    try expectDecoded(&.{"\xc4\x02ab"}, "bin2:ab");
    // Neovim sends handles as ext: buffer (0), window (1), tabpage (2)
    try expectDecoded(&.{"\xd4\x01\x05"}, "ext1/1:\x05");
    try expectDecoded(&.{"\xc7\x02\x02\x01\x02"}, "ext2/2:\x01\x02");
}

test "decode neovim's reply" {
    // nvim_eval("1+2") → [1, 1, nil, 3]
    try expectDecoded(&.{"\x94\x01\x01\xc0\x03"}, "[4] 1 1 nil 3 ");
}

test "decode split at every byte" {
    const msg = "\x93\xcd\x01\x00\xa5hello\xcb\x3f\xf8\x00\x00\x00\x00\x00\x00";
    const expected = "[3] 256 str5:hello1.5 ";
    try expectDecoded(&.{msg}, expected);
    for (1..msg.len) |i| try expectDecoded(&.{ msg[0..i], msg[i..] }, expected);

    var one_byte: [msg.len][]const u8 = undefined;
    for (&one_byte, 0..) |*part, i| part.* = msg[i..][0..1];
    try expectDecoded(&one_byte, expected);
}

test "decode what the encoder wrote" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeArrayHeader(&w, 4);
    try writeInt(&w, -129);
    try writeStr(&w, "nvim_input");
    try writeNil(&w);
    try writeMapHeader(&w, 0);
    try expectDecoded(&.{w.buffered()}, "[4] -129 str10:nvim_inputnil {0} ");
}

test "decode rejects 0xc1" {
    var d: Decoder = .{};
    d.feed("\xc1");
    try std.testing.expectError(error.InvalidByte, d.next());
}
