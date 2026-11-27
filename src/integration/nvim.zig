//! `Nvim`, the connection, against a real Neovim: requests, errors, a socket
//! to a `--listen`ing Neovim, and replies too large for one read.

const std = @import("std");
const testing = std.testing;
const nvim = @import("nvim");
const testing_nvim = @import("../testing/nvim.zig");

const msgpack = @import("msgpack");

test "eval" {
    const gpa = testing.allocator;
    var buf: [256]u8 = undefined;
    var nvim_client = try testing_nvim.spawn(&buf);
    defer nvim_client.deinit(gpa);

    const id = try nvim_client.request("nvim_eval", 1);
    try msgpack.writeStr(nvim_client.writer(), "1+2");
    try nvim_client.flush();

    var r = try testing_nvim.waitResponse(&nvim_client, id);
    try testing.expectEqual(@as(?[]const u8, null), r.err);
    try testing.expectEqual(@as(i64, 3), try msgpack.expectInt(&r.result));
}

test "error response" {
    const gpa = testing.allocator;
    var buf: [256]u8 = undefined;
    var nvim_client = try testing_nvim.spawn(&buf);
    defer nvim_client.deinit(gpa);

    const id = try nvim_client.request("nvim_eval", 1);
    try msgpack.writeStr(nvim_client.writer(), "no_such_variable");
    try nvim_client.flush();

    const r = try testing_nvim.waitResponse(&nvim_client, id);
    try testing.expect(std.mem.indexOf(u8, r.err.?, "no_such_variable") != null);
}

test "a resize to the same size isn't sent" {
    const gpa = testing.allocator;
    var buf: [256]u8 = undefined;
    var nvim_client = try testing_nvim.spawn(&buf);
    defer nvim_client.deinit(gpa);
    try nvim_client.uiAttach(40, 10, .{});
    const before = nvim_client.next_id;
    try nvim_client.uiTryResize(40, 10);
    try testing.expectEqual(before, nvim_client.next_id);
    try nvim_client.uiTryResize(30, 8);
    try testing.expectEqual(before + 1, nvim_client.next_id);
}

test "connect to a listening neovim" {
    const gpa = testing.allocator;
    const io = testing.io;
    const path = "/tmp/neorex-test-connect.sock";
    var server = std.process.spawn(io, .{
        .argv = &.{ "nvim", "--clean", "--headless", "--listen", path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return testing_nvim.notInstalled(),
        else => return err,
    };
    defer {
        _ = std.c.kill(server.id.?, .HUP);
        _ = server.wait(io) catch {};
    }

    var buf: [256]u8 = undefined;
    var nvim_client = try nvim.Nvim.connectRetry(io, path, &buf);
    defer nvim_client.deinit(gpa);
    const id = try nvim_client.request("nvim_eval", 1);
    try msgpack.writeStr(nvim_client.writer(), "1+2");
    try nvim_client.flush();
    var r = try testing_nvim.waitResponse(&nvim_client, id);
    try testing.expectEqual(@as(i64, 3), try msgpack.expectInt(&r.result));
}

test "large reply over several reads" {
    const gpa = testing.allocator;
    var buf: [256]u8 = undefined;
    var nvim_client = try testing_nvim.spawn(&buf);
    defer nvim_client.deinit(gpa);

    _ = try nvim_client.request("nvim_get_api_info", 0);
    const id = try nvim_client.request("nvim_get_api_info", 0); // two in flight
    try nvim_client.flush();

    // [channel id, {version, functions, ...}]
    var r = try testing_nvim.waitResponse(&nvim_client, id);
    try testing.expectEqual(@as(u32, 2), try msgpack.expectArray(&r.result));
    try testing.expect(try msgpack.expectInt(&r.result) > 0);
    try msgpack.skip(&r.result);
}
