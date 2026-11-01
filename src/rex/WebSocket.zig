//! A minimal RFC 6455 WebSocket client: the handshake and framing, no I/O.
//! No extensions, so no compression.

const std = @import("std");
const Writer = std.Io.Writer;

const WebSocket = @This();

/// Bytes received: handed-out frames, then ones not yet parsed.
buf: std.ArrayList(u8) = .empty,
/// Offset of the first frame not yet parsed.
pos: usize = 0,
/// A fragmented message being joined in place in `buf`.
joined: ?Joined = null,
/// Largest message accepted, in bytes.
max_message: usize = 1 << 20,

const Joined = struct { start: usize, len: usize };

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const Message = union(enum) {
    text: []const u8,
    ping: []const u8,
    pong: []const u8,
    close: Close,
};

pub const Close = struct {
    /// Null when the frame had no body.
    code: ?u16,
    reason: []const u8,
};

/// Adds bytes read from the socket. Invalidates messages from `next`.
pub fn feed(self: *WebSocket, gpa: std.mem.Allocator, bytes: []const u8) !void {
    // drop parsed frames, keeping a message still being joined
    const drop: usize = if (self.joined) |j| j.start else self.pos;
    const rest: usize = self.buf.items.len - drop;
    @memmove(self.buf.items[0..rest], self.buf.items[drop..]);
    self.buf.shrinkRetainingCapacity(rest);
    self.pos -= drop;
    if (self.joined) |*j| j.start = 0;

    try self.buf.appendSlice(gpa, bytes);
}

/// The next whole message, or null until more is fed. Valid until `next` or `feed`.
pub fn next(self: *WebSocket) !?Message {
    while (true) {
        const rest: []const u8 = self.buf.items[self.pos..];
        if (rest.len < 2) return null;
        const fin = rest[0] & 0x80 != 0;
        if (rest[0] & 0x70 != 0) return error.ReservedBits;
        const opcode: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(rest[0]))));
        // servers never mask
        if (rest[1] & 0x80 != 0) return error.MaskedFrame;

        const len7: u7 = @truncate(rest[1]);
        const header: usize = switch (len7) {
            126 => 4,
            127 => 10,
            else => 2,
        };
        if (rest.len < header) return null;
        const len: u64 = switch (len7) {
            126 => std.mem.readInt(u16, rest[2..4], .big),
            127 => std.mem.readInt(u64, rest[2..10], .big),
            else => len7,
        };
        const is_control = @backingInt(opcode) >= 8;
        if (is_control and (!fin or len > 125)) return error.BadControlFrame;
        const so_far: usize = if (self.joined) |j| j.len else 0;
        if (len > self.max_message - so_far) return error.MessageTooLarge;
        const n: usize = @intCast(len);
        if (rest.len - header < n) return null;

        const start = self.pos + header;
        const payload: []u8 = self.buf.items[start..][0..n];
        self.pos = start + n;

        switch (opcode) {
            .text => {
                if (self.joined != null) return error.UnfinishedMessage;
                if (fin) return .{ .text = try checkUtf8(payload) };
                self.joined = .{ .start = start, .len = n };
            },
            .continuation => {
                const j = &(self.joined orelse return error.UnexpectedContinuation);
                // joined data always sits before this frame
                std.mem.copyForwards(u8, self.buf.items[j.start + j.len ..][0..n], payload);
                j.len += n;
                if (fin) {
                    const text = self.buf.items[j.start..][0..j.len];
                    self.joined = null;
                    return .{ .text = try checkUtf8(text) };
                }
            },
            .ping => return .{ .ping = payload },
            .pong => return .{ .pong = payload },
            .close => {
                if (n == 1) return error.BadControlFrame;
                if (n == 0) return .{ .close = .{ .code = null, .reason = "" } };
                return .{ .close = .{ .code = std.mem.readInt(u16, payload[0..2], .big), .reason = payload[2..] } };
            },
            .binary => return error.BinaryMessage,
            _ => return error.BadOpcode,
        }
    }
}

pub fn deinit(self: *WebSocket, gpa: std.mem.Allocator) void {
    self.buf.deinit(gpa);
    self.* = undefined;
}

fn checkUtf8(text: []const u8) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return text;
}

/// A `Sec-WebSocket-Key`: 16 random bytes in base64.
pub const Key = [24]u8;

pub fn newKey(io: std.Io) Key {
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    var key: Key = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &nonce);
    return key;
}

/// The `Sec-WebSocket-Accept` a server must answer `key` with.
pub fn acceptFor(key: *const Key) [28]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    h.final(&digest);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    return accept;
}

/// Writes the HTTP upgrade request.
pub fn writeRequest(w: *Writer, host: []const u8, path: []const u8, protocol: []const u8, key: *const Key) !void {
    try w.print(
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Protocol: {s}\r\n" ++
            "\r\n",
        .{ path, host, key, protocol },
    );
}

/// Length of the response head through its blank line, or null if it's cut off.
pub fn headEnd(bytes: []const u8) ?usize {
    const i = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return null;
    return i + 4;
}

