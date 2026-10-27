//! A Neovim child process, spoken to with msgpack-RPC over its stdin and stdout.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Framer = @import("Framer.zig");
const msgpack = @import("msgpack.zig");
const rpc = @import("rpc.zig");

const Nvim = @This();

child: std.process.Child,
io: Io,
/// Buffered writes to Neovim's stdin. Send with `flush`.
out: Io.File.Writer,
/// Splits Neovim's stdout into messages.
framer: Framer = .{},
next_id: u32 = 1,

/// Starts `argv`, which must include `--embed`. Requests buffer in `buffer`.
/// Neovim's stderr is inherited.
pub fn spawn(io: Io, argv: []const []const u8, buffer: []u8) !Nvim {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe });
    errdefer child.kill(io);
    return .{
        .child = child,
        .io = io,
        .out = child.stdin.?.writerStreaming(io, buffer),
    };
}

/// Closes Neovim's stdin, which makes an embedded Neovim exit, then waits for it.
pub fn deinit(self: *Nvim, gpa: Allocator) void {
    self.out.interface.flush() catch {};
    // close stdin ourselves; wait closes the rest
    self.child.stdin.?.close(self.io);
    self.child.stdin = null;
    _ = self.child.wait(self.io) catch {};
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
};

/// Attaches as a UI of `cols` x `rows` and flushes.
pub fn uiAttach(self: *Nvim, cols: u32, rows: u32, options: UiOptions) !void {
    const w = self.writer();
    _ = try self.request("nvim_ui_attach", 3);
    try msgpack.writeInt(w, cols);
    try msgpack.writeInt(w, rows);
    try msgpack.writeMapHeader(w, 3);
    try msgpack.writeStr(w, "ext_linegrid");
    try msgpack.writeBool(w, true);
    try msgpack.writeStr(w, "rgb");
    try msgpack.writeBool(w, true);
    try msgpack.writeStr(w, "ext_termcolors");
    try msgpack.writeBool(w, options.ext_termcolors);
    try self.flush();
}

/// Asks to resize the UI and flushes. Neovim answers with grid_resize.
pub fn uiTryResize(self: *Nvim, cols: u32, rows: u32) !void {
    _ = try self.request("nvim_ui_try_resize", 2);
    try msgpack.writeInt(self.writer(), cols);
    try msgpack.writeInt(self.writer(), rows);
    try self.flush();
}

/// Neovim's stdout. Poll it; readable when `read` won't block.
pub fn readFd(self: *const Nvim) std.posix.fd_t {
    return self.child.stdout.?.handle;
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
