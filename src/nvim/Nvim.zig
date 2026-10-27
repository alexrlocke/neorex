//! A connection to Neovim speaking msgpack-RPC: an embedded child's stdin
//! and stdout, or a socket to a Neovim started with `--listen`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Framer = @import("Framer.zig");
const msgpack = @import("msgpack.zig");
const rpc = @import("rpc.zig");

const Nvim = @This();

/// Null when connected to a socket.
child: ?std.process.Child,
io: Io,
/// Neovim's stdout, or the socket.
read_fd: std.posix.fd_t,
/// Buffered writes to Neovim's stdin or the socket. Send with `flush`.
out: Io.File.Writer,
/// Splits Neovim's stdout into messages.
framer: Framer = .{},
next_id: u32 = 1,
/// The UI size last sent, as columns and rows.
ui_size: [2]u32 = .{ 0, 0 },

/// Starts `argv`, which must include `--embed`. Requests buffer in `buffer`.
/// Neovim's stderr is inherited.
pub fn spawn(io: Io, argv: []const []const u8, buffer: []u8) !Nvim {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe });
    errdefer child.kill(io);
    return .{
        .child = child,
        .io = io,
        .read_fd = child.stdout.?.handle,
        .out = child.stdin.?.writerStreaming(io, buffer),
    };
}

/// Connects to the socket of a Neovim started with `--listen`.
pub fn connect(io: Io, path: []const u8, buffer: []u8) !Nvim {
    const addr = try std.Io.net.UnixAddress.init(path);
    const stream = try addr.connect(io);
    const file: Io.File = .{ .handle = stream.socket.handle, .flags = .{ .nonblocking = false } };
    return .{
        .child = null,
        .io = io,
        .read_fd = stream.socket.handle,
        .out = file.writerStreaming(io, buffer),
    };
}

/// Embedded: closes Neovim's stdin, which makes it exit, then waits for it.
/// Socket: closes the socket; Neovim keeps running.
pub fn deinit(self: *Nvim, gpa: Allocator) void {
    self.out.interface.flush() catch {};
    if (self.child) |*child| {
        // close stdin ourselves; wait closes the rest
        child.stdin.?.close(self.io);
        child.stdin = null;
        _ = child.wait(self.io) catch {};
    } else {
        _ = std.c.close(self.read_fd);
    }
    self.framer.deinit(gpa);
    self.* = undefined;
}

/// Writes a request's header and returns its id. Write `param_count` params
/// to `writer()` after it, then `flush`.
pub fn request(self: *Nvim, method: []const u8, param_count: u32) !u32 {
    const id = self.next_id;
    self.next_id +%= 1;
    try rpc.writeRequestHeader(self.writer(), id, method, param_count);
    return id;
}

pub fn writer(self: *Nvim) *Io.Writer {
    return &self.out.interface;
}

/// Sends everything written so far.
pub fn flush(self: *Nvim) !void {
    try self.out.interface.flush();
}

/// Answers request `id` with an error, so Neovim stops waiting, and flushes.
pub fn respondError(self: *Nvim, id: u32, message: []const u8) !void {
    const w = self.writer();
    try msgpack.writeArrayHeader(w, 4);
    try msgpack.writeInt(w, 1);
    try msgpack.writeInt(w, id);
    try msgpack.writeStr(w, message);
    try msgpack.writeNil(w);
    try self.flush();
}

/// Options for `uiAttach`. ext_linegrid and rgb are always on.
pub const UiOptions = struct {
    /// Unset default colors arrive as -1, so the terminal's own are used.
    ext_termcolors: bool = false,
    /// A grid per window; see `Grids`.
    ext_multigrid: bool = false,
};

/// Attaches as a UI of `cols` x `rows` and flushes.
pub fn uiAttach(self: *Nvim, cols: u32, rows: u32, options: UiOptions) !void {
    const w = self.writer();
    _ = try self.request("nvim_ui_attach", 3);
    try msgpack.writeInt(w, cols);
    try msgpack.writeInt(w, rows);
    try msgpack.writeMapHeader(w, 4);
    try msgpack.writeStr(w, "ext_linegrid");
    try msgpack.writeBool(w, true);
    try msgpack.writeStr(w, "rgb");
    try msgpack.writeBool(w, true);
    try msgpack.writeStr(w, "ext_termcolors");
    try msgpack.writeBool(w, options.ext_termcolors);
    try msgpack.writeStr(w, "ext_multigrid");
    try msgpack.writeBool(w, options.ext_multigrid);
    try self.flush();
    self.ui_size = .{ cols, rows };
}

/// Asks to resize the UI and flushes. Neovim answers with grid_resize. Does
/// nothing for the size it already has: every resize redraws the whole screen.
pub fn uiTryResize(self: *Nvim, cols: u32, rows: u32) !void {
    if (self.ui_size[0] == cols and self.ui_size[1] == rows) return;
    _ = try self.request("nvim_ui_try_resize", 2);
    try msgpack.writeInt(self.writer(), cols);
    try msgpack.writeInt(self.writer(), rows);
    try self.flush();
    self.ui_size = .{ cols, rows };
}

