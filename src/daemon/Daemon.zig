//! The running daemon: Neovim, its grids, the Rex connection, a pane per
//! window and a floating pane per group of editor floats that took focus or
//! can't (see FloatGroups). After
//! each Neovim flush, `reconcile` gives new windows and float groups panes
//! and hangs up panes whose windows closed; then every pane is drawn.
// TODO: Needs a pretty major rewrite

const std = @import("std");
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const input = @import("../term/input.zig");
const Nvim = @import("../nvim/Nvim.zig");
const msgpack = @import("../nvim/msgpack.zig");
const windows = @import("../nvim/windows.zig");
const Options = @import("../nvim/Options.zig");
const Forwarder = @import("../nvim/Forwarder.zig");
const Grids = @import("../screen/Grids.zig");
const FloatGroups = @import("../screen/FloatGroups.zig");
const PaneView = @import("../screen/PaneView.zig");
const Client = @import("../rex/Client.zig");
const layout = @import("../rex/layout.zig");
const LayoutTree = @import("../rex/LayoutTree.zig");
const Loop = @import("loop.zig").Loop;
const Pane = @import("Pane.zig");
const Panes = @import("Panes.zig");
const RexSession = @import("../rex/Session.zig");
const NvimSession = @import("NvimSession.zig");
const WindowChanges = @import("WindowChanges.zig");
const Titles = @import("Titles.zig");
const Surface = @import("Surface.zig");
const pane_helper = @import("pane_helper.zig");
const sizing = @import("sizing.zig");

const Daemon = @This();

gpa: Allocator,
io: std.Io,
loop: *Loop,
/// Our executable and the helpers' socket, for new panes' command.
exe: []const u8,
sock: []const u8,
grids: Grids = .{},
panes: Panes = .{},
rex: RexSession,
nvim: NvimSession,
changes: WindowChanges = .{},
titles: Titles = .{},
/// Rex's tiled layout of the window holding our panes, as its last view had it.
rex_layout: LayoutTree = .{},
/// What `vim.g.neorex_config` last chose, as applied.
options: Options = .default,
/// Set by `stop`; `run` returns it.
stopped: ?StopReason = null,
/// How long the cursor color timer was set for, while it runs.
cursor_color_timer_ms: ?u32 = null,

pub const StopReason = enum { nvim_exited, pane_gone, signal };

/// What a loop event's token names; pane tokens fall in `_`.
pub const Token = enum(usize) { signal, nvim_socket, helper_listener, rex_socket, focus_timer, layout_timer, cursor_color_timer, _ };
pub const PaneEvent = struct { pane: *Pane, fd: Pane.PaneFd };

comptime {
    // the fixed tokens must stay below the pane tokens
    for (@typeInfo(Token).@"enum".field_values) |v| std.debug.assert(v < Pane.token_base);
}

/// The id `Pane.startup` gives the pane neorex was run in.
const startup_pane_id = 0;

/// How long losing focus waits before Neovim hears of it: focus moving
/// from one pane to another, such as into a floating pane, arrives as an
/// out then an in, and shouldn't fire FocusLost and FocusGained.
const focus_out_delay_ms = 80;

/// How long a new split waits for the app to size it before trusting its terminal's size.
const layout_wait_ms = 1000;
/// How long to wait before asking a pane's terminal for its cursor color
/// again, after an empty answer.
const cursor_color_retry_ms = 500;
/// While focus is elsewhere, how often to ask for the cursor color: quickly
/// at first, to follow a theme picker's previews, then slower once it has
/// stayed the same for a while, and not at all after a minute.
const cursor_watch = .{ .fast_ms = 30, .slow_ms = 250, .ease_after_ms = 5000, .stop_after_ms = 60000 };

/// About how many cells a Rex floating pane's frame takes, across and down.
/// Only a first guess: once made, its floats fit whatever size it is.
const layer_frame = [2]i32{ 3, 2 };

pub fn deinit(self: *Daemon) void {
    // before the panes hang up: the launching pane outlives us
    self.titles.restore(&self.panes, &self.rex);
    self.titles.deinit(self.gpa);
    self.panes.deinit(self.gpa, self.io);
    self.grids.deinit(self.gpa);
    self.changes.deinit(self.gpa);
    self.rex_layout.deinit(self.gpa);
    self.rex.deinit();
    self.* = undefined;
}

/// Adds the launcher's pane, already connected, and starts talking to
/// Neovim and Rex.
pub fn start(self: *Daemon, launch_pane: Pane) !void {
    // only ever called on startup
    std.debug.assert(self.panes.list.items.len == 0);

    const pane = try self.panes.add(self.gpa, launch_pane);

    try pane.registerWith(self.loop);
    const view = pane.terminal_surface.?.view;
    try self.nvim.attachUi(view.cols, view.rows);
    try self.rex.attach();
}

/// Runs the loop until something calls `stop`, returns why.
pub fn run(self: *Daemon, server: *net.Server) !StopReason {
    var events: [16]Loop.Event = undefined;
    while (self.stopped == null) {
        var helper_waiting = false;
        for (try self.loop.wait(&events)) |e| {
            if (tokenOf(e) == .helper_listener) helper_waiting = true;
            try self.handle(e);
            if (self.stopped != null) break;
        }
        // between batches, so no stale event reaches a new pane
        if (helper_waiting and self.stopped == null) {
            self.accept(server) catch |err| {
                std.debug.print("neorex daemon: a pane failed: {t}\n", .{err});
            };
        }
        if (self.stopped == null) try self.afterBatch();
    }
    return self.stopped.?;
}

/// Ends `run` once the current event is handled.
fn stop(self: *Daemon, reason: StopReason) void {
    self.stopped = reason;
}

fn tokenOf(e: Loop.Event) Token {
    return @fromBackingInt(@intCast(e.token));
}

/// Starts, or restarts, one of our timers.
fn addTimer(self: *Daemon, t: Token, ms: u32) !void {
    try self.loop.addTimer(@backingInt(t), ms, @backingInt(t));
}

