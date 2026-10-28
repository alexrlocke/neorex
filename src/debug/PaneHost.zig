//! Panes for the debug daemons: takes terminals from `neorex pane` helpers,
//! shows their input and sizes. `q` in a pane closes it.

const std = @import("std");
const net = std.Io.net;
const Terminal = @import("../term/Terminal.zig");
const Loop = @import("../daemon/Loop.zig");
const input = @import("../term/input.zig");
const fdpass = @import("../daemon/fdpass.zig");
const pane = @import("../daemon/pane_helper.zig");

const PaneHost = @This();

pub const max_panes = 8;
pub const OutBufs = [max_panes][4096]u8;

/// Fixed slots: each Terminal's writer points into `out_bufs`.
panes: [max_panes]?Pane = @splat(null),
out_bufs: *OutBufs,
/// Loop tokens from here up, two per slot.
base: usize,
/// Shown in each pane's greeting.
name: []const u8,
next_id: u32 = 1,

const Pane = struct {
    id: u32,
    stream: net.Stream,
    term: Terminal,
    parser: input.Parser = .{},
};

const Source = enum(u1) { socket, tty };

/// Restores every terminal and hangs up, so the helpers exit.
pub fn deinit(self: *PaneHost, io: std.Io) void {
    for (&self.panes) |*slot| if (slot.*) |*p| close(io, p, slot);
    self.* = undefined;
}

/// Whether `token` is one of this host's.
pub fn owns(self: *const PaneHost, token: usize) bool {
    return token >= self.base and token < self.base + 2 * max_panes;
}

/// Handles an event for one of this host's tokens.
pub fn handle(self: *PaneHost, io: std.Io, token: usize) !void {
    const i = (token - self.base) / 2;
    const source: Source = @enumFromInt((token - self.base) % 2);
    const slot = &self.panes[i];
    // null if closed earlier in this batch
    const p = &(slot.* orelse return);
    switch (source) {
        .socket => if (!try onMessage(io, p)) {
            std.debug.print("pane {d}: helper gone\n", .{p.id});
            close(io, p, slot);
        },
        .tty => if (!try onInput(p)) {
            std.debug.print("pane {d}: closed with q\n", .{p.id});
            close(io, p, slot);
        },
    }
}

/// Takes a new helper's terminal and greets it. Call between batches of
/// events, so a stale event can't reach a reused slot.
pub fn accept(self: *PaneHost, io: std.Io, loop: *const Loop, server: *net.Server) !void {
    const stream = try server.accept(io);
    errdefer stream.close(io);
    var buf: [1]u8 = undefined;
    const hello = try fdpass.recv(stream, io, &buf);
    const tty = hello.fd orelse return error.NoTerminal;
    errdefer _ = std.c.close(tty);
    if (hello.len != 1 or buf[0] != @intFromEnum(pane.Message.hello)) return error.BadHello;

    const i = for (self.panes, 0..) |p, i| {
        if (p == null) break i;
    } else return error.TooManyPanes;
    self.panes[i] = .{ .id = self.next_id, .stream = stream, .term = try .init(tty, &self.out_bufs[i]) };
    self.next_id += 1;

    const p = &self.panes[i].?;
    try loop.addRead(stream.socket.handle, self.base + 2 * i + @intFromEnum(Source.socket));
    try loop.addRead(tty, self.base + 2 * i + @intFromEnum(Source.tty));
    std.debug.print("pane {d}: attached\n", .{p.id});
    try p.term.writer.print("\x1b[H\x1b[2Jneorex pane {d}, driven by {s}.\r\n", .{ p.id, self.name });
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
