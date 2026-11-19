//! `neorex debug-keys`: shows each input event with the raw bytes that
//! made it, so you can see what the terminal sends. Ctrl+Q quits.

const std = @import("std");
const term = @import("term");

/// Terminal modes `debug-keys` turns on, and the sequences that turn them
/// off again.
const modes_on = "\x1b[?1049h" ++ // alternate screen: keep the shell's scrollback clean
    "\x1b[?2004h" ++ // bracketed paste: pastes arrive wrapped in ESC[200~ ... ESC[201~
    "\x1b[?1004h" ++ // focus reporting: ESC[I and ESC[O
    "\x1b[?1002h" ++ // mouse: presses, releases and drags
    "\x1b[?1006h" ++ // mouse: SGR encoding (ESC[<b;x;yM), no limit on size
    term.input.kitty_push; // kitty keyboard protocol, after the screen switch
// Undone in reverse: pop kitty's flags while still on the alternate screen.
const modes_off = term.input.kitty_pop ++ "\x1b[?1006l\x1b[?1002l\x1b[?1004l\x1b[?2004l\x1b[?1049l";

pub fn run() !void {
    var out_buf: [16 * 1024]u8 = undefined;
    var terminal = try term.Terminal.init(std.posix.STDIN_FILENO, &out_buf);
    defer terminal.deinit();

    // before reading the size, so a resize in between isn't missed
    var signals = try term.Signals.init(&.{.WINCH});
    defer signals.deinit();

    const out = &terminal.writer;
    try out.writeAll(modes_on);
    // Runs before terminal.deinit (defers run in reverse), so the modes are off
    // before the terminal's settings come back.
    defer out.writeAll(modes_off) catch {};

    var ws = try terminal.size();
    try out.print("\x1b[H\x1b[2Jdebug-keys: {d}x{d}. Type, paste, click or resize. Ctrl+Q quits.\r\n", .{ ws.col, ws.row });
    try terminal.flush();

    var parser: term.input.Parser = .{};
    var buf: [4096]u8 = undefined;
    while (true) {
        var fds = [_]std.c.pollfd{
            .{ .fd = terminal.fd, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = signals.read_fd, .events = std.c.POLL.IN, .revents = 0 },
        };
        const ready = std.c.poll(&fds, fds.len, -1);
        if (ready < 0) {
            // a signal interrupted poll; its byte is waiting in the pipe
            if (std.c.errno(ready) == .INTR) continue;
            return error.PollFailed;
        }

        if (fds[1].revents != 0) {
            const fired = try signals.drain();
            if (fired.contains(.WINCH)) {
                ws = try terminal.size();
                try out.print("resize {d}x{d}\r\n", .{ ws.col, ws.row });
                try terminal.flush();
            }
        }
        if (fds[0].revents == 0) continue;

        const n = std.c.read(terminal.fd, &buf, buf.len);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) return; // the terminal went away
        const bytes = buf[0..@intCast(n)];

        // One line per read: the raw bytes, then the events they made.
        try out.writeAll("read ");
        for (bytes) |b| try out.print("{x:0>2} ", .{b});
        try out.writeAll("\r\n");

        parser.feed(bytes);
        while (parser.next()) |event| {
            try out.print("  {f}\r\n", .{event});
            if (isQuit(event)) {
                try terminal.flush();
                return;
            }
        }
        try terminal.flush();
    }
}

fn isQuit(event: term.input.Event) bool {
    return switch (event) {
        .key => |k| k.mods.ctrl and !k.mods.alt and k.key == .codepoint and k.key.codepoint == 'q',
        else => false,
    };
}
