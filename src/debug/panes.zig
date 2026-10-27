//! `neorex debug-panes SOCKET`: a stand-in daemon. Takes terminals from
//! `neorex pane` helpers and drives them: shows input and resizes. `q` in a
//! pane closes it; Ctrl+C here closes them all.

const std = @import("std");
const net = std.Io.net;
const Loop = @import("../daemon/Loop.zig");
const PaneHost = @import("PaneHost.zig");

const token_signal = 0;
const token_server = 1;
const token_panes = 2;

pub fn run(io: std.Io, socket_path: []const u8) !void {
    var loop: Loop = try .init();
    defer loop.deinit();
    try loop.addSignal(.INT, token_signal);
    try loop.addSignal(.TERM, token_signal);

    var server = try listen(io, socket_path);
    defer server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    try loop.addRead(server.socket.handle, token_server);
    std.debug.print("debug-panes: listening on {s}. Run `neorex pane {s}` in Rex panes. Ctrl+C quits.\n", .{ socket_path, socket_path });

    var out_bufs: PaneHost.OutBufs = undefined;
    var host: PaneHost = .{ .out_bufs = &out_bufs, .base = token_panes, .name = "debug-panes" };
    defer host.deinit(io);

    var events: [16]Loop.Event = undefined;
    while (true) {
        var pending_accept = false;
        for (try loop.wait(&events)) |e| switch (e.token) {
            token_signal => {
                std.debug.print("closing all panes\n", .{});
                return;
            },
            token_server => pending_accept = true,
            else => try host.handle(io, e.token),
        };
        if (pending_accept) try host.accept(io, &loop, &server);
    }
}

/// Listens on `socket_path`, replacing a socket left by an earlier run.
pub fn listen(io: std.Io, socket_path: []const u8) !net.Server {
    const addr = try net.UnixAddress.init(socket_path);
    std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    return addr.listen(io, .{});
}