/// Handles one loop event.
fn handle(self: *Daemon, e: Loop.Event) !void {
    switch (tokenOf(e)) {
        .signal => self.stop(.signal),
        .nvim_socket => try self.onNvim(),
        .rex_socket => try self.onRex(),
        .focus_timer => try self.sendFocus(true),
        .layout_timer => try self.layoutWaitOver(),
        .cursor_color_timer => try self.onCursorColorTimer(),
        .helper_listener => {},
        _ => try self.onPane(e.token),
    }
}

/// After each batch of events: tells Neovim whether any pane has focus,
/// and names panes and the tab after their files. Losing focus waits a
/// moment, in case another pane gains it.
fn afterBatch(self: *Daemon) !void {
    try self.sendFocus(false);
    try self.titles.sync(self.gpa, &self.panes, &self.rex, self.nvim.current_win);
}

fn sendFocus(self: *Daemon, waited: bool) !void {
    var known = false;
    var any = false;
    for (self.panes.list.items) |p| if (p.terminal_surface) |s| if (s.forwarder.focused) |f| {
        known = true;
        any = any or f;
    };
    if (!known or any == self.nvim.ui_focused) return;
    if (!any and !waited) return self.addTimer(.focus_timer, focus_out_delay_ms);
    self.nvim.ui_focused = any;
    _ = try self.nvim.client.request("nvim_ui_set_focus", 1);
    try msgpack.writeBool(self.nvim.client.writer(), any);
    try self.nvim.client.flush();
}

// panes

/// A new helper connected: match its hello to a pane waiting for it.
fn accept(self: *Daemon, server: *net.Server) !void {
    const hello = try pane_helper.acceptHello(server, self.io);
    // its window may have closed before it connected
    const pane = (if (hello.id) |id| self.panes.byId(id) else null) orelse {
        std.debug.print("neorex daemon: a helper for a pane that's gone\n", .{});
        return hello.close(self.io);
    };
    pane.terminal_surface = Surface.create(self.gpa, hello.stream, hello.tty) catch |err| {
        hello.close(self.io);
        return err;
    };
    try pane.registerWith(self.loop);
    if (pane.awaiting_layout) {
        const v = pane.terminal_surface.?.view;
        if (v.cols != sizing.rex_default_size[0] or v.rows != sizing.rex_default_size[1]) {
            pane.awaiting_layout = false;
        } else try self.addTimer(.layout_timer, layout_wait_ms);
    }
    try self.sizeWindow(pane);
    if (pane.layer != null) try self.refit(pane);
    try self.nvim.client.flush();
    try self.draw();
}

/// The app never resized a new split, or Rex a floating pane we asked it
/// to: its terminal's size is the real one.
fn layoutWaitOver(self: *Daemon) !void {
    var any = false;
    for (self.panes.list.items) |*p| if (p.awaiting_layout and p.terminal_surface != null) {
        p.awaiting_layout = false;
        any = true;
        if (p.layer != null) try self.refit(p) else try self.sizeWindow(p);
    };
    if (!any) return;
    try self.nvim.client.flush();
    try self.draw();
}

// Decode pane info from token, get the pane object, forward to
// terminal or helper_socket handler depending on which fd the event came from
fn onPane(self: *Daemon, pane_token: usize) !void {
    const decoded = Pane.decodeToken(pane_token);
    // pane might be gone
    const pane = self.panes.byId(decoded.id) orelse return;
    switch (decoded.source_fd) {
        .helper_socket => try self.onHelper(pane),
        .terminal => try self.onInput(pane),
    }
}

fn onHelper(self: *Daemon, pane: *Pane) !void {
    var buf: [64]u8 = undefined;
    const surface = pane.terminal_surface.?;
    const n = std.posix.read(surface.helper_socket.socket.handle, &buf) catch 0;
    if (n == 0) return self.paneGone(pane);

    for (buf[0..n]) |byte| switch (pane_helper.Message.fromByte(byte)) {
        .resized => return self.handleResize(pane),
        .hello => {},
        _ => {},
    };
}

fn handleResize(self: *Daemon, pane: *Pane) !void {
    const surface = pane.terminal_surface.?;
    const window_size = surface.terminal.size() catch return self.paneGone(pane);
    pane.awaiting_layout = false;
    surface.view.resize(window_size.col, window_size.row);
    try self.sizeWindow(pane);
    // whatever Rex gave, asked for or not: the floats fit it
    if (pane.layer != null) try self.refit(pane);
    if (pane == self.focusedPane()) try self.nvim.fitUiTo(pane);
    try self.nvim.client.flush();
    try self.draw();
}

fn onInput(self: *Daemon, pane: *Pane) !void {
    var buf: [4096]u8 = undefined;
    const surface = pane.terminal_surface.?;
    const n = std.posix.read(surface.terminal.fd, &buf) catch 0;
    if (n == 0) return self.paneGone(pane);

    const bytes = buf[0..n];
    if (self.typedIntoUnfocusedPane(pane, bytes)) {
        try self.makeCurrent(pane);
        try self.rex.focus(pane.rex_block);
    }

    // a floating pane's default grid is set as it draws
    if (pane.layer == null) surface.forwarder.grid = self.gridOfPane(pane) orelse 0;
    _ = try surface.forwarder.feed(self.nvim.client, bytes);
    if (surface.forwarder.ask_cursor_color) {
        surface.forwarder.ask_cursor_color = false;
        try askCursorColor(surface);
    }
    try self.scheduleCursorColor();
}

fn askCursorColor(surface: *Surface) !void {
    try surface.terminal.writer.writeAll(input.cursor_query);
    try surface.terminal.flush();
}

/// Starts the cursor color timer, or brings it forward, if a pane needs to
/// ask again: after an empty answer, or while it watches for changes.
fn scheduleCursorColor(self: *Daemon) !void {
    var soonest: ?u32 = null;
    for (self.panes.list.items) |p| if (p.terminal_surface) |s| {
        const f = &s.forwarder;
        if (f.retry_cursor_color) soonest = @min(soonest orelse cursor_color_retry_ms, cursor_color_retry_ms);
        if (f.watch_cursor_color) {
            const ms: u32 = if (f.cursor_quiet_ms < cursor_watch.ease_after_ms) cursor_watch.fast_ms else cursor_watch.slow_ms;
            soonest = @min(soonest orelse ms, ms);
        }
    };
    const ms = soonest orelse return;
    if (self.cursor_color_timer_ms) |running| if (running <= ms) return;
    self.cursor_color_timer_ms = ms;
    try self.addTimer(.cursor_color_timer, ms);
}

