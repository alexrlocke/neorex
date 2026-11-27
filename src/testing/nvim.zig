//! A real Neovim for a test. Without `nvim` on the PATH the test skips, so a
//! checkout without it still passes; with -Dnvim-required, as CI builds, it
//! fails instead, so CI can't pass by skipping.

const std = @import("std");
const testing = std.testing;
const nvim = @import("nvim");
const test_options = @import("test_options");

/// Starts `nvim --clean --embed -n`. Requests buffer in `buffer`.
pub fn spawn(buffer: []u8) !nvim.Nvim {
    return nvim.Nvim.spawn(testing.io, &.{ "nvim", "--clean", "--embed", "-n" }, buffer) catch |err| switch (err) {
        error.FileNotFound => notInstalled(),
        else => err,
    };
}

/// What a test does when starting `nvim` finds no such program.
pub fn notInstalled() error{ SkipZigTest, NvimNotInstalled } {
    if (test_options.nvim_required) {
        std.debug.print("nvim isn't on the PATH, and -Dnvim-required is set\n", .{});
        return error.NvimNotInstalled;
    }
    return error.SkipZigTest;
}

/// Reads until the response to `id`, skipping other messages.
pub fn waitResponse(nvim_client: *nvim.Nvim, id: u32) !nvim.rpc.Message.Response {
    while (true) {
        while (try nvim_client.next()) |msg| switch (msg) {
            .response => |r| if (r.id == id) return r,
            else => {},
        };
        if (!try nvim_client.read(testing.allocator)) return error.NvimExited;
    }
}
