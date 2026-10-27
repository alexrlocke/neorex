//! `neorex debug-panes SOCKET`: a stand-in daemon. Takes terminals from
//! `neorex pane` helpers and drives them: shows input and resizes. `q` in a
//! pane closes it; Ctrl+C here closes them all.

const std = @import("std");
const net = std.Io.net;
const Terminal = @import("Terminal.zig");
const Loop = @import("Loop.zig");
const input = @import("input.zig");
const fdpass = @import("fdpass.zig");
const pane = @import("pane.zig");

const max_panes = 8;

const Pane = struct {
    id: u32,
    stream: net.Stream,
    term: Terminal,
    parser: input.Parser = .{},
};

pub fn run(io: std.Io, socket_path: []const u8) !void {
    var loop: Loop = try .init();
    defer loop.deinit();
    try loop.addSignal(.INT, token_signal);
    try loop.addSignal(.TERM, token_signal);

    const addr = try net.UnixAddress.init(socket_path);
    // a socket left by an earlier run would block bind
    std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    try loop.addRead(server.socket.handle, token_server);
    std.debug.print("debug-panes: listening on {s}. Run `neorex pane {s}` in Rex panes. Ctrl+C quits.\n", .{ socket_path, socket_path });

    // fixed slots: each Terminal's writer points into out_bufs
    var panes: [max_panes]?Pane = @splat(null);
    var out_bufs: [max_panes][4096]u8 = undefined;
    defer for (&panes) |*p| if (p.*) |*live| close(io, live, p);
    var next_id: u32 = 1;

    var events: [16]Loop.Event = undefined;
    while (true) {
        // accepted after the batch, so a stale event can't reach a reused slot
        var pending_accept = false;
        for (try loop.wait(&events)) |e| switch (e.token) {
            token_signal => {
                std.debug.print("closing all panes\n", .{});
                return;
            },
            token_server => pending_accept = true,
            else => {
                const i, const source = paneToken(e.token);
                const slot = &panes[i];
                // null if closed earlier in this batch
                if (slot.*) |*live| switch (source) {
                    .socket => if (!try onMessage(io, live)) {
                        std.debug.print("pane {d}: helper gone\n", .{live.id});
                        close(io, live, slot);
                    },
                    .tty => if (!try onInput(live)) {
                        std.debug.print("pane {d}: closed with q\n", .{live.id});
                        close(io, live, slot);
                    },
                };
            },
        };
        if (pending_accept) try accept(io, &loop, &server, &panes, &out_bufs, &next_id);
    }
}

const token_signal = 0;
const token_server = 1;

/// Each pane has two tokens from 2 up: its socket, then its terminal.
fn tokenFor(i: usize, source: Source) usize {
    return 2 + 2 * i + @intFromEnum(source);
}

fn paneToken(token: usize) struct { usize, Source } {
    return .{ (token - 2) / 2, @enumFromInt((token - 2) % 2) };
}

const Source = enum(u1) { socket, tty };

/// Takes a new helper's terminal and greets it.
fn accept(io: std.Io, loop: *const Loop, server: *net.Server, panes: []?Pane, out_bufs: [][4096]u8, next_id: *u32) !void {
    const stream = try server.accept(io);
    errdefer stream.close(io);
    var buf: [1]u8 = undefined;
    const hello = try fdpass.recv(stream, io, &buf);
    const tty = hello.fd orelse return error.NoTerminal;
    errdefer _ = std.c.close(tty);
    if (hello.len != 1 or buf[0] != @intFromEnum(pane.Message.hello)) return error.BadHello;

    const i = for (panes, 0..) |p, i| {
        if (p == null) break i;
    } else return error.TooManyPanes;
    panes[i] = .{ .id = next_id.*, .stream = stream, .term = try .init(tty, &out_bufs[i]) };
    next_id.* += 1;

    const p = &panes[i].?;
    try loop.addRead(stream.socket.handle, tokenFor(i, .socket));
    try loop.addRead(tty, tokenFor(i, .tty));
    std.debug.print("pane {d}: attached\n", .{p.id});
    try p.term.writer.print("\x1b[H\x1b[2Jneorex pane {d}, driven by debug-panes.\r\n", .{p.id});
    try printSize(p);
    try p.term.writer.writeAll("Type to see events. q closes this pane.\r\n");
    try p.term.flush();
}

/// A message from the helper. False when it hung up.
fn onMessage(io: std.Io, p: *Pane) !bool {
    var buf: [64]u8 = undefined;
    const r = try fdpass.recv(p.stream, io, &buf);
    if (r.fd) |fd| _ = std.c.close(fd);
    if (r.len == 0) return false;
    for (buf[0..r.len]) |b| switch (@as(pane.Message, @enumFromInt(b))) {
        .resized => try printSize(p),
        else => {},
    };
    try p.term.flush();
    return true;
}

/// Keys typed in the pane. False on q.
fn onInput(p: *Pane) !bool {
    var buf: [4096]u8 = undefined;
    const n = std.c.read(p.term.fd, &buf, buf.len);
    if (n <= 0) return false;
    p.parser.feed(buf[0..@intCast(n)]);
    while (p.parser.next()) |event| {
        if (event == .key and event.key.key == .codepoint and event.key.key.codepoint == 'q' and @as(u8, @bitCast(event.key.mods)) == 0) return false;
        try p.term.writer.print("  {f}\r\n", .{event});
    }
    try p.term.flush();
    return true;
}

fn printSize(p: *Pane) !void {
    const ws = try p.term.size();
    try p.term.writer.print("size {d}x{d}\r\n", .{ ws.col, ws.row });
}

/// Restores the terminal and hangs up, so the helper exits.
fn close(io: std.Io, p: *Pane, slot: *?Pane) void {
    p.term.deinit();
    _ = std.c.close(p.term.fd);
    p.stream.close(io);
    slot.* = null;
}