/// Asks again in the panes that need to: those whose terminal answered with
/// no cursor color before it had drawn them, and those watching for changes.
fn onCursorColorTimer(self: *Daemon) !void {
    const elapsed = self.cursor_color_timer_ms orelse 0;
    self.cursor_color_timer_ms = null;
    for (self.panes.list.items) |p| if (p.terminal_surface) |s| {
        const f = &s.forwarder;
        var ask = f.retry_cursor_color;
        f.retry_cursor_color = false;
        if (f.watch_cursor_color) {
            f.cursor_quiet_ms +|= elapsed;
            if (f.cursor_quiet_ms >= cursor_watch.stop_after_ms) f.watch_cursor_color = false else ask = true;
        }
        if (ask) try askCursorColor(s);
    };
    try self.scheduleCursorColor();
}

/// Typed into a pane Rex hasn't focused, as `rex send` can. The terminal's
/// own reports don't count: Rex sends focus reports as it moves focus away,
/// and a pane without focus keeps asking for the cursor color.
fn typedIntoUnfocusedPane(self: *const Daemon, pane: *const Pane, bytes: []const u8) bool {
    const win = pane.neovim_window_handle orelse return false;
    return win != self.nvim.current_win and
        !self.rex.hasFocused(pane.rex_block) and
        !input.onlyReports(pane.terminal_surface.?.forwarder.parser, bytes);
}

fn newPane(self: *Daemon, win: i64) !void {
    if (self.rex.conn == .closed) return; // no Rex: the window stays in Neovim
    const sp = self.changes.splitOf(win);
    const fixed = self.fixedPlace(sp);
    // a fixed-size window at the edge of our panes; else beside the window it came
    // from, else any pane Rex knows
    // a copy: appending below can move every pane
    const anchor: [42]u8 = blk: {
        if (fixed) |fx| break :blk fx.anchor;
        if (self.splitFrom(sp)) |f| if (f.rex_block) |b| break :blk b;
        for (self.panes.list.items) |q| if (q.layer == null) if (q.rex_block) |b| break :blk b;
        return; // no anchor yet: next flush
    };
    // starts at the guess, not Rex's default
    const size = if (fixed) |fx| sizing.fixedPaneSize(fx.fit, sp.side_by_side) else sizing.newPaneSize(self.splitFrom(sp), sp.side_by_side);
    // half, unless it has a fixed size
    const ratio = sizing.splitRatio(if (fixed) |fx| fx.fit.share else 0.5, sp.before);
    const pane = try self.panes.addForWindow(self.gpa, win);
    pane.awaiting_layout = true;
    const pane_id = pane.id;
    self.changes.forgetSplit(win);

    var id_buf: [16]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{pane_id});
    try self.rex.request(.{ .new_split = pane_id }, "session.new_split", .{
        .session_id = self.rex.session_id,
        .anchor_id = @as([]const u8, &anchor),
        .direction = if (sp.side_by_side) "horizontal" else "vertical",
        .side = if (sp.before) "before" else "after",
        .ratio = ratio,
        .layout = .{ .block = .{
            .flavor = "com.superlogical.terminal.shell",
            .label = "neorex",
            .options = .{
                .shell = "none",
                .command = &[_][]const u8{ self.exe, "pane", self.sock, id },
                .size = .{ .columns = size[0], .rows = size[1] },
            },
        } },
    });
}

/// The helper or terminal went away: Rex closed the pane. Close its
/// window, or end if it was the last pane.
fn paneGone(self: *Daemon, p: *Pane) !void {
    p.closing = .rex_pane_closed;
    const i = self.panes.indexOf(p.id).?;
    if (p.layer) |l| {
        // closed in Rex: close its floats, which the plugin notices
        self.panes.remove(self.gpa, self.io, self.loop, i);
        for (l.group.topGrids()) |top| if (self.grids.winOn(top)) |w| try windows.close(self.nvim.client, w.win);
        try self.nvim.client.flush();
        return;
    }
    if (!self.otherTiledPanes(p.id)) {
        self.stop(.pane_gone);
        return;
    }
    const maybe_win = p.neovim_window_handle;
    self.panes.remove(self.gpa, self.io, self.loop, i);
    const win = maybe_win orelse return;
    try self.changes.markClosing(self.gpa, win);
    try windows.close(self.nvim.client, win);
    try self.nvim.client.flush();
}

/// Another pane than `id` shows, or will show, an ordinary window.
fn otherTiledPanes(self: *const Daemon, id: u32) bool {
    for (self.panes.list.items) |q| {
        if (q.id != id and q.closing != .request_failed and q.layer == null) return true;
    }
    return false;
}

// Neovim

