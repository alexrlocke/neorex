//! A Rex control connection: a WebSocket on the server's Unix socket
//! carrying JSON requests, responses and events. The caller's loop reads;
//! see `read` and `next`.

const std = @import("std");
const net = std.Io.net;
const Value = std.json.Value;
const WebSocket = @import("WebSocket.zig");

const Client = @This();

pub const protocol = "rex.control.v1";
pub const api_revision = 7;

io: std.Io,
stream: net.Stream,
/// Writes to the server; its buffer is the caller's.
writer: net.Stream.Writer,
ws: WebSocket = .{},
/// Request ids are this counter as strings.
next_id: u64 = 1,
/// The server's `limits.max_message_bytes`.
max_message: usize = 65536,
/// Scratch for building outgoing JSON.
out: std.ArrayList(u8) = .empty,
/// The parsed message last returned by `next`.
parsed: ?std.json.Parsed(Value) = null,
/// Upgraded, and no close frame sent yet.
open: bool = false,

pub const Message = union(enum) {
    response: Response,
    event: Event,
    /// The server closed the connection.
    closed: WebSocket.Close,
};

pub const Result = union(enum) { ok: Value, err: Error };

pub const Response = struct {
    id: u64,
    seq: i64,
    result: Result,
};

pub const Error = struct {
    code: []const u8,
    message: []const u8,
    status: i64,
};

/// A server event, or a session event unwrapped from `session_event`.
pub const Event = struct {
    seq: i64,
    /// Set for session events.
    session_id: ?[]const u8,
    name: []const u8,
    /// `.null` when the event has no fields.
    payload: Value,
};

pub const Welcome = struct {
    max_message_bytes: usize,
    api_revision: i64,
};

/// Connects to `server_url` (`REX_SERVER`), then exchanges hello and welcome.
/// Blocks until welcomed. Writes go through `buffer`.
pub fn connect(gpa: std.mem.Allocator, io: std.Io, server_url: []const u8, buffer: []u8) !Client {
    var path_buf: [256]u8 = undefined;
    const path = try socketPath(server_url, &path_buf);
    const addr = try net.UnixAddress.init(path);
    const stream = try addr.connect(io);
    var self: Client = .{ .io = io, .stream = stream, .writer = stream.writer(io, buffer) };
    errdefer self.deinit(gpa);
    const w = &self.writer.interface;

    const key = WebSocket.newKey(io);
    // any host works on the Unix socket
    try WebSocket.writeRequest(w, "localhost", "/api/control", protocol, &key);
    try w.flush();

    var head: [4096]u8 = undefined;
    var len: usize = 0;
    const end = while (true) {
        if (len == head.len) return error.ResponseTooLarge;
        const n = try std.posix.read(self.fd(), head[len..]);
        if (n == 0) return error.ConnectionClosed;
        len += n;
        if (WebSocket.headEnd(head[0..len])) |e| break e;
    };
    try WebSocket.checkResponse(head[0..end], &key, protocol);
    self.open = true;
    try self.ws.feed(gpa, head[end..len]);

    var hello: [512]u8 = undefined;
    var hw: std.Io.Writer = .fixed(&hello);
    try std.json.Stringify.value(.{
        .type = "hello",
        .api_revision = api_revision,
        .client = .{ .kind = "other", .name = "neorex" },
    }, .{}, &hw);
    try WebSocket.writeFrame(w, io, .text, hw.buffered());
    try w.flush();

    const welcome = while (true) {
        if (try self.ws.next()) |m| switch (m) {
            .text => |t| {
                const p = try std.json.parseFromSlice(Value, gpa, t, .{});
                defer p.deinit();
                break try parseWelcome(p.value);
            },
            .close => return error.ConnectionClosed,
            else => {},
        };
        if (!try self.read(gpa)) return error.ConnectionClosed;
    };
    self.max_message = welcome.max_message_bytes;
    self.ws.max_message = welcome.max_message_bytes;
    return self;
}

