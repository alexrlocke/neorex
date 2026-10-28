//! `neorex [nvim args]`: opens Neovim in this pane. Starts the daemon in the
//! background, then hands it this terminal and waits as its pane helper.

const std = @import("std");
const serve = @import("serve.zig");
const pane = @import("pane_helper.zig");

pub fn run(gpa: std.mem.Allocator, io: std.Io, nvim_args: []const []const u8) !void {
    if (std.c.isatty(std.posix.STDIN_FILENO) == 0) return error.NotATerminal;
    // each window becomes a Rex pane
    if (std.c.getenv("REX_SERVER") == null or std.c.getenv("REX_SESSION") == null) {
        std.debug.print("neorex: run it in a Rex pane\n", .{});
        return error.NotInRex;
    }

    var base_buf: [serve.max_path + 1]u8 = undefined;
    var sock_buf: [serve.max_path + 1]u8 = undefined;
    var log_buf: [serve.max_path + 1]u8 = undefined;
    const base = try serve.basePath(&base_buf);
    const sock = try serve.path(&sock_buf, base, ".sock");
    const log_path = try serve.path(&log_buf, base, ".log");

    var exe_buf: [1024]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(io, &exe_buf)];
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ exe, "daemon", base });
    try argv.appendSlice(gpa, nvim_args);

    const log = try std.Io.Dir.cwd().createFile(io, log_path, .{});
    var daemon = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .{ .file = log },
    }) catch |err| {
        log.close(io);
        return err;
    };
    log.close(io);

    // one byte once it's listening; nothing if it failed
    var ready: [1]u8 = undefined;
    const n = std.c.read(daemon.stdout.?.handle, &ready, 1);
    daemon.stdout.?.close(io);
    daemon.stdout = null;
    if (n != 1) {
        std.debug.print("neorex: the daemon didn't start; see {s}\n", .{log_path});
        return error.DaemonFailed;
    }
    // the daemon outlives us; it's never waited for here
    try pane.run(io, sock, null);
}
