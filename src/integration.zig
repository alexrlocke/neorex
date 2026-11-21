//! Integration tests: neorex's pieces against a real Neovim. Each test
//! skips when `nvim` isn't installed. Run alone with `zig build test-integration`.

test {
    _ = @import("integration/windows.zig");
    _ = @import("integration/grids.zig");
}
