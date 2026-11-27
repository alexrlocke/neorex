//! Neovim, from neorex's side: the connection, its messages, the Lua that
//! keeps windows as panes, options, input and the runtime path.

pub const Nvim = @import("Nvim.zig");
pub const rpc = @import("rpc.zig");
pub const windows = @import("windows.zig");
pub const Options = @import("Options.zig");
pub const Forwarder = @import("Forwarder.zig");
pub const runtime = @import("runtime.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Framer.zig"); // internal: Nvim's, not exported, but has tests
}