fn onNvim(self: *Daemon) !void {
    if (!try self.nvim.client.read(self.gpa)) return self.stop(.nvim_exited);
    while (try self.nvim.client.next()) |msg| switch (msg) {
        .notification => |n| {
            var params = n.params;
            if (std.mem.eql(u8, n.method, "redraw")) {
                if (try self.grids.applyRedraw(self.gpa, &params)) {
                    try self.reconcile();
                    try self.draw();
                }
            } else if (std.mem.eql(u8, n.method, Options.method)) {
                try self.onOptions(&params);
            } else if (try windows.parseNote(n.method, &params)) |note| switch (note) {
                .current => |win| try self.onCurrent(win),
                .float => |win| try self.onCurrentFloat(win),
                .entered => |win| try self.onEnteredFloat(win),
                .reopen => |win| if (self.panes.byWin(win) != null) try self.changes.markReopening(self.gpa, win),
                .split => |sp| if (self.panes.byWin(sp.win) == null) try self.changes.noteSplit(self.gpa, sp),
                .fixed => |fx| self.changes.noteFixed(fx),
                .resize => |rz| try self.onResize(rz),
                .title => |t| try self.titles.set(self.gpa, t),
                .cmdheight => |rows| try self.onCmdheight(rows),
            };
        },
        .request => |r| try self.nvim.client.respondError(r.id, "neorex serves no requests"),
        .response => |r| {
            var result = r.result;
            if (r.id == self.nvim.current_win_req) self.nvim.current_win_req = null;
            var show_now = false;
            for (self.panes.list.items) |*p| if (p.layer) |*l| if (l.fit == r.id) {
                // the refit redraws before it answers (`place_group`), so
                // the floats are where it left them: settled, and shown
                l.fit = null;
                l.settled = l.group.box;
                show_now = true;
            };
            if (show_now) try self.draw();
            if (r.err) |e| {
                std.debug.print("neovim error: {s}\n", .{e});
            } else if (r.id == self.nvim.channel_req) {
                const size = sizing.windowSize(self.panes.byId(startup_pane_id).?, self.nvim.cmd_rows);
                self.nvim.setup_req = try windows.setup(self.nvim.client, try windows.parseChannel(&result), size[0], size[1]);
                try self.nvim.client.flush();
            } else if (r.id == self.nvim.setup_req) {
                const wins = try windows.parseSetup(&result);
                if (self.panes.byId(startup_pane_id)) |launch| launch.neovim_window_handle = wins[0];
                self.nvim.ready = true;
                try self.reconcile();
                try self.draw();
            }
        },
    };
}

/// The Lua sent `vim.g.neorex_config`: say what's wrong with it, and do
/// what changed.
fn onOptions(self: *Daemon, params: *msgpack.Decoder) !void {
    var buf: [1024]u8 = undefined;
    var problems: std.Io.Writer = .fixed(&buf);
    const new = try Options.decode(params, &problems);
    if (problems.end > 0) try warn(self.nvim.client, problems.buffered());
    var effects: [Options.max_effects]Options.Effect = undefined;
    for (Options.diff(self.options, new, &effects)) |e| switch (e) {
        .vim_ui => |v| try setVimUi(self.nvim.client, @tagName(v.func), v.surface == .rex),
        // each comes with the feature it turns on
        .ui_option, .palette => {},
    };
    self.options = new;
    try self.nvim.client.flush();
}

/// Hands `vim.ui.<func>` to Rex's palette, or gives back what it replaced.
/// Without neorex's runtime on 'runtimepath' there's nothing to hand it to.
fn setVimUi(nvim: *Nvim, func: []const u8, rex: bool) !void {
    _ = try nvim.execLua(
        \\local ok, ui = pcall(require, 'neorex.ui')
        \\if ok then ui.set(...) end
    , 2);
    try msgpack.writeStr(nvim.writer(), func);
    try msgpack.writeBool(nvim.writer(), rex);
}

