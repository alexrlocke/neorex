//! `neorex debug-rex SOCKET`: talks to Rex directly. Attaches to this
//! session, opens a split running `neorex pane SOCKET`, takes that pane's
//! terminal over as debug-panes does, and prints Rex's events. Ctrl+C quits.

const std = @import("std");
const Loop = @import("../daemon/Loop.zig");
const Client = @import("../rex/Client.zig");
const PaneHost = @import("PaneHost.zig");
const debug_panes = @import("panes.zig");

const token_signal = 0;
const token_server = 1;
const token_rex = 2;
const token_panes = 3;

pub fn run(gpa: std.mem.Allocator, io: std.Io, socket_path: []const u8) !void {
    // the pane starts elsewhere, so the path must work from any directory
    if (!std.fs.path.isAbsolute(socket_path)) return error.SocketPathNotAbsolute;
    const server_url = std.mem.span(std.c.getenv("REX_SERVER") orelse return error.NoRexServer);
    const session_id = std.mem.span(std.c.getenv("REX_SESSION") orelse return error.NoRexSession);
    const anchor_id: ?[]const u8 = if (std.c.getenv("REX_BLOCK")) |b| std.mem.span(b) else null;
    var exe_buf: [1024]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(io, &exe_buf)];

    var loop: Loop = try .init();
    defer loop.deinit();
    try loop.addSignal(.INT, token_signal);
    try loop.addSignal(.TERM, token_signal);

    var server = try debug_panes.listen(io, socket_path);
    defer server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
    try loop.addRead(server.socket.handle, token_server);

    var rex_buf: [4096]u8 = undefined;
    var rex: Client = try .connect(gpa, io, server_url, &rex_buf);
    defer rex.deinit(gpa);
    try loop.addRead(rex.fd(), token_rex);
    std.debug.print("debug-rex: connected to {s}. Ctrl+C quits.\n", .{server_url});

    var out_bufs: PaneHost.OutBufs = undefined;
    var host: PaneHost = .{ .out_bufs = &out_bufs, .base = token_panes, .name = "debug-rex" };
    defer host.deinit(io);

    const attach_id = try rex.request(gpa, "session.attach", .{ .session_id = session_id });
    var split_id: ?u64 = null;

    var events: [16]Loop.Event = undefined;
    while (true) {
        var pending_accept = false;
        for (try loop.wait(&events)) |e| switch (e.token) {
            token_signal => {
                std.debug.print("closing all panes\n", .{});
                return;
            },
            token_server => pending_accept = true,
            token_rex => {
                if (!try rex.read(gpa)) {
                    std.debug.print("rex: server hung up\n", .{});
                    return;
                }
                while (try rex.next(gpa)) |m| switch (m) {
                    .response => |r| {
                        switch (r.result) {
                            .ok => |v| std.debug.print("rex: response {d}: {f}\n", .{ r.id, std.json.fmt(v, .{}) }),
                            .err => |err| std.debug.print("rex: response {d} failed: {s} ({d}): {s}\n", .{ r.id, err.code, err.status, err.message }),
                        }
                        if (r.result == .err and (r.id == attach_id or r.id == split_id)) return error.RexRequestFailed;
                        // creating made us the owner, which sizes it; let the app size it instead
                        if (r.id == split_id) _ = try rex.request(gpa, "session.disown_block", .{
                            .session_id = session_id,
                            .block_ids = Client.get(r.result.ok, "block_ids") orelse .null,
                        });
                        // the split names the session, so it waits for the attach
                        if (r.id == attach_id) split_id = try rex.request(gpa, "session.new_split", .{
                            .session_id = session_id,
                            .anchor_id = anchor_id,
                            .direction = "horizontal",
                            .side = "after",
                            .layout = .{ .block = .{
                                .flavor = "com.superlogical.terminal.shell",
                                .label = "neorex",
                                .options = .{ .shell = "none", .command = &[_][]const u8{ exe, "pane", socket_path } },
                            } },
                        });
                    },
                    .event => |ev| std.debug.print("rex: event {d} {s}: {f}\n", .{ ev.seq, ev.name, std.json.fmt(ev.payload, .{}) }),
                    .closed => |c| {
                        std.debug.print("rex: closed {?d} {s}\n", .{ c.code, c.reason });
                        return;
                    },
                };
            },
            else => if (host.owns(e.token)) try host.handle(io, e.token),
        };
        if (pending_accept) try host.accept(io, &loop, &server);
    }
}
