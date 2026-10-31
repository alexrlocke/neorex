//! Our side of the Neovim connection: setup requests, the current window,
//! and what Neovim was last told about focus.

const Nvim = @import("../nvim/Nvim.zig");
const windows = @import("../nvim/windows.zig");
const Pane = @import("Pane.zig");

const NvimSession = @This();

client: *Nvim,
/// Neovim's current window, as the Lua last said; 0 before setup.
current_win: i64 = 0,
/// A `nvim_set_current_win` of ours not answered yet. Reports sent before
/// it ran are stale.
current_win_req: ?u32 = null,
channel_req: u32 = 0,
setup_req: u32 = 0,
/// Setup answered: windows can be adopted and given panes.
ready: bool = false,
/// Whether some pane's terminal has focus, as Neovim was last told.
ui_focused: bool = true,

/// Attaches as Neovim's UI at `cols` x `rows` and asks for our channel.
pub fn attachUi(self: *NvimSession, cols: u32, rows: u32) !void {
    try self.client.uiAttach(cols, rows, .{ .ext_termcolors = true, .ext_multigrid = true });
    self.channel_req = try windows.askChannel(self.client);
    try self.client.flush();
}

/// The editor's size follows the focused pane, so messages fit it.
pub fn fitUiTo(self: *NvimSession, p: *Pane) !void {
    const surface = p.terminal_surface orelse return;
    try self.client.uiTryResize(surface.view.cols, surface.view.rows);
}