/// Sends a close frame, then closes the socket.
pub fn deinit(self: *Client, gpa: std.mem.Allocator) void {
    if (self.open) {
        WebSocket.writeClose(&self.writer.interface, self.io, 1000) catch {};
        self.writer.interface.flush() catch {};
    }
    self.stream.close(self.io);
    self.ws.deinit(gpa);
    self.out.deinit(gpa);
    if (self.parsed) |p| p.deinit();
    self.* = undefined;
}

/// The socket, for the caller's loop to watch.
pub fn fd(self: *const Client) std.posix.fd_t {
    return self.stream.socket.handle;
}

/// Sends a request and returns its id. A null `payload` is left out.
pub fn request(self: *Client, gpa: std.mem.Allocator, method: []const u8, payload: anytype) !u64 {
    const id = self.next_id;
    self.next_id += 1;

    self.out.clearRetainingCapacity();
    var a: std.Io.Writer.Allocating = .fromArrayList(gpa, &self.out);
    defer self.out = a.toArrayList();
    var s: std.json.Stringify = .{ .writer = &a.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("type");
    try s.write("request");
    try s.objectField("id");
    try s.print("\"{d}\"", .{id});
    try s.objectField("method");
    try s.write(method);
    if (@TypeOf(payload) != @TypeOf(null)) {
        try s.objectField("payload");
        try s.write(payload);
    }
    try s.endObject();

    // the server closes the connection on a request over its limit
    if (a.written().len > self.max_message) return error.MessageTooLarge;
    try WebSocket.writeFrame(&self.writer.interface, self.io, .text, a.written());
    try self.writer.interface.flush();
    return id;
}

/// One read from the socket. False when the server hung up.
pub fn read(self: *Client, gpa: std.mem.Allocator) !bool {
    var buf: [16384]u8 = undefined;
    const n = std.posix.read(self.fd(), &buf) catch |err| switch (err) {
        error.ConnectionResetByPeer => return false,
        else => return err,
    };
    if (n == 0) return false;
    try self.ws.feed(gpa, buf[0..n]);
    return true;
}

/// The next message read, or null until more is read. Answers pings and
/// skips unknown types. Valid until `next` or `read`.
pub fn next(self: *Client, gpa: std.mem.Allocator) !?Message {
    while (try self.ws.next()) |m| switch (m) {
        .ping => |p| {
            try WebSocket.writeFrame(&self.writer.interface, self.io, .pong, p);
            try self.writer.interface.flush();
        },
        .pong => {},
        .close => |c| {
            if (self.open) {
                // echo the code, as RFC 6455 asks
                WebSocket.writeClose(&self.writer.interface, self.io, c.code orelse 1000) catch {};
                self.writer.interface.flush() catch {};
                self.open = false;
            }
            return .{ .closed = c };
        },
        .text => |t| {
            if (self.parsed) |p| p.deinit();
            self.parsed = null;
            self.parsed = try std.json.parseFromSlice(Value, gpa, t, .{});
            if (try parseMessage(self.parsed.?.value)) |msg| return msg;
        },
    };
    return null;
}

/// The path in a `unix://` URL, percent-decoded into `buf`.
pub fn socketPath(url: []const u8, buf: []u8) ![]const u8 {
    const scheme = "unix://";
    if (!std.mem.startsWith(u8, url, scheme)) return error.NotUnixUrl;
    const encoded = url[scheme.len..];
    if (encoded.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..encoded.len], encoded);
    return std.Uri.percentDecodeInPlace(buf[0..encoded.len]);
}

pub fn parseWelcome(root: Value) !Welcome {
    if (!eql(getStr(root, "type"), "welcome")) return error.NotWelcome;
    if (!eql(getStr(root, "protocol"), protocol)) return error.BadProtocol;
    const max = getInt(get(root, "limits"), "max_message_bytes") orelse return error.NotWelcome;
    if (max < 65536) return error.NotWelcome;
    return .{ .max_message_bytes = @intCast(max), .api_revision = getInt(root, "api_revision") orelse 0 };
}