/// Shows `lines`, one problem each, as a warning in Neovim.
fn warn(nvim: *Nvim, lines: []const u8) !void {
    _ = try nvim.execLua(
        \\local text = ...
        \\local out = {}
        \\for line in text:gmatch('[^\n]+') do out[#out + 1] = 'neorex: ' .. line end
        \\vim.notify(table.concat(out, '\n'), vim.log.levels.WARN)
    , 1);
    try msgpack.writeStr(nvim.writer(), lines);
}

/// Neovim resized a window and put it back: move its pane's borders in Rex
/// instead, one `resize_pane` for each way it changed. The new size comes
/// back like any other, as Rex resizing the pane.
fn onResize(self: *Daemon, rz: windows.Resize) !void {
    const p = self.panes.byWin(rz.win) orelse return;
    if (p.layer != null) return;
    const block = p.rex_block orelse return;
    // zoomed, the pane fills the window whatever its borders say
    if (self.rex_layout.zoomed_block != null) return;
    // the editor spans the Rex window, so its size is the window's
    const window = self.nvim.editor_size;
    for ([_]LayoutTree.Direction{ .horizontal, .vertical }, [_]i32{ rz.cols, rz.rows }, 0..) |dir, delta, axis| {
        const b = self.rex_layout.border(&block, dir) orelse continue;
        const n = self.rex_layout.node(b.split);
        const across = sizing.scaled(window[axis], n.rect[2 + axis]);
        const ratio = sizing.movedRatio(n.kind.split.ratio, delta, across, b.side == .before) orelse continue;
        self.rex_layout.setRatio(b.split, ratio);
        try self.rex.request(.resize_pane, "session.resize_pane", .{
            .session_id = self.rex.session_id,
            .direction = @tagName(dir),
            .before_block_id = @as([]const u8, &b.before_block),
            .after_block_id = @as([]const u8, &b.after_block),
            .ratio = ratio,
        });
    }
}

/// 'cmdheight' changed: give each window the rows its pane no longer keeps
/// for the command line, or take them back.
fn onCmdheight(self: *Daemon, rows: u32) !void {
    if (rows == self.nvim.cmd_rows) return;
    self.nvim.cmd_rows = rows;
    for (self.panes.list.items) |*p| try self.sizeWindow(p);
    try self.nvim.client.flush();
}

/// Neovim's current window changed: focus its pane in Rex.
fn onCurrent(self: *Daemon, win: i64) !void {
    // sent before our own change ran; the report after it is coming
    if (self.nvim.current_win_req != null) return;
    self.nvim.current_float = 0;
    self.nvim.current_win = win;
    const p = self.panes.byWin(win) orelse return;
    try self.nvim.fitUiTo(p);
    try self.draw();
    try self.rex.focus(p.rex_block);
}

/// A float became current: if it's in a floating pane, focus that.
fn onCurrentFloat(self: *Daemon, win: i64) !void {
    self.nvim.current_float = win;
    const p = self.layerOfWin(win) orelse return;
    try self.rex.focus(p.rex_block);
}

/// A float took focus. Usually before it's drawn, so the next flush gives
/// its group a floating pane; if it's already showing in a pane, now.
fn onEnteredFloat(self: *Daemon, win: i64) !void {
    self.nvim.noteEntered(win);
    if (!self.nvim.ready or self.grids.gridOf(win) == null or self.layerOfWin(win) != null) return;
    try self.reconcileLayers();
    try self.nvim.client.flush();
    try self.draw();
}

/// Matches panes to windows: new external windows get panes, ordinary ones
/// are made external, and panes whose windows closed hang up.
fn reconcile(self: *Daemon) !void {
    if (!self.nvim.ready) return;
    var i = self.panes.list.items.len;
    while (i > 0) {
        i -= 1;
        const p = &self.panes.list.items[i];
        const win = p.neovim_window_handle orelse continue;
        if (self.grids.gridOf(win) != null) continue;
        self.titles.forget(self.gpa, win);
        if (self.changes.takeReopening(win)) {
            p.neovim_window_handle = null;
            continue;
        }
        p.closing = .window_closed;
        // close the Rex pane ourselves: Rex can keep a pane open after its
        // helper exits (as when neo-tree opens and closes quickly), showing
        // "exited". Before Rex answers there's no block yet, and
        // onSplitMade closes it.
        if (p.rex_block) |*b| try self.rex.closeBlock(b);
        self.panes.remove(self.gpa, self.io, self.loop, i);
    }
    if (self.panes.list.items.len == 0) {
        self.stop(.pane_gone);
        return;
    }
    self.changes.forgetGone(&self.grids);

    for (self.grids.wins.values()) |w| switch (w.kind) {
        .ordinary => {
            if (!try self.changes.shouldAdopt(self.gpa, w.win)) continue;
            const size = if (self.panes.byWin(w.win)) |p| sizing.windowSize(p, self.nvim.cmd_rows) else self.newWindowSize(w.win);
            try windows.adopt(self.nvim.client, w.win, size[0], size[1]);
        },
        .external => {
            self.changes.becameExternal(w.win);
            if (self.panes.byWin(w.win) != null or self.changes.isClosing(w.win)) continue;
            if (self.waitingPane()) |p| {
                p.neovim_window_handle = w.win;
            } else {
                try self.newPane(w.win);
            }
        },
        .float, .hidden => {},
    };
    for (self.panes.list.items) |*p| try self.sizeWindow(p);
    try self.reconcileLayers();
    try self.nvim.client.flush();
}

/// A pane kept for a reopened window.
fn waitingPane(self: *const Daemon) ?*Pane {
    for (self.panes.list.items) |*p| if (p.layer == null and p.neovim_window_handle == null and p.terminal_surface != null) return p;
    return null;
}

/// A guess until the new pane says its size: half the pane it splits, or a
/// fixed-size window's size.
fn newWindowSize(self: *const Daemon, win: i64) [2]u32 {
    const sp = self.changes.splitOf(win);
    if (self.fixedPlace(sp)) |fx| {
        const size = sizing.fixedPaneSize(fx.fit, sp.side_by_side);
        return .{ size[0], @max(size[1] -| self.nvim.cmd_rows, 1) };
    }
    return sizing.newWindowSize(self.splitFrom(sp), sp.side_by_side, self.nvim.cmd_rows);
}

/// Where fixed-size window `sp` opens: beside the smallest part of Rex's layout that
/// holds all our tiled panes, like Neovim's :topleft at the editor's edge.
/// Null for an ordinary split, or before Rex has shown us a layout or the
/// editor's size.
fn fixedPlace(self: *const Daemon, sp: windows.Split) ?struct { anchor: [42]u8, fit: sizing.Fixed } {
    if (sp.fixed_cells == 0) return null;
    const window = self.nvim.editor_size;
    if (window[0] == 0 or window[1] == 0) return null;
    const edge = self.rex_layout.edgeAround(OurTiledBlocks{ .panes = &self.panes }) orelse return null;
    const id = self.rex_layout.idOf(edge) orelse return null;
    if (id.len != 42) return null;
    return .{
        .anchor = id[0..42].*,
        // the editor spans the Rex window, so its size is the window's
        .fit = sizing.fixed(window, self.rex_layout.node(edge).rect, sp.fixed_cells, sp.side_by_side, self.nvim.cmd_rows),
    };
}

/// Claims the blocks of our tiled panes, for `LayoutTree.edgeAround`.
const OurTiledBlocks = struct {
    panes: *const Panes,
    pub fn isOurs(self: OurTiledBlocks, block: []const u8) bool {
        const p = self.panes.byBlock(block) orelse return false;
        return p.layer == null;
    }
};

/// The pane a new window splits: its origin's, else the focused one.
fn splitFrom(self: *const Daemon, sp: windows.Split) ?*Pane {
    if (sp.from != 0) if (self.panes.byWin(sp.from)) |p| return p;
    return self.focusedPane();
}

// Rex

fn onRex(self: *Daemon) !void {
    if (!try self.rex.read()) return self.loop.remove(self.rex.client.fd());
    while (try self.rex.next()) |update| switch (update) {
        .split_made => |made| try self.onSplitMade(made.pane, made.block),
        // a floating pane that failed leaves its floats drawn in the pane
        .split_failed, .layer_failed => |failed| if (self.panes.byId(failed.pane)) |p| {
            p.closing = .request_failed;
        },
        .layer_made => |made| try self.onLayerMade(made.pane, made.block, made.layer),
        .layer_resized => |id| if (self.panes.byId(id)) |p| if (p.layer) |*l| {
            l.bounds_asked -|= 1;
        },
        .layout => |wins| try self.onLayout(wins),
        .focus_moved => |block| try self.onRexFocus(block),
    };
}

/// Rex made the pane's split: link the block and let Rex size it.
fn onSplitMade(self: *Daemon, pane_id: u32, block: []const u8) !void {
    // its window closed while Rex made it: nothing will draw there
    const p = self.panes.byId(pane_id) orelse return self.rex.closeBlock(block);
    p.rex_block = Pane.rexBlock(block) catch blk: {
        std.debug.print("neorex daemon: not a block id: {s}\n", .{block});
        break :blk null;
    };
    try self.rex.disown(block);
    if (p.neovim_window_handle == self.nvim.current_win) try self.rex.focus(p.rex_block);
}

/// Rex made the floating pane's layer: link it, and focus it if its float is current.
fn onLayerMade(self: *Daemon, pane_id: u32, block: []const u8, layer: ?[]const u8) !void {
    // its floats closed while Rex made it: nothing will draw there
    const p = self.panes.byId(pane_id) orelse {
        if (layer) |id| return self.rex.closeLayer(id);
        return self.rex.closeBlock(block);
    };
    p.rex_block = Pane.rexBlock(block) catch blk: {
        std.debug.print("neorex daemon: not a block id: {s}\n", .{block});
        break :blk null;
    };
    try self.rex.disown(block);
    const l = &p.layer.?;
    if (layer) |id| l.id = Pane.rexLayer(id) catch null;
    l.bounds_asked -|= 1;
    if (self.nvim.current_float != 0 and self.layerOfWin(self.nvim.current_float) == p) try self.rex.focus(p.rex_block);
}

/// The user focused one of our panes in Rex: make its window current.
fn onRexFocus(self: *Daemon, block: []const u8) !void {
    const p = self.panes.byBlock(block) orelse return;
    if (p.layer) |*l| {
        // clicked into a floating pane: into one of its floats, if not there
        if (self.nvim.current_float != 0 and self.layerOfWin(self.nvim.current_float) == p) return;
        const win = self.focusableIn(&l.group) orelse return;
        self.nvim.current_float = win;
        _ = try windows.setCurrent(self.nvim.client, win);
        try self.nvim.client.flush();
        return;
    }
    const win = p.neovim_window_handle orelse return;
    // back from a float to the window under it counts as a move
    if (win == self.nvim.current_win and self.nvim.current_float == 0) return;
    self.nvim.current_float = 0;
    try self.makeCurrent(p);
    try self.nvim.client.flush();
    try self.draw();
}

/// A newer view: where our panes sit, so the editor and floats fit.
fn onLayout(self: *Daemon, wins: []const std.json.Value) !void {
    try self.readLayout(wins);
    if (self.focusedPane()) |f| try self.nvim.fitUiTo(f);
    try self.nvim.client.flush();
    try self.draw();
}

/// Remembers which Rex window holds our panes, and where each sits in it.
fn readLayout(self: *Daemon, wins: []const std.json.Value) !void {
    for (wins) |w| {
        var blocks = try layout.readWindow(self.gpa, w);
        defer blocks.deinit(self.gpa);
        for (blocks.floating.items) |f| self.onLayerBounds(f.block, f.rect);
        var ours = false;
        for (blocks.tiled.items) |t| if (self.panes.byBlock(t.block)) |p| {
            p.rect = t.rect;
            ours = true;
        };
        if (!ours) continue;
        try self.rex_layout.read(self.gpa, w);
        const id = Client.getStr(w, "window_id") orelse continue;
        if (id.len == 43) self.rex.window = id[0..43].*;
        self.titles.readWindow(self.gpa, &self.panes, &self.rex, w);
    }
}

/// A floating layer of ours somewhere else: the user moved it, so its
/// floats follow, and from now on its size is theirs.
fn onLayerBounds(self: *Daemon, block: []const u8, bounds: layout.Rect) void {
    const p = self.panes.byBlock(block) orelse return;
    const l = if (p.layer) |*l| l else return;
    // a view from before Rex did what we asked
    if (l.bounds_asked > 0) return;
    if (self.sameBounds(bounds, l.bounds)) return;
    l.bounds = bounds;
    l.user_placed = true;
    self.sizeLayer(p, self.layerSize(bounds)) catch {};
}

// floating panes

/// Matches floating panes to groups of floats: new groups get one, and
/// those whose group closed hang up. A floating pane opens at the size its
/// floats ask for, then its size is Rex's: when they ask again, Rex may
/// grant it (`onFloatsMoved`), and either way they fit what Rex gives.
fn reconcileLayers(self: *Daemon) !void {
    var buf: [FloatGroups.max_groups]FloatGroups.Group = undefined;
    const groups = if (self.rex.conn != .closed) FloatGroups.find(&self.grids, self.nvim.enteredFloats(), &buf) else buf[0..0];
    var i = self.panes.list.items.len;
    while (i > 0) {
        i -= 1;
        const p = &self.panes.list.items[i];
        const l = if (p.layer) |*l| l else continue;
        const g = for (groups) |*g| {
            if (g.key == l.group.key) break g;
        } else {
            // without an id Rex hasn't answered yet: the answer closes it
            if (l.id) |*id| try self.rex.closeLayer(id);
            if (p.closing == null) p.closing = .window_closed;
            self.panes.remove(self.gpa, self.io, self.loop, i);
            continue;
        };
        l.group = g.*;
        // Floats that move or resize themselves, as which-key's do on every
        // key, ask for the pane's size again. Once per move of their own:
        // where a refit lands, even if not quite where asked, is settled,
        // so this never chases itself.
        if (l.fit == null and !std.mem.eql(i64, &l.group.box, &l.settled)) {
            l.settled = l.group.box;
            try self.onFloatsMoved(p);
        }
    }
    for (groups) |g| {
        if (self.panes.byLayerKey(g.key) == null) try self.newLayer(g);
    }
}

/// A floating pane's floats moved or resized themselves: a request for
/// another size and place, which Rex grants as far as the window allows,
/// unless the user placed the pane. Either way the floats end up fitting
/// the pane Rex gives, and nothing is drawn until then.
fn onFloatsMoved(self: *Daemon, p: *Pane) !void {
    const l = &p.layer.?;
    // the user's size wins; and until Rex has made it, there's nothing to ask
    if (l.user_placed or l.id == null or p.rex_block == null) return self.refit(p);
    const bounds = self.layerBounds(l.group) orelse return self.refit(p);
    if (!self.sameBounds(bounds, l.bounds)) {
        try self.rex.resizeLayer(p.id, &l.id.?, bounds);
        l.bounds = bounds;
        l.bounds_asked += 1;
    }
    try self.sizeLayer(p, self.layerSize(bounds));
}

/// Gives a floating pane's terminal `size` and fits its floats to it. No
/// app sizes that terminal (none owns it), so we ask Rex, and the floats fit
/// once it says its size (`handleResize`), or once the wait is over.
fn sizeLayer(self: *Daemon, p: *Pane, size: [2]u32) !void {
    const s = p.terminal_surface orelse return;
    if (s.view.cols == size[0] and s.view.rows == size[1]) return self.refit(p);
    try self.rex.resizeTerminal(&p.rex_block.?, size[0], size[1]);
    p.awaiting_layout = true;
    try self.addTimer(.layout_timer, layout_wait_ms);
}

/// Fits a floating pane's floats to it, holding it back until they do.
fn refit(self: *Daemon, p: *Pane) !void {
    if (try self.followLayer(p)) |req| p.layer.?.fit = req;
}

/// Bounds for a floating pane on `g`, as fractions of the window: the cells
/// its floats asked for, with the frame Rex draws inside them, so it covers
/// nothing they kept clear of, such as the statusline under which-key. Too
/// small to hold the frame and a cell, as a one-line notification is, it
/// grows evenly around them.
fn layerBounds(self: *const Daemon, g: FloatGroups.Group) ?[4]f64 {
    const screen = self.grids.get(1) orelse return null;
    if (screen.width == 0 or screen.height == 0) return null;
    const sw: f64 = @floatFromInt(screen.width);
    const sh: f64 = @floatFromInt(screen.height);
    const b = g.box;
    const cells_w = @max(b[2], layer_frame[0] + 1);
    const cells_h = @max(b[3], layer_frame[1] + 1);
    const w = @min(@as(f64, @floatFromInt(cells_w)) / sw, 1);
    const h = @min(@as(f64, @floatFromInt(cells_h)) / sh, 1);
    const col = b[1] - @divFloor(cells_w - b[2], 2);
    const row = b[0] - @divFloor(cells_h - b[3], 2);
    const x = std.math.clamp(@as(f64, @floatFromInt(col)) / sw, 0, 1 - w);
    const y = std.math.clamp(@as(f64, @floatFromInt(row)) / sh, 0, 1 - h);
    return .{ x, y, w, h };
}

/// The terminal size, cols x rows, inside a floating pane at `bounds`: its
/// cells on grid 1, less the frame Rex draws around it.
fn layerSize(self: *const Daemon, bounds: [4]f64) [2]u32 {
    const screen = self.grids.get(1) orelse return sizing.rex_default_size;
    const cells = [2]i64{
        @intFromFloat(@round(bounds[2] * @as(f64, @floatFromInt(screen.width)))),
        @intFromFloat(@round(bounds[3] * @as(f64, @floatFromInt(screen.height)))),
    };
    return .{ @intCast(@max(cells[0] - layer_frame[0], 1)), @intCast(@max(cells[1] - layer_frame[1], 1)) };
}

fn newLayer(self: *Daemon, g: FloatGroups.Group) !void {
    const bounds = self.layerBounds(g) orelse return;
    const pane = try self.panes.addForGroup(self.gpa, g);
    pane.layer.?.bounds = bounds;
    // until Rex makes it, views don't show where it is
    pane.layer.?.bounds_asked = 1;
    const pane_id = pane.id;
    const size = self.layerSize(bounds);

    var id_buf: [16]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{pane_id});
    try self.rex.newLayer(pane_id, bounds, .{ .block = .{
        .flavor = "com.superlogical.terminal.shell",
        .label = "neorex",
        .options = .{
            .shell = "none",
            // a login session prints "Last login" before the pane draws
            .login = false,
            .command = &[_][]const u8{ self.exe, "pane", self.sock, id },
            // the size it shows at: no Rex app sizes a floating pane's
            // terminal (the block has no owner once we disown it), so
            // without this it stays 80x24, and Rex shows only the top left
            // of one bigger than the pane, as which-key's
            .size = .{ .columns = size[0], .rows = size[1] },
        },
    } });
}

