//! Runs the Lua tests (test/lua/*_spec.lua) for runtime/lua/neorex in a
//! headless Neovim. `zig build test` runs from the repository's root, which
//! the specs need.

const std = @import("std");
const testing = std.testing;

fn runSpec(comptime path: []const u8) !void {
    const result = std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "nvim", "--headless", "--clean", "-l", path },
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
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

test "runtime/lua/neorex: prompts, vim.ui and pickers" {
    try runSpec("test/lua/prompt_spec.lua");
}
