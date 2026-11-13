//! The `--cmd` neorex passes to every Neovim it starts. It runs before the
//! user's init.lua and sets
//!
//! - `vim.g.neorex = true`, so configs can tell they run in neorex
//! - `vim.g.neorex_runtime`, the runtime installed beside the binary (the
//!   `neorex` colorscheme and lualine theme), which it also adds to
//!   'runtimepath'. Configs whose plugin manager rebuilds 'runtimepath'
//!   (lazy.nvim) can add it back from this variable.

const std = @import("std");

/// Where `zig build` installs `runtime/`, under the install prefix.
const sub_path = "share/neorex/runtime";

const mark = "lua vim.g.neorex = true";

/// Room for the `--cmd` with any path.
pub const cmd_len = mark.len + std.Io.Dir.max_path_bytes + 128;

/// The `--cmd` for this binary, built in `buf`. Without a runtime beside the
/// binary it only sets `vim.g.neorex`.
pub fn cmd(io: std.Io, buf: *[cmd_len]u8) ![]const u8 {
    // resolved through symlinks (realpath on macOS, /proc/self/exe on Linux),
    // so ~/.local/bin/neorex and a Nix profile's bin/neorex find the real install
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(io, &exe_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime = path(&path_buf, exe) orelse return mark;
    std.Io.Dir.accessAbsolute(io, runtime, .{}) catch return mark;
    return lua(buf, runtime);
}

/// `<prefix>/share/neorex/runtime` for the binary `<prefix>/bin/neorex`.
fn path(buf: []u8, exe: []const u8) ?[]const u8 {
    const bin = std.fs.path.dirname(exe) orelse return null;
    const prefix = std.fs.path.dirname(bin) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/" ++ sub_path, .{prefix}) catch null;
}

fn lua(buf: []u8, runtime: []const u8) []const u8 {
    // a Lua long string takes the path as it is, quotes and spaces too;
    // only its closing bracket can't appear in it
    if (std.mem.indexOf(u8, runtime, "]==]") != null) return mark;
    return std.fmt.bufPrint(
        buf,
        mark ++ "; vim.g.neorex_runtime = [==[{s}]==]; vim.opt.rtp:append(vim.g.neorex_runtime)",
        .{runtime},
    ) catch mark;
}

test path {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/nix/store/abc-neorex/share/neorex/runtime",
        path(&buf, "/nix/store/abc-neorex/bin/neorex").?,
    );
    try std.testing.expectEqualStrings(
        "/home/me/neorex/zig-out/share/neorex/runtime",
        path(&buf, "/home/me/neorex/zig-out/bin/neorex").?,
    );
    try std.testing.expect(path(&buf, "neorex") == null);
}

test lua {
    var buf: [cmd_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "lua vim.g.neorex = true; vim.g.neorex_runtime = [==[/a b/it's \"here\"]==]; vim.opt.rtp:append(vim.g.neorex_runtime)",
        lua(&buf, "/a b/it's \"here\""),
    );
    try std.testing.expectEqualStrings(mark, lua(&buf, "/odd]==]path"));
}

test cmd {
    var buf: [cmd_len]u8 = undefined;
    // the test binary, in Zig's cache, has no runtime beside it
    try std.testing.expectEqualStrings(mark, try cmd(std.testing.io, &buf));
}