/// Within half a cell of each other on grid 1.
fn sameBounds(self: *const Daemon, a: [4]f64, b: [4]f64) bool {
    const screen = self.grids.get(1) orelse return true;
    const half = [2]f64{ 0.5 / @as(f64, @floatFromInt(@max(screen.width, 1))), 0.5 / @as(f64, @floatFromInt(@max(screen.height, 1))) };
    for (a, b, 0..) |x, y, i| if (@abs(x - y) >= half[i % 2]) return false;
    return true;
}

/// Fits a floating pane's floats to where it is and the size Rex gave it.
/// Returns the request's id, if it sent one.
fn followLayer(self: *Daemon, p: *Pane) !?u32 {
    const l = if (p.layer) |*l| l else return null;
    const s = p.terminal_surface orelse return null;
    const screen = self.grids.get(1) orelse return null;
    if (screen.width == 0 or screen.height == 0) return null;
    // somewhere on the screen, or Neovim moves the floats back onto it and
    // they never get there
    const w = @min(s.view.cols, screen.width);
    const h = @min(s.view.rows, screen.height);
    const at_row: i32 = @as(i32, @intFromFloat(@round(l.bounds[1] * @as(f64, @floatFromInt(screen.height))))) + @divFloor(layer_frame[1], 2);
    const at_col: i32 = @as(i32, @intFromFloat(@round(l.bounds[0] * @as(f64, @floatFromInt(screen.width))))) + @divFloor(layer_frame[0], 2);
    const row = std.math.clamp(at_row, 0, @as(i32, @intCast(screen.height - h)));
    const col = std.math.clamp(at_col, 0, @as(i32, @intCast(screen.width - w)));
    const g = l.group;
    if (std.mem.eql(i64, &g.box, &.{ row, col, w, h })) return null;
    var wins: [16]i64 = undefined;
    var n: usize = 0;
    for (g.topGrids()) |top| if (self.grids.winOn(top)) |on| {
        wins[n] = on.win;
        n += 1;
    };
    if (n == 0) return null;
    return try windows.placeGroup(self.nvim.client, wins[0..n], row, col, w, h);
}

