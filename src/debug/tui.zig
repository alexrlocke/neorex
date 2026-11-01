//! `neorex debug-tui`: runs Neovim in this terminal through neorex's own
//! grid and renderer. Ctrl+Q or :q quits.

const std = @import("std");
const Terminal = @import("../term/Terminal.zig");
const Signals = @import("../term/Signals.zig");
const modes = @import("../term/modes.zig");
const Nvim = @import("../nvim/Nvim.zig");
const Forwarder = @import("../nvim/Forwarder.zig");
const Grids = @import("../screen/Grids.zig");
const render = @import("../screen/render.zig");

/// Runs `nvim --embed` plus `nvim_args`.
pub fn run(gpa: std.mem.Allocator, io: std.Io, nvim_args: []const []const u8) !void {
    var out_buf: [64 * 1024]u8 = undefined;
    var term = try Terminal.init(std.posix.STDIN_FILENO, &out_buf);
    defer term.deinit();

    var signals = try Signals.init(&.{.WINCH});
    defer signals.deinit();

    const out = &term.writer;
    try out.writeAll(modes.editor_on);
    defer out.writeAll(modes.editor_off) catch {};
    try term.flush();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "nvim", "--embed" });
    try argv.appendSlice(gpa, nvim_args);

    var nvim_buf: [4096]u8 = undefined;
    var nvim = try Nvim.spawn(io, argv.items, &nvim_buf);
    defer nvim.deinit(gpa);

    // without ext_multigrid everything is grid 1
    var grids: Grids = .{};
    defer grids.deinit(gpa);

    const ws = try term.size();
    // termcolors: unset colors stay the terminal's, so the theme shows through
    try nvim.uiAttach(ws.col, ws.row, .{ .ext_termcolors = true });

    var forwarder: Forwarder = .{};
    var buf: [4096]u8 = undefined;
    while (true) {
        var fds = [_]std.c.pollfd{
            .{ .fd = term.fd, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = signals.read_fd, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = nvim.readFd(), .events = std.c.POLL.IN, .revents = 0 },
        };
        const ready = std.c.poll(&fds, fds.len, -1);
        if (ready < 0) {
            if (std.c.errno(ready) == .INTR) continue;
            return error.PollFailed;
        }

        if (fds[1].revents != 0) {
            const fired = try signals.drain();
            if (fired.contains(.WINCH)) {
                const size = try term.size();
                try nvim.uiTryResize(size.col, size.row);
            }
        }

        if (fds[2].revents != 0) {
            if (!try nvim.read(gpa)) return;
            while (try nvim.next()) |msg| switch (msg) {
                .notification => |note| if (std.mem.eql(u8, note.method, "redraw")) {
                    var params = note.params;
                    if (try grids.applyRedraw(gpa, &params)) if (grids.get(1)) |grid| {
                        try render.frame(grid, &grids.style, out);
                        try term.flush();
                    };
                },
                // nothing here serves requests; neovim would wait forever
                .request => |r| try nvim.respondError(r.id, "neorex debug-tui serves no requests"),
                .response => {},
            };
        }

        if (fds[0].revents != 0) {
            const n = std.c.read(term.fd, &buf, buf.len);
            if (n < 0) {
                if (std.c.errno(n) == .INTR) continue;
                return error.ReadFailed;
            }
            if (n == 0) return;
            if (!try forwarder.feed(&nvim, buf[0..@intCast(n)])) return;
        }
    }
}