/// A response or event, or null for a type we don't know.
pub fn parseMessage(root: Value) !?Message {
    const kind = getStr(root, "type") orelse return error.BadMessage;
    if (eql(kind, "response")) {
        const id_str = getStr(root, "id") orelse return error.BadMessage;
        // not one of ours
        const id = std.fmt.parseInt(u64, id_str, 10) catch return null;
        const seq = getInt(root, "seq") orelse 0;
        if (get(root, "error")) |e| if (e == .object) return .{ .response = .{ .id = id, .seq = seq, .result = .{ .err = .{
            .code = getStr(e, "code") orelse "",
            .message = getStr(e, "message") orelse "",
            .status = getInt(e, "status") orelse 0,
        } } } };
        return .{ .response = .{ .id = id, .seq = seq, .result = .{ .ok = get(root, "payload") orelse .null } } };
    }
    if (eql(kind, "event")) {
        const seq = getInt(root, "seq") orelse 0;
        var event = get(root, "payload") orelse return error.BadMessage;
        var name = getStr(event, "type") orelse return error.BadMessage;
        var session_id: ?[]const u8 = null;
        if (eql(name, "session_event")) {
            const inner = get(event, "payload");
            session_id = getStr(inner, "session_id");
            event = get(inner, "event") orelse return error.BadMessage;
            name = getStr(event, "type") orelse return error.BadMessage;
        }
        return .{ .event = .{ .seq = seq, .session_id = session_id, .name = name, .payload = get(event, "payload") orelse .null } };
    }
    return null;
}

/// A field of an object, or null.
pub fn get(v: ?Value, name: []const u8) ?Value {
    const obj = v orelse return null;
    if (obj != .object) return null;
    return obj.object.get(name);
}

pub fn str(v: ?Value) ?[]const u8 {
    const s = v orelse return null;
    return if (s == .string) s.string else null;
}

pub fn int(v: ?Value) ?i64 {
    const n = v orelse return null;
    return if (n == .integer) n.integer else null;
}

/// The integer field `name` of an object, or null.
pub fn getInt(v: ?Value, name: []const u8) ?i64 {
    return int(get(v, name));
}

/// The string field `name` of an object, or null.
pub fn getStr(v: ?Value, name: []const u8) ?[]const u8 {
    return str(get(v, name));
}

fn eql(a: ?[]const u8, b: []const u8) bool {
    return std.mem.eql(u8, a orelse return false, b);
}

const testing = std.testing;

fn parseSample(gpa: std.mem.Allocator, json: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, gpa, json, .{});
}

test "socket path from REX_SERVER" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "/Users/a/Library/Application Support/rex/server.sock",
        try socketPath("unix:///Users/a/Library/Application%20Support/rex/server.sock", &buf),
    );
    try testing.expectError(error.NotUnixUrl, socketPath("ws://localhost", &buf));
    var small: [4]u8 = undefined;
    try testing.expectError(error.NameTooLong, socketPath("unix:///abcde", &small));
}

test "welcome" {
    const gpa = testing.allocator;
    const p = try parseSample(gpa,
        \\{"type":"welcome","protocol":"rex.control.v1","limits":{"max_message_bytes":1048576},
        \\ "client":{"id":"client:x","reconnect_token":"t"},"api_revision":7,"new_field":[1]}
    );
    defer p.deinit();
    const w = try parseWelcome(p.value);
    try testing.expectEqual(@as(usize, 1048576), w.max_message_bytes);
    try testing.expectEqual(@as(i64, 7), w.api_revision);

    const bad = try parseSample(gpa,
        \\{"type":"welcome","protocol":"other","limits":{"max_message_bytes":1048576}}
    );
    defer bad.deinit();
    try testing.expectError(error.BadProtocol, parseWelcome(bad.value));
}