/// Checks the server's response head: 101, the accept, and the subprotocol.
pub fn checkResponse(head: []const u8, key: *const Key, protocol: []const u8) !void {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status = lines.first();
    if (!std.mem.startsWith(u8, status, "HTTP/1.1 101")) return error.NotUpgraded;

    var upgrade = false;
    var accepted = false;
    var chosen = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            accepted = std.mem.eql(u8, value, &acceptFor(key));
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) {
            chosen = std.mem.eql(u8, value, protocol);
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-extensions")) {
            // none were offered
            return error.UnexpectedExtension;
        }
    }
    if (!upgrade) return error.NotUpgraded;
    if (!accepted) return error.BadAccept;
    if (!chosen) return error.BadProtocol;
}

/// Writes one masked frame with a random mask. Doesn't flush.
pub fn writeFrame(w: *Writer, io: std.Io, opcode: Opcode, payload: []const u8) !void {
    var mask: [4]u8 = undefined;
    io.random(&mask);
    try writeFrameMasked(w, opcode, payload, mask);
}

/// Writes one final frame masked with `mask`.
pub fn writeFrameMasked(w: *Writer, opcode: Opcode, payload: []const u8, mask: [4]u8) !void {
    try w.writeByte(0x80 | @as(u8, @backingInt(opcode)));
    if (payload.len < 126) {
        try w.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= std.math.maxInt(u16)) {
        try w.writeByte(0x80 | 126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(0x80 | 127);
        try w.writeInt(u64, payload.len, .big);
    }
    try w.writeAll(&mask);

    var chunk: [256]u8 = undefined;
    var off: usize = 0;
    while (off < payload.len) {
        const n = @min(chunk.len, payload.len - off);
        // chunk.len is a multiple of 4, so the mask index is off + i
        for (chunk[0..n], payload[off..][0..n], 0..) |*out, b, i| out.* = b ^ mask[i % 4];
        try w.writeAll(chunk[0..n]);
        off += n;
    }
}

/// Writes a close frame with `code`. Doesn't flush.
pub fn writeClose(w: *Writer, io: std.Io, code: u16) !void {
    var body: [2]u8 = undefined;
    std.mem.writeInt(u16, &body, code, .big);
    try writeFrame(w, io, .close, &body);
}

const testing = std.testing;

/// An unmasked server frame.
fn serverFrame(gpa: std.mem.Allocator, fin: bool, opcode: Opcode, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, (if (fin) @as(u8, 0x80) else 0) | @backingInt(opcode));
    if (payload.len < 126) {
        try out.append(gpa, @intCast(payload.len));
    } else if (payload.len <= std.math.maxInt(u16)) {
        try out.append(gpa, 126);
        try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(payload.len))));
    } else {
        try out.append(gpa, 127);
        try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u64, payload.len)));
    }
    try out.appendSlice(gpa, payload);
    return out.toOwnedSlice(gpa);
}

fn expectText(ws: *WebSocket, expected: []const u8) !void {
    const m = (try ws.next()) orelse return error.TestExpectedMessage;
    try testing.expectEqualStrings(expected, m.text);
}

test "rfc 6455 accept example" {
    const key: Key = "dGhlIHNhbXBsZSBub25jZQ==".*;
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptFor(&key));
}

test "request and response" {
    const key: Key = "dGhlIHNhbXBsZSBub25jZQ==".*;
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeRequest(&w, "localhost", "/api/control", "rex.control.v1", &key);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "GET /api/control HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Sec-WebSocket-Protocol: rex.control.v1\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "\r\n\r\n"));

    const good = "HTTP/1.1 101 Switching Protocols\r\nupgrade: WebSocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSec-WebSocket-Protocol: rex.control.v1\r\n\r\n";
    try testing.expectEqual(@as(?usize, good.len), headEnd(good ++ "\x81\x00"));
    try testing.expectEqual(@as(?usize, null), headEnd(good[0 .. good.len - 1]));
    try checkResponse(good, &key, "rex.control.v1");
    try testing.expectError(error.BadProtocol, checkResponse(good, &key, "other"));
    const other_key: Key = "AAAAAAAAAAAAAAAAAAAAAA==".*;
    try testing.expectError(error.BadAccept, checkResponse(good, &other_key, "rex.control.v1"));
    try testing.expectError(error.NotUpgraded, checkResponse("HTTP/1.1 400 Bad Request\r\n\r\n", &key, "rex.control.v1"));
}

test "each length form" {
    const gpa = testing.allocator;
    var ws: WebSocket = .{};
    defer ws.deinit(gpa);
    for ([_]usize{ 0, 125, 126, 65535, 65536 }) |len| {
        const payload = try gpa.alloc(u8, len);
        defer gpa.free(payload);
        @memset(payload, 'a');
        const frame = try serverFrame(gpa, true, .text, payload);
        defer gpa.free(frame);
        try testing.expectEqual(@as(usize, if (len < 126) 2 else if (len < 65536) 4 else 10), frame.len - len);
        try ws.feed(gpa, frame);
        try expectText(&ws, payload);
        try testing.expectEqual(@as(?Message, null), try ws.next());
    }
}

