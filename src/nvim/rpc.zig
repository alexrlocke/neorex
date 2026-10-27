//! msgpack-RPC messages: writing requests and parsing whole messages.

const std = @import("std");
const msgpack = @import("msgpack.zig");

/// A parsed message. Slices and decoders point into its bytes.
pub const Message = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,

    /// `[0, id, method, params]`
    pub const Request = struct {
        id: u32,
        method: []const u8,
        /// Positioned at the params array.
        params: msgpack.Decoder,
    };

    /// `[1, id, error, result]`
    pub const Response = struct {
        id: u32,
        /// Neovim's error message, or null on success.
        err: ?[]const u8,
        /// Positioned at the result.
        result: msgpack.Decoder,
    };

    /// `[2, method, params]`
    pub const Notification = struct {
        method: []const u8,
        /// Positioned at the params array.
        params: msgpack.Decoder,
    };
};

/// Writes `[0, id, method, [`; follow with `param_count` params.
pub fn writeRequestHeader(w: *std.Io.Writer, id: u32, method: []const u8, param_count: u32) msgpack.Error!void {
    try msgpack.writeArrayHeader(w, 4);
    try msgpack.writeInt(w, 0);
    try msgpack.writeInt(w, id);
    try msgpack.writeStr(w, method);
    try msgpack.writeArrayHeader(w, param_count);
}

/// Parses one whole message, as returned by `Framer.next`.
pub fn parse(bytes: []const u8) !Message {
    var d: msgpack.Decoder = .{};
    d.feed(bytes);
    const len = try expectArray(&d);
    switch (try expectInt(&d)) {
        0 => {
            if (len != 4) return error.BadMessage;
            const id = try expectId(&d);
            const method = try expectStr(&d);
            return .{ .request = .{ .id = id, .method = method, .params = d } };
        },
        1 => {
            if (len != 4) return error.BadMessage;
            const id = try expectId(&d);
            const err = try readError(&d);
            return .{ .response = .{ .id = id, .err = err, .result = d } };
        },
        2 => {
            if (len != 3) return error.BadMessage;
            const method = try expectStr(&d);
            return .{ .notification = .{ .method = method, .params = d } };
        },
        else => return error.BadMessage,
    }
}

/// Reads an array header, returning its length.
pub fn expectArray(d: *msgpack.Decoder) !u32 {
    return switch (try nextToken(d)) {
        .array => |n| n,
        else => error.BadMessage,
    };
}

pub fn expectInt(d: *msgpack.Decoder) !i64 {
    return switch (try nextToken(d)) {
        .int => |n| n,
        else => error.BadMessage,
    };
}

/// Reads a whole string. Needs a whole message, so it's one chunk.
pub fn expectStr(d: *msgpack.Decoder) ![]const u8 {
    return switch (try nextToken(d)) {
        .str => |len| expectBytes(d, len),
        else => error.BadMessage,
    };
}

pub fn expectBool(d: *msgpack.Decoder) !bool {
    return switch (try nextToken(d)) {
        .bool => |b| b,
        else => error.BadMessage,
    };
}

/// Reads a map header, returning its number of pairs.
pub fn expectMap(d: *msgpack.Decoder) !u32 {
    return switch (try nextToken(d)) {
        .map => |n| n,
        else => error.BadMessage,
    };
}

/// A buffer, window or tabpage handle: an ext wrapping an int, or a plain int.
pub fn expectHandle(d: *msgpack.Decoder) !i64 {
    return switch (try nextToken(d)) {
        .int => |n| n,
        .ext => |e| {
            var inner: msgpack.Decoder = .{};
            inner.feed(try expectBytes(d, e.len));
            return expectInt(&inner);
        },
        else => error.BadMessage,
    };
}

/// Skips one whole value, however deeply nested.
pub fn skip(d: *msgpack.Decoder) !void {
    // values still owed; nesting doesn't matter when only counting
    var owed: u64 = 1;
    while (owed > 0) : (owed -= 1) {
        switch (try nextToken(d)) {
            .array => |n| owed += n,
            .map => |n| owed += @as(u64, n) * 2,
            .str, .bin => |len| _ = try expectBytes(d, len),
            .ext => |e| _ = try expectBytes(d, e.len),
            .chunk => return error.BadMessage,
            else => {},
        }
    }
}