test "responses: payload and error" {
    const gpa = testing.allocator;
    const ok = try parseSample(gpa,
        \\{"type":"response","id":"3","seq":5,"payload":{"rex_version":"1.0"}}
    );
    defer ok.deinit();
    const r = (try parseMessage(ok.value)).?.response;
    try testing.expectEqual(@as(u64, 3), r.id);
    try testing.expectEqual(@as(i64, 5), r.seq);
    try testing.expectEqualStrings("1.0", getStr(r.result.ok, "rex_version").?);

    const err = try parseSample(gpa,
        \\{"type":"response","id":"2","seq":0,"error":{"code":"not_found","message":"block not found","status":404}}
    );
    defer err.deinit();
    const e = (try parseMessage(err.value)).?.response.result.err;
    try testing.expectEqualStrings("not_found", e.code);
    try testing.expectEqualStrings("block not found", e.message);
    try testing.expectEqual(@as(i64, 404), e.status);

    const foreign = try parseSample(gpa,
        \\{"type":"response","id":"abc","seq":0}
    );
    defer foreign.deinit();
    try testing.expectEqual(@as(?Message, null), try parseMessage(foreign.value));
}

test "events: plain, session-wrapped, and unknown types" {
    const gpa = testing.allocator;
    const plain = try parseSample(gpa,
        \\{"type":"event","seq":1,"payload":{"type":"session_created","payload":{"session":{"session_id":"session:s"}}}}
    );
    defer plain.deinit();
    const a = (try parseMessage(plain.value)).?.event;
    try testing.expectEqual(@as(i64, 1), a.seq);
    try testing.expectEqualStrings("session_created", a.name);
    try testing.expectEqual(@as(?[]const u8, null), a.session_id);

    const wrapped = try parseSample(gpa,
        \\{"type":"event","seq":2,"payload":{"type":"session_event","payload":{"session_id":"session:s",
        \\ "event":{"type":"block_created","payload":{"block_id":"block:b"}}}}}
    );
    defer wrapped.deinit();
    const b = (try parseMessage(wrapped.value)).?.event;
    try testing.expectEqualStrings("block_created", b.name);
    try testing.expectEqualStrings("session:s", b.session_id.?);
    try testing.expectEqualStrings("block:b", getStr(b.payload, "block_id").?);

    const bare = try parseSample(gpa,
        \\{"type":"event","seq":3,"payload":{"type":"keymap_changed"}}
    );
    defer bare.deinit();
    try testing.expect((try parseMessage(bare.value)).?.event.payload == .null);

    const unknown = try parseSample(gpa,
        \\{"type":"something_new","x":1}
    );
    defer unknown.deinit();
    try testing.expectEqual(@as(?Message, null), try parseMessage(unknown.value));

    const broken = try parseSample(gpa,
        \\{"seq":1}
    );
    defer broken.deinit();
    try testing.expectError(error.BadMessage, parseMessage(broken.value));
}

/// Reads until the response to `id`, skipping events.
fn waitFor(c: *Client, gpa: std.mem.Allocator, id: u64) !Response {
    while (true) {
        while (try c.next(gpa)) |m| switch (m) {
            .response => |r| if (r.id == id) return r,
            .event => {},
            .closed => return error.ConnectionClosed,
        };
        if (!try c.read(gpa)) return error.ConnectionClosed;
    }
}

test "live: server.version and an unknown method" {
    const gpa = testing.allocator;
    const url = std.c.getenv("REX_SERVER") orelse return error.SkipZigTest;
    var buf: [4096]u8 = undefined;
    var c: Client = try .connect(gpa, testing.io, std.mem.span(url), &buf);
    defer c.deinit(gpa);
    try testing.expect(c.max_message >= 65536);

    const id = try c.request(gpa, "server.version", null);
    const r = try waitFor(&c, gpa, id);
    try testing.expect(getStr(r.result.ok, "rex_version").?.len > 0);

    const bad = try c.request(gpa, "neorex.no_such_method", .{ .x = 1 });
    const e = (try waitFor(&c, gpa, bad)).result.err;
    try testing.expectEqualStrings("method_not_found", e.code);
    try testing.expectEqual(@as(i64, 404), e.status);
}