test "a frame split across feeds, byte by byte" {
    const gpa = testing.allocator;
    var ws: WebSocket = .{};
    defer ws.deinit(gpa);
    const payload: [300]u8 = @splat('x');
    const frame = try serverFrame(gpa, true, .text, &payload);
    defer gpa.free(frame);
    for (frame[0 .. frame.len - 1]) |b| {
        try ws.feed(gpa, &.{b});
        try testing.expectEqual(@as(?Message, null), try ws.next());
    }
    try ws.feed(gpa, frame[frame.len - 1 ..]);
    try expectText(&ws, &payload);
}

test "fragments joined, with a ping between them" {
    const gpa = testing.allocator;
    var ws: WebSocket = .{};
    defer ws.deinit(gpa);
    const parts = [_][]const u8{
        try serverFrame(gpa, false, .text, "hel"),
        try serverFrame(gpa, false, .continuation, "lo, "),
        try serverFrame(gpa, true, .ping, "p"),
        try serverFrame(gpa, true, .continuation, "world"),
        try serverFrame(gpa, true, .text, "next"),
    };
    defer for (parts) |p| gpa.free(p);
    try ws.feed(gpa, parts[0]);
    try ws.feed(gpa, parts[1]);
    try testing.expectEqual(@as(?Message, null), try ws.next());
    // compaction keeps the joined part
    try ws.feed(gpa, parts[2]);
    try testing.expectEqualStrings("p", (try ws.next()).?.ping);
    const tail = try std.mem.concat(gpa, u8, parts[3..]);
    defer gpa.free(tail);
    try ws.feed(gpa, tail);
    try expectText(&ws, "hello, world");
    try expectText(&ws, "next");
}

test "ping, pong and close" {
    const gpa = testing.allocator;
    var ws: WebSocket = .{};
    defer ws.deinit(gpa);
    try ws.feed(gpa, "\x89\x02hi\x8a\x00\x88\x07\x03\xe9going\x88\x00");
    try testing.expectEqualStrings("hi", (try ws.next()).?.ping);
    try testing.expectEqualStrings("", (try ws.next()).?.pong);
    const c = (try ws.next()).?.close;
    try testing.expectEqual(@as(?u16, 1001), c.code);
    try testing.expectEqualStrings("going", c.reason);
    try testing.expectEqual(@as(?u16, null), (try ws.next()).?.close.code);
}

test "oddities are rejected" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, anyerror }{
        .{ "\x81\x81\x00\x00\x00\x00x", error.MaskedFrame },
        .{ "\x82\x01x", error.BinaryMessage },
        .{ "\xc1\x01x", error.ReservedBits },
        .{ "\x83\x00", error.BadOpcode },
        .{ "\x09\x00", error.BadControlFrame }, // fragmented ping
        .{ "\x88\x01x", error.BadControlFrame },
        .{ "\x80\x01x", error.UnexpectedContinuation },
        .{ "\x01\x01x\x81\x01y", error.UnfinishedMessage },
        .{ "\x81\x02\xc3\x28", error.InvalidUtf8 },
        .{ "\x81\x7f\x00\x00\x00\x00\x00\x10\x00\x01", error.MessageTooLarge },
    };
    for (cases) |c| {
        var ws: WebSocket = .{};
        defer ws.deinit(gpa);
        try ws.feed(gpa, c[0]);
        try testing.expectError(c[1], ws.next());
    }
    // fragments count toward the limit too
    var ws: WebSocket = .{ .max_message = 4 };
    defer ws.deinit(gpa);
    try ws.feed(gpa, "\x01\x03abc\x80\x02de");
    try testing.expectError(error.MessageTooLarge, ws.next());
}

test "sent frames are masked" {
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    var buf: [70000]u8 = undefined;
    var w: Writer = .fixed(&buf);
    // RFC 6455 section 5.7: masked "Hello"
    try writeFrameMasked(&w, .text, "Hello", mask);
    try testing.expectEqualSlices(u8, "\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58", w.buffered());

    for ([_]usize{ 126, 300, 65536 }) |len| {
        w = .fixed(&buf);
        const payload: [65536]u8 = @splat('z');
        try writeFrameMasked(&w, .pong, payload[0..len], mask);
        const out = w.buffered();
        const header: usize = if (len < 65536) 8 else 14;
        try testing.expectEqual(header + len, out.len);
        try testing.expectEqual(@as(u8, 0x8a), out[0]);
        try testing.expectEqualSlices(u8, &mask, out[header - 4 .. header]);
        for (out[header..], 0..) |b, i| try testing.expectEqual(@as(u8, 'z'), b ^ mask[i % 4]);
    }

    w = .fixed(&buf);
    try writeClose(&w, testing.io, 1000);
    const out = w.buffered();
    try testing.expectEqualSlices(u8, "\x88\x82", out[0..2]);
    try testing.expectEqual(@as(u8, 0x03), out[6] ^ out[2]);
    try testing.expectEqual(@as(u8, 0xe8), out[7] ^ out[3]);
}