/// The floating pane showing float `win`, if one does.
fn layerOfWin(self: *const Daemon, win: i64) ?*Pane {
    const grid = self.grids.gridOf(win) orelse return null;
    const top = (self.grids.place(grid) orelse return null).top;
    if (top == 0) return null;
    for (self.panes.list.items) |*p| if (p.layer) |*l| if (l.group.hasTop(top)) return p;
    return null;
}

/// A float in group `g` that takes focus: the input of a picker, which
/// stacks above its box.
fn focusableIn(self: *const Daemon, g: *const FloatGroups.Group) ?i64 {
    var best: ?Grids.Win = null;
    for (self.grids.wins.keys(), self.grids.wins.values()) |id, w| {
        if (w.kind != .float or !w.float.focusable) continue;
        const top = (self.grids.place(id) orelse continue).top;
        if (top == 0 or !g.hasTop(top)) continue;
        if (best == null or w.float.zindex > best.?.float.zindex) best = w;
    }
    return if (best) |w| w.win else null;
}

// shared

/// Draws every pane that changed.
fn draw(self: *Daemon) !void {
    const focused = self.focusedPane();
    // floats in floating panes stay out of the others
    var skip_buf: [FloatGroups.max_groups * 16]u32 = undefined;
    var skip_n: usize = 0;
    for (self.panes.list.items) |p| if (p.layerHides()) for (p.layer.?.group.topGrids()) |t| {
        if (skip_n == skip_buf.len) break;
        skip_buf[skip_n] = t;
        skip_n += 1;
    };
    var i = self.panes.list.items.len;
    while (i > 0) {
        i -= 1;
        // backwards, so removing this pane leaves the ones still to draw in place
        const p = &self.panes.list.items[i];
        const s = p.terminal_surface orelse continue;
        // a floating pane waiting on its refit shows nothing yet; what
        // changes meanwhile is marked drawn below, so it draws whole once shown
        if (p.layer != null and !p.layerShown()) {
            s.view.full = true;
            continue;
        }
        const drawn = if (p.layer) |*l| blk: {
            var mbuf: [Grids.max_floats]Grids.Placed = undefined;
            const members = FloatGroups.members(&self.grids, &l.group, &mbuf);
            s.forwarder.grid = if (members.len > 0) members[0].grid else 1;
            // the terminal's top left is where its editor floats start
            const origin = [2]i32{ @intCast(l.group.box[0]), @intCast(l.group.box[1]) };
            break :blk s.view.frameFloats(&self.grids, members, origin, &s.terminal.writer) catch false;
        } else s.view.frame(&self.grids, self.gridOfPane(p), .{
            .focused = p == focused,
            .origin = self.paneOrigin(p),
            .skip = skip_buf[0..skip_n],
        }, &s.terminal.writer) catch false;
        setTargets(&s.forwarder, s.view.drawnFloats());
        if (drawn) s.terminal.flush() catch try self.paneGone(p);
    }
    // drawn into one pane at most; done with them
    if (self.grids.msg_grid) |id| if (self.grids.get(id)) |m| {
        m.dirty.unsetAll();
        m.scrolls_len = 0;
    };
    for (self.grids.wins.keys(), self.grids.wins.values()) |id, w| if (w.kind == .float) if (self.grids.get(id)) |f| {
        f.dirty.unsetAll();
        f.scrolls_len = 0;
    };
}

