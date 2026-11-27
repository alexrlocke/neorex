//! The Lua tests (test/lua/*_spec.lua) for runtime/lua/neorex, in a headless
//! Neovim.

const runSpec = @import("../testing/lua.zig").runSpec;

test "runtime/lua/neorex: prompts, vim.ui and pickers" {
    try runSpec("test/lua/prompt_spec.lua");
}
