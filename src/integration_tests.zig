//! Integration tests: neorex's pieces against a real Neovim. Each test skips
//! when `nvim` isn't installed, or fails with `-Dnvim-required`. Run alone
//! with `zig build test:integration`. Helpers they share are in testing/.

test {
    _ = @import("integration/nvim.zig");
    _ = @import("integration/windows.zig");
    _ = @import("integration/grids.zig");
    _ = @import("integration/lua.zig");
}