/// Mouse events on the floats drawn go to their grids.
fn setTargets(f: *Forwarder, rects: []const PaneView.Rect) void {
    var buf: [Forwarder.max_targets]Forwarder.Target = undefined;
    const n = @min(rects.len, buf.len);
    for (rects[0..n], buf[0..n]) |r, *t| t.* = .{ .grid = r.grid, .row = r.row, .col = r.col, .width = r.width, .height = r.height };
    f.setTargets(buf[0..n]);
}

/// Where pane `p`'s top left sits on grid 1: row, col.
fn paneOrigin(self: *const Daemon, p: *const Pane) [2]i32 {
    const r = p.rect orelse return .{ 0, 0 };
    const screen = self.grids.get(1) orelse return .{ 0, 0 };
    return .{
        @intFromFloat(@round(r[1] * @as(f64, @floatFromInt(screen.height)))),
        @intFromFloat(@round(r[0] * @as(f64, @floatFromInt(screen.width)))),
    };
}

/// Asks Neovim for the window to fit the pane, unless it already was.
fn sizeWindow(self: *Daemon, p: *Pane) !void {
    const s = p.terminal_surface orelse return;
    if (p.awaiting_layout) return;
    const win = p.neovim_window_handle orelse return;
    const grid = self.grids.gridOf(win) orelse return;
    const size = s.windowSize(self.nvim.cmd_rows);
    const last = p.last_asked_win_size;
    if (last.grid == grid and last.cols == size[0] and last.rows == size[1]) return;
    p.last_asked_win_size = .{ .grid = grid, .cols = size[0], .rows = size[1] };
    try windows.size(self.nvim.client, win, size[0], size[1]);
}

/// Makes the pane's window Neovim's current one, sized to the pane.
fn makeCurrent(self: *Daemon, pane: *Pane) !void {
    const win = pane.neovim_window_handle.?;
    self.nvim.current_win = win;
    self.nvim.current_win_req = try windows.setCurrent(self.nvim.client, win);
    try self.nvim.fitUiTo(pane);
}

/// The pane showing Neovim's current window; before setup, the launcher's.
fn focusedPane(self: *const Daemon) ?*Pane {
    if (self.nvim.current_win == 0) return self.panes.byId(startup_pane_id);
    return self.panes.byWin(self.nvim.current_win);
}

/// The grid showing the pane's window, if it has one yet.
fn gridOfPane(self: *const Daemon, pane: *const Pane) ?u32 {
    const win = pane.neovim_window_handle orelse return null;
    return self.grids.gridOf(win);
}