/// Asks for grid `grid` (a window's) to be `cols` x `rows`. Doesn't flush.
pub fn uiTryResizeGrid(self: *Nvim, grid: u32, cols: u32, rows: u32) !void {
    _ = try self.request("nvim_ui_try_resize_grid", 3);
    try msgpack.writeInt(self.writer(), grid);
    try msgpack.writeInt(self.writer(), @max(cols, 1));
    try msgpack.writeInt(self.writer(), @max(rows, 1));
}

/// Starts `nvim_exec_lua(code, args)` and returns its id. Write `arg_count`
/// args to `writer()` after it, then `flush`.
pub fn execLua(self: *Nvim, code: []const u8, arg_count: u32) !u32 {
    const id = try self.request("nvim_exec_lua", 2);
    try msgpack.writeStr(self.writer(), code);
    try msgpack.writeArrayHeader(self.writer(), arg_count);
    return id;
}

/// Neovim's stdout. Poll it; readable when `read` won't block.
pub fn readFd(self: *const Nvim) std.posix.fd_t {
    return self.read_fd;
}

/// Reads what Neovim has sent, blocking until something arrives. False once
/// Neovim has exited. Invalidates messages from `next`.
pub fn read(self: *Nvim, gpa: Allocator) !bool {
    var buf: [64 * 1024]u8 = undefined;
    const n = try std.posix.read(self.readFd(), &buf);
    if (n == 0) return false;
    try self.framer.feed(gpa, buf[0..n]);
    return true;
}

/// The next whole message, or null until `read` gets more. Valid until `read`.
pub fn next(self: *Nvim) !?rpc.Message {
    const bytes = try self.framer.next() orelse return null;
    return try rpc.parse(bytes);
}

/// Starts Neovim for a test, or skips the test if it isn't installed.
fn spawnForTest(buffer: []u8) !Nvim {
    return spawn(std.testing.io, &.{ "nvim", "--clean", "--embed" }, buffer) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

/// Reads until the response to `id`, skipping other messages.
fn waitResponse(nvim: *Nvim, gpa: Allocator, id: u32) !rpc.Message.Response {
    while (true) {
        while (try nvim.next()) |msg| switch (msg) {
            .response => |r| if (r.id == id) return r,
            else => {},
        };
        if (!try nvim.read(gpa)) return error.NvimExited;
    }
}

test "eval" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var nvim = try spawnForTest(&buf);
    defer nvim.deinit(gpa);

    const id = try nvim.request("nvim_eval", 1);
    try msgpack.writeStr(nvim.writer(), "1+2");
    try nvim.flush();

    var r = try waitResponse(&nvim, gpa, id);
    try std.testing.expectEqual(@as(?[]const u8, null), r.err);
    try std.testing.expectEqual(@as(i64, 3), try rpc.expectInt(&r.result));
}

test "error response" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var nvim = try spawnForTest(&buf);
    defer nvim.deinit(gpa);

    const id = try nvim.request("nvim_eval", 1);
    try msgpack.writeStr(nvim.writer(), "no_such_variable");
    try nvim.flush();

    const r = try waitResponse(&nvim, gpa, id);
    try std.testing.expect(std.mem.indexOf(u8, r.err.?, "no_such_variable") != null);
}

test "a resize to the same size isn't sent" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var nvim = try spawnForTest(&buf);
    defer nvim.deinit(gpa);
    try nvim.uiAttach(40, 10, .{});
    const before = nvim.next_id;
    try nvim.uiTryResize(40, 10);
    try std.testing.expectEqual(before, nvim.next_id);
    try nvim.uiTryResize(30, 8);
    try std.testing.expectEqual(before + 1, nvim.next_id);
}

test "connect to a listening neovim" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/neorex-test-connect.sock";
    var server = std.process.spawn(io, .{
        .argv = &.{ "nvim", "--clean", "--headless", "--listen", path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer {
        _ = std.c.kill(server.id.?, .HUP);
        _ = server.wait(io) catch {};
    }

    var buf: [256]u8 = undefined;
    var nvim = try connectRetry(io, path, &buf);
    defer nvim.deinit(gpa);
    const id = try nvim.request("nvim_eval", 1);
    try msgpack.writeStr(nvim.writer(), "1+2");
    try nvim.flush();
    var r = try waitResponse(&nvim, gpa, id);
    try std.testing.expectEqual(@as(i64, 3), try rpc.expectInt(&r.result));
}

/// `connect`, retrying for up to 2 s: Neovim makes its socket a moment after starting.
pub fn connectRetry(io: Io, path: []const u8, buffer: []u8) !Nvim {
    for (0..200) |_| {
        return connect(io, path, buffer) catch {
            try io.sleep(.fromMilliseconds(10), .awake);
            continue;
        };
    }
    return error.Timeout;
}

test "large reply over several reads" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var nvim = try spawnForTest(&buf);
    defer nvim.deinit(gpa);

    _ = try nvim.request("nvim_get_api_info", 0);
    const id = try nvim.request("nvim_get_api_info", 0); // two in flight
    try nvim.flush();

    // [channel id, {version, functions, ...}]
    var r = try waitResponse(&nvim, gpa, id);
    try std.testing.expectEqual(@as(u32, 2), try rpc.expectArray(&r.result));
    try std.testing.expect(try rpc.expectInt(&r.result) > 0);
    try rpc.skip(&r.result);
}
