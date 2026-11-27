//! `neorex debug-events`: attaches to Neovim as a UI and prints every redraw
//! event it sends. Keys and pastes go to Neovim. Ctrl+Q or :q quits.

const std = @import("std");
const Writer = std.Io.Writer;

const term = @import("term");
const msgpack = @import("msgpack");
const nvim = @import("nvim");

// no alternate screen, so the events stay in scrollback
const modes_on = "\x1b[?2004h\x1b[?1004h" ++ term.input.kitty_push;
const modes_off = term.input.kitty_pop ++ "\x1b[?1004l\x1b[?2004l";

/// Runs `nvim --embed` plus `nvim_args`.
pub fn run(gpa: std.mem.Allocator, io: std.Io, nvim_args: []const []const u8) !void {
    var out_buf: [16 * 1024]u8 = undefined;
    var terminal = try term.Terminal.init(std.posix.STDIN_FILENO, &out_buf);
    defer terminal.deinit();

    var signals = try term.Signals.init(&.{.WINCH});
    defer signals.deinit();

    const out = &terminal.writer;
    try out.writeAll(modes_on);
    defer out.writeAll(modes_off) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var cmd_buf: [nvim.runtime.cmd_len]u8 = undefined;
    try argv.appendSlice(gpa, &.{ "nvim", "--embed", "--cmd", try nvim.runtime.cmd(io, &cmd_buf) });
    try argv.appendSlice(gpa, nvim_args);

    var nvim_buf: [4096]u8 = undefined;
    var nvim_client = try nvim.Nvim.spawn(io, argv.items, &nvim_buf);
    defer nvim_client.deinit(gpa);

    const ws = try terminal.size();
    try nvim_client.uiAttach(ws.col, ws.row, .{});
    try out.print("debug-events: attached at {d}x{d}. Ctrl+Q or :q quits.\r\n", .{ ws.col, ws.row });
    try terminal.flush();

    var forwarder: nvim.Forwarder = .{};
    var buf: [4096]u8 = undefined;
    while (true) {
        var fds = [_]std.c.pollfd{
            .{ .fd = terminal.fd, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = signals.read_fd, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = nvim_client.readFd(), .events = std.c.POLL.IN, .revents = 0 },
        };
        const ready = std.c.poll(&fds, fds.len, -1);
        if (ready < 0) {
            if (std.c.errno(ready) == .INTR) continue;
            return error.PollFailed;
        }

        if (fds[1].revents != 0) {
            const fired = try signals.drain();
            if (fired.contains(.WINCH)) {
                const size = try terminal.size();
                try nvim_client.uiTryResize(size.col, size.row);
            }
        }

        if (fds[2].revents != 0) {
            if (!try nvim_client.read(gpa)) {
                try out.writeAll("neovim exited\r\n");
                return;
            }
            while (try nvim_client.next()) |msg| try printMessage(&nvim_client, out, msg);
            try terminal.flush();
        }

        if (fds[0].revents != 0) {
            const n = std.c.read(terminal.fd, &buf, buf.len);
            if (n < 0) {
                if (std.c.errno(n) == .INTR) continue;
                return error.ReadFailed;
            }
            if (n == 0) return;
            if (!try forwarder.feed(&nvim_client, buf[0..@intCast(n)])) return;
        }
    }
}

/// One line per redraw event; errors and other messages in brief.
fn printMessage(nvim_client: *nvim.Nvim, out: *Writer, msg: nvim.rpc.Message) !void {
    switch (msg) {
        .response => |r| if (r.err) |e| {
            try out.writeAll("error: ");
            try writeEscaped(out, e);
            try out.writeAll("\r\n");
        },
        .request => |r| {
            // nothing here serves requests; answer so Neovim doesn't wait
            try out.print("request {s} (refused)\r\n", .{r.method});
            try nvim_client.respondError(r.id, "neorex debug-events serves no requests");
        },
        .notification => |note| {
            if (!std.mem.eql(u8, note.method, "redraw")) {
                try out.print("notification {s}\r\n", .{note.method});
                return;
            }
            // params: [[name, args, args, ...], ...]
            var d = note.params;
            const events = try msgpack.expectArray(&d);
            for (0..events) |_| {
                const len = try msgpack.expectArray(&d);
                if (len == 0) return error.BadMessage;
                const name = try msgpack.expectStr(&d);
                for (1..len) |_| {
                    try out.print("{s} ", .{name});
                    try printValue(&d, out);
                    try out.writeAll("\r\n");
                }
            }
        },
    }
}

/// Prints one value compactly, as in `[1, "a", {k: true}]`.
fn printValue(d: *msgpack.Decoder, out: *Writer) !void {
    switch ((try d.next()) orelse return error.BadMessage) {
        .nil => try out.writeAll("nil"),
        .bool => |b| try out.print("{}", .{b}),
        .int => |n| try out.print("{d}", .{n}),
        .uint => |n| try out.print("{d}", .{n}),
        .float => |f| try out.print("{d}", .{f}),
        .array => |n| {
            try out.writeByte('[');
            for (0..n) |i| {
                if (i > 0) try out.writeAll(", ");
                try printValue(d, out);
            }
            try out.writeByte(']');
        },
        .map => |n| {
            try out.writeByte('{');
            for (0..n) |i| {
                if (i > 0) try out.writeAll(", ");
                try printValue(d, out);
                try out.writeAll(": ");
                try printValue(d, out);
            }
            try out.writeByte('}');
        },
        .str => |len| {
            try out.writeByte('"');
            try writeEscaped(out, try msgpack.expectBytes(d, len));
            try out.writeByte('"');
        },
        .bin => |len| try out.print("bin({d})", .{(try msgpack.expectBytes(d, len)).len}),
        // buffer, window and tabpage handles: an int packed inside
        .ext => |e| {
            const payload = try msgpack.expectBytes(d, e.len);
            var inner: msgpack.Decoder = .{};
            inner.feed(payload);
            const names = [_][]const u8{ "buf", "win", "tab" };
            const name = if (e.type >= 0 and e.type < names.len) names[@intCast(e.type)] else "ext";
            try out.print("{s}:", .{name});
            try printValue(&inner, out);
        },
        .chunk => return error.BadMessage,
    }
}

/// Writes `s` with control bytes, quotes and backslashes escaped, so it
/// can't change the terminal's state.
fn writeEscaped(out: *Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"', '\\' => try out.print("\\{c}", .{c}),
        0...0x1f, 0x7f => try out.print("\\x{x:0>2}", .{c}),
        else => try out.writeByte(c),
    };
}

test "printValue" {
    // [1, "a\x1b", {"k": true}, ext buffer 5, -2.5]
    var d: msgpack.Decoder = .{};
    d.feed("\x95\x01\xa2a\x1b\x81\xa1k\xc3\xd4\x00\x05\xcb\xc0\x04\x00\x00\x00\x00\x00\x00");
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try printValue(&d, &w);
    try std.testing.expectEqualStrings("[1, \"a\\x1b\", {\"k\": true}, buf:5, -2.5]", w.buffered());
}
