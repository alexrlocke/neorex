//! `neorex daemon BASE [nvim args]`: the background half of `neorex`. Takes
//! the launching pane's terminal, runs Neovim with `--listen`, and shows
//! each of its windows in a Rex pane (see `Daemon`). Exits when Neovim does
//! or the last pane goes away.

const std = @import("std");
const net = std.Io.net;
const Nvim = @import("../nvim/Nvim.zig");
const Client = @import("../rex/Client.zig");
const Loop = @import("Loop.zig");
const Daemon = @import("Daemon.zig");
const Pane = @import("Pane.zig");
const Surface = @import("Surface.zig");
const pane = @import("pane_helper.zig");

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

pub fn run(gpa: std.mem.Allocator, io: std.Io, base: []const u8, nvim_args: []const []const u8) !void {
    // out of the pane's session, so closing the pane doesn't signal us
    _ = std.c.setsid();

    var sock_buf: [max_path + 1]u8 = undefined;
    var nvim_sock_buf: [max_path + 1]u8 = undefined;
    var log_buf: [max_path + 1]u8 = undefined;
    const sock = try path(&sock_buf, base, ".sock");
    const nvim_sock = try path(&nvim_sock_buf, base, ".nvim.sock");
    const log = try path(&log_buf, base, ".log");
    const rex_url = env("REX_SERVER") orelse return error.NotInRex;
    const session_id = env("REX_SESSION") orelse return error.NotInRex;
    var exe_buf: [1024]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(io, &exe_buf)];

    const addr = try net.UnixAddress.init(sock);
    std.Io.Dir.cwd().deleteFile(io, sock) catch {};
    // open until we exit: every new pane's helper connects here
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

    const rex_block: ?Pane.RexBlock = if (env("REX_BLOCK")) |b| Pane.rexBlock(b) catch blk: {
        std.debug.print("neorex daemon: REX_BLOCK isn't a block id: {s}\n", .{b});
        break :blk null;
    } else null;
    var launch = Pane.startup(rex_block, try takePane(gpa, io, &server));
    var launch_owned = true;
    defer if (launch_owned) launch.deinit(gpa, io);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "nvim", "--headless", "--listen", nvim_sock });
    try argv.appendSlice(gpa, nvim_args);
    // its stderr is ours: the log
    var child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore });
    // after the terminals are restored: SIGHUP makes Neovim save swap files and exit
    defer {
        _ = std.c.kill(child.id.?, .HUP);
        _ = child.wait(io) catch {};
    }

    var nvim_buf: [16 * 1024]u8 = undefined;
    var nvim = try Nvim.connectRetry(io, nvim_sock, &nvim_buf);
    defer nvim.deinit(gpa);
    var rex_buf: [16 * 1024]u8 = undefined;
    var rex: Client = try .connect(gpa, io, rex_url, &rex_buf);
    defer rex.deinit(gpa);

    var loop: Loop = try .init();
    defer loop.deinit();
    for ([_]std.c.SIG{ .TERM, .INT, .HUP }) |sig| try loop.addSignal(sig, @backingInt(Daemon.Token.signal));
    try loop.addRead(nvim.readFd(), @backingInt(Daemon.Token.nvim_socket));
    try loop.addRead(server.socket.handle, @backingInt(Daemon.Token.helper_listener));
    try loop.addRead(rex.fd(), @backingInt(Daemon.Token.rex_socket));

    var d: Daemon = .{
        .gpa = gpa,
        .io = io,
        .loop = &loop,
        .nvim = .{ .client = &nvim },
        .rex = .{ .gpa = gpa, .client = &rex, .session_id = session_id },
        .exe = exe,
        .sock = sock,
    };
    // first: terminals restored and panes hung up before anything else ends
    defer d.deinit();
    launch_owned = false;
    try d.start(launch);

    const stop_reason = try d.run(&server);
    std.debug.print("neorex daemon: {t}\n", .{stop_reason});
    // a clean end needs no log
    std.Io.Dir.cwd().deleteFile(io, log) catch {};
}

fn env(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
}

/// Waits up to 5 s for the launcher's helper and takes its terminal.
fn takePane(gpa: std.mem.Allocator, io: std.Io, server: *net.Server) !*Surface {
    var fds = [_]std.c.pollfd{.{ .fd = server.socket.handle, .events = std.c.POLL.IN, .revents = 0 }};
    if ((std.posix.poll(&fds, 5000) catch 0) == 0) return error.NoPane;
    const hello = try pane.acceptHello(server, io);
    errdefer hello.close(io);
    return Surface.create(gpa, hello.stream, hello.tty);
}

test "base path fits a socket" {
    var buf: [256]u8 = undefined;
    const base = try basePath(&buf);
    try std.testing.expect(std.mem.indexOf(u8, base, "/neorex-") != null);
    var sock: [max_path + 1]u8 = undefined;
    try std.testing.expect((try path(&sock, base, ".nvim.sock")).len <= max_path);
}
