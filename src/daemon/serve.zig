//! `neorex daemon BASE [nvim args]`: the background half of `neorex`. Takes
//! the launching pane's terminal, runs Neovim with `--listen`, and draws it
//! there. Exits when Neovim does or the pane goes away.

const std = @import("std");
const net = std.Io.net;
const Terminal = @import("../term/Terminal.zig");
const modes = @import("../term/modes.zig");
const Nvim = @import("../nvim/Nvim.zig");
const Forwarder = @import("../nvim/Forwarder.zig");
const Grid = @import("../screen/Grid.zig");
const render = @import("../screen/render.zig");
const Loop = @import("Loop.zig");
const fdpass = @import("fdpass.zig");
const pane = @import("pane.zig");

/// Longest path a Unix socket takes on macOS, less one for the terminator.
pub const max_path = 103;

/// `$TMPDIR/neorex-PID`, which every daemon file is named from.
pub fn basePath(buf: []u8) ![]const u8 {
    const tmp = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    const dir = std.mem.trimEnd(u8, tmp, "/");
    const base = try std.fmt.bufPrint(buf, "{s}/neorex-{d}", .{ dir, std.c.getpid() });
    // room for the longest suffix
    if (base.len + ".nvim.sock".len > max_path) return error.NameTooLong;
    return base;
}

/// `base` plus `suffix`, such as `.sock`.
pub fn path(buf: []u8, base: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ base, suffix });
}

const token_signal = 0;
const token_nvim = 1;
const token_pane = 2;
const token_tty = 3;

const End = enum { nvim_exited, pane_gone, signal };

pub fn run(gpa: std.mem.Allocator, io: std.Io, base: []const u8, nvim_args: []const []const u8) !void {
    // out of the pane's session, so closing the pane doesn't signal us
    _ = std.c.setsid();

    var sock_buf: [max_path + 1]u8 = undefined;
    var nvim_sock_buf: [max_path + 1]u8 = undefined;
    var log_buf: [max_path + 1]u8 = undefined;
    const sock = try path(&sock_buf, base, ".sock");
    const nvim_sock = try path(&nvim_sock_buf, base, ".nvim.sock");
    const log = try path(&log_buf, base, ".log");

    const pane_conn = try takePane(io, sock);
    defer pane_conn.stream.close(io);
    defer _ = std.c.close(pane_conn.tty);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "nvim", "--headless", "--listen", nvim_sock });
    try argv.appendSlice(gpa, nvim_args);
    // its stderr is ours: the log
    var child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore });
    // after the terminal is restored: SIGHUP makes Neovim save swap files and exit
    defer {
        _ = std.c.kill(child.id.?, .HUP);
        _ = child.wait(io) catch {};
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var term = try Terminal.init(pane_conn.tty, &out_buf);
    defer term.deinit();
    try term.writer.writeAll(modes.editor_on);
    defer term.writer.writeAll(modes.editor_off) catch {};
    try term.flush();

    var nvim_buf: [4096]u8 = undefined;
    var nvim = try Nvim.connectRetry(io, nvim_sock, &nvim_buf);
    defer nvim.deinit(gpa);
    var grid: Grid = .{};
    defer grid.deinit(gpa);
    const ws = try term.size();
    // termcolors: unset colors stay the terminal's, so the theme shows through
    try nvim.uiAttach(ws.col, ws.row, .{ .ext_termcolors = true });

    var loop: Loop = try .init();
    defer loop.deinit();
    for ([_]std.c.SIG{ .TERM, .INT, .HUP }) |sig| try loop.addSignal(sig, token_signal);
    try loop.addRead(nvim.readFd(), token_nvim);
    try loop.addRead(pane_conn.stream.socket.handle, token_pane);
    try loop.addRead(pane_conn.tty, token_tty);

    const end = try serve(gpa, io, &loop, &nvim, &grid, &term, pane_conn.stream);
    std.debug.print("neorex daemon: {t}\n", .{end});
    // a clean end needs no log
    std.Io.Dir.cwd().deleteFile(io, log) catch {};
}

const PaneConn = struct { stream: net.Stream, tty: std.posix.fd_t };

