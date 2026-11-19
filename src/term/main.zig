//! The terminals neorex drives: raw mode, input decoding, modes.
// TODO: Signals isn't terminal-specific (the event loop is its main
// user); it lives here only because SIGWINCH is the signal we care about.

pub const input = @import("input.zig");
pub const Terminal = @import("Terminal.zig");
pub const Signals = @import("Signals.zig");
pub const modes = @import("modes.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