/// A token that must exist: the message is whole, so null means it's cut short.
fn nextToken(d: *msgpack.Decoder) !msgpack.Token {
    return (try d.next()) orelse error.BadMessage;
}

/// The `len` bytes after a str, bin or ext header.
pub fn expectBytes(d: *msgpack.Decoder, len: u32) ![]const u8 {
    if (len == 0) return "";
    return switch (try nextToken(d)) {
        .chunk => |c| if (c.len == len) c else error.BadMessage,
        else => error.BadMessage,
    };
}

fn expectId(d: *msgpack.Decoder) !u32 {
    return std.math.cast(u32, try expectInt(d)) orelse error.BadMessage;
}

/// nil, or Neovim's `[type, message]`. Returns the message.
fn readError(d: *msgpack.Decoder) !?[]const u8 {
    switch (try nextToken(d)) {
        .nil => return null,
        .array => |n| {
            if (n < 2) return error.BadMessage;
            try skip(d); // error type
            const msg = try expectStr(d);
            for (2..n) |_| try skip(d);
            return msg;
        },
        else => return error.BadMessage,
    }
}

test "request header" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRequestHeader(&w, 7, "nvim_input", 1);
    try msgpack.writeStr(&w, "<C-a>");
    try std.testing.expectEqualSlices(u8, "\x94\x00\x07\xaanvim_input\x91\xa5<C-a>", w.buffered());
}

test "parse response" {
    // [1, 1, nil, 3]
    var msg = try parse("\x94\x01\x01\xc0\x03");
    const r = msg.response;
    try std.testing.expectEqual(@as(u32, 1), r.id);
    try std.testing.expectEqual(@as(?[]const u8, null), r.err);
    try std.testing.expectEqual(@as(i64, 3), try expectInt(&msg.response.result));
}

test "parse error response" {
    // [1, 2, [0, "boom"], nil]
    const msg = try parse("\x94\x01\x02\x92\x00\xa4boom\xc0");
    try std.testing.expectEqual(@as(u32, 2), msg.response.id);
    try std.testing.expectEqualStrings("boom", msg.response.err.?);
}

test "parse notification" {
    // [2, "redraw", [["flush"]]]
    var msg = try parse("\x93\x02\xa6redraw\x91\x91\xa5flush");
    try std.testing.expectEqualStrings("redraw", msg.notification.method);
    const params = &msg.notification.params;
    try std.testing.expectEqual(@as(u32, 1), try expectArray(params));
    try std.testing.expectEqual(@as(u32, 1), try expectArray(params));
    try std.testing.expectEqualStrings("flush", try expectStr(params));
}

test "parse request" {
    // [0, 7, "x", []]
    var msg = try parse("\x94\x00\x07\xa1x\x90");
    try std.testing.expectEqual(@as(u32, 7), msg.request.id);
    try std.testing.expectEqualStrings("x", msg.request.method);
    try std.testing.expectEqual(@as(u32, 0), try expectArray(&msg.request.params));
}

test "parse rejects bad messages" {
    try std.testing.expectError(error.BadMessage, parse("\x05")); // not an array
    try std.testing.expectError(error.BadMessage, parse("\x93\x03\x01\x02")); // unknown type
    try std.testing.expectError(error.BadMessage, parse("\x93\x01\x01\xc0")); // response too short
    try std.testing.expectError(error.BadMessage, parse("\x94\x01\xff\xc0\xc0")); // negative id
}

test "handles" {
    // window 1000 as ext 1, then a plain 7, then -1 as fixext 1
    var d: msgpack.Decoder = .{};
    d.feed("\xc7\x03\x01\xcd\x03\xe8\x07\xd4\x01\xff");
    try std.testing.expectEqual(@as(i64, 1000), try expectHandle(&d));
    try std.testing.expectEqual(@as(i64, 7), try expectHandle(&d));
    try std.testing.expectEqual(@as(i64, -1), try expectHandle(&d));
}

test "skip" {
    // [1, {2: "ab"}, nil] then 9
    var d: msgpack.Decoder = .{};
    d.feed("\x93\x01\x81\x02\xa2ab\xc0\x09");
    try skip(&d);
    try std.testing.expectEqual(@as(i64, 9), try expectInt(&d));
}