/// Listens at `sock`, tells the launcher, and takes the one pane that connects.
fn takePane(io: std.Io, sock: []const u8) !PaneConn {
    const addr = try net.UnixAddress.init(sock);
    std.Io.Dir.cwd().deleteFile(io, sock) catch {};
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, sock) catch {};

    // one byte on stdout says we're listening; then stdout goes nowhere
    if (std.c.write(std.posix.STDOUT_FILENO, "r", 1) != 1) return error.LauncherGone;
    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
    if (devnull >= 0) {
        _ = std.c.dup2(devnull, std.posix.STDOUT_FILENO);
        _ = std.c.close(devnull);
    }

    var fds = [_]std.c.pollfd{.{ .fd = server.socket.handle, .events = std.c.POLL.IN, .revents = 0 }};
    if (std.c.poll(&fds, 1, 5000) <= 0) return error.NoPane;
    const stream = try server.accept(io);
    errdefer stream.close(io);
    var hello: [1]u8 = undefined;
    const r = try fdpass.recv(stream, io, &hello);
    const tty = r.fd orelse return error.NoTerminal;
    if (r.len != 1 or hello[0] != @intFromEnum(pane.Message.hello)) {
        _ = std.c.close(tty);
        return error.BadHello;
    }
    return .{ .stream = stream, .tty = tty };
}

fn serve(gpa: std.mem.Allocator, io: std.Io, loop: *const Loop, nvim: *Nvim, grid: *Grid, term: *Terminal, stream: net.Stream) !End {
    var forwarder: Forwarder = .{ .ctrl_q_quits = false };
    var events: [16]Loop.Event = undefined;
    while (true) for (try loop.wait(&events)) |e| switch (e.token) {
        token_signal => return .signal,
        token_nvim => if (!try onNvim(gpa, nvim, grid, term)) return .nvim_exited,
        token_pane => if (!try onPane(io, stream, nvim, term)) return .pane_gone,
        token_tty => if (!try onInput(term, &forwarder, nvim)) return .pane_gone,
        else => unreachable,
    };
}

/// Applies Neovim's messages, drawing on each flush. False once it exits.
fn onNvim(gpa: std.mem.Allocator, nvim: *Nvim, grid: *Grid, term: *Terminal) !bool {
    if (!try nvim.read(gpa)) return false;
    while (try nvim.next()) |msg| switch (msg) {
        .notification => |note| if (std.mem.eql(u8, note.method, "redraw")) {
            var params = note.params;
            if (try grid.applyRedraw(gpa, &params)) {
                try render.frame(grid, &term.writer);
                try term.flush();
            }
        },
        // nothing here serves requests; neovim would wait forever
        .request => |r| try nvim.respondError(r.id, "neorex serves no requests"),
        .response => |r| if (r.err) |e| std.debug.print("neovim error: {s}\n", .{e}),
    };
    return true;
}

/// A message from the pane helper. False once it hangs up.
fn onPane(io: std.Io, stream: net.Stream, nvim: *Nvim, term: *Terminal) !bool {
    var buf: [64]u8 = undefined;
    const r = try fdpass.recv(stream, io, &buf);
    if (r.fd) |fd| _ = std.c.close(fd);
    if (r.len == 0) return false;
    for (buf[0..r.len]) |b| if (@as(pane.Message, @enumFromInt(b)) == .resized) {
        const ws = try term.size();
        try nvim.uiTryResize(ws.col, ws.row);
    };
    return true;
}

/// Keys typed in the pane. False once the terminal is gone.
fn onInput(term: *Terminal, forwarder: *Forwarder, nvim: *Nvim) !bool {
    var buf: [4096]u8 = undefined;
    const n = std.c.read(term.fd, &buf, buf.len);
    if (n <= 0) return false;
    _ = try forwarder.feed(nvim, buf[0..@intCast(n)]);
    return true;
}

test "base path fits a socket" {
    var buf: [256]u8 = undefined;
    const base = try basePath(&buf);
    try std.testing.expect(std.mem.indexOf(u8, base, "/neorex-") != null);
    var sock: [max_path + 1]u8 = undefined;
    try std.testing.expect((try path(&sock, base, ".nvim.sock")).len <= max_path);
}
