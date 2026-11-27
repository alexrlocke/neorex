//! Runs a Lua spec (test/lua/*_spec.lua) in a headless Neovim. Paths are from
//! the repository's root, which the integration tests run from.

const std = @import("std");
const testing = std.testing;
const testing_nvim = @import("nvim.zig");

pub fn runSpec(comptime path: []const u8) !void {
    const result = std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "nvim", "--headless", "--clean", "-l", path },
    }) catch |err| switch (err) {
        error.FileNotFound => return testing_nvim.notInstalled(),
        else => return err,
    };
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    const passed = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!passed) {
        std.debug.print("{s}:\n{s}{s}\n", .{ path, result.stdout, result.stderr });
        return error.LuaSpecFailed;
    }
}
