//! Our side of the Neovim connection: setup requests, the current window,
//! and what Neovim was last told about focus.

const std = @import("std");
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
/// Neovim's current window when it's a float, else 0.
current_float: i64 = 0,
/// The editor size last asked for.
editor_size: [2]u32 = .{ 0, 0 },

/// Attaches as Neovim's UI at `cols` x `rows` and asks for our channel.
pub fn attachUi(self: *NvimSession, cols: u32, rows: u32) !void {
    try self.client.uiAttach(cols, rows, .{ .ext_termcolors = true, .ext_multigrid = true });
    self.channel_req = try windows.askChannel(self.client);
    try self.client.flush();
}

/// The editor spans the Rex window, so editor floats such as pickers can
/// too. Messages show in the focused pane.
pub fn fitUiTo(self: *NvimSession, p: *const Pane) !void {
    const size = editorSize(p) orelse return;
    if (std.mem.eql(u32, &size, &self.editor_size)) return;
    self.editor_size = size;
    try self.client.uiTryResize(size[0], size[1]);
}

/// The Rex window's size in cells, judged from pane `p`'s share of it;
/// without that, the pane's own size.
fn editorSize(p: *const Pane) ?[2]u32 {
    const s = p.terminal_surface orelse return null;
    const cols = s.view.cols;
    const rows = s.view.rows;
    const r = p.rect orelse return .{ cols, rows };
    if (r[2] <= 0 or r[3] <= 0) return .{ cols, rows };
    return .{
        @max(cols, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(cols)) / r[2])))),
        @max(rows, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(rows)) / r[3])))),
    };
}
