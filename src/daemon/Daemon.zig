//! The running daemon: Neovim, its grids, the Rex connection, and a pane
//! per window. After each Neovim flush, `reconcile` gives new windows panes
//! and hangs up panes whose windows closed; then every pane is drawn.
// TODO: Needs a pretty major rewrite

const std = @import("std");
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const input = @import("../term/input.zig");
const Nvim = @import("../nvim/Nvim.zig");
const msgpack = @import("../nvim/msgpack.zig");
const windows = @import("../nvim/windows.zig");
const Grids = @import("../screen/Grids.zig");
const Loop = @import("Loop.zig");
const Pane = @import("Pane.zig");
const Panes = @import("Panes.zig");
const RexSession = @import("../rex/Session.zig");
const NvimSession = @import("NvimSession.zig");
const WindowChanges = @import("WindowChanges.zig");
const Surface = @import("Surface.zig");
const pane_helper = @import("pane_helper.zig");

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
/// Set by `stop`; `run` returns it.
stopped: ?StopReason = null,

pub const StopReason = enum { nvim_exited, pane_gone, signal };

/// What a loop event's token names; pane tokens fall in `_`.
pub const Token = enum(usize) { signal, nvim_socket, helper_listener, rex_socket, _ };
pub const PaneEvent = struct { pane: *Pane, fd: Pane.PaneFd };

comptime {
    // the fixed tokens must stay below the pane tokens
    for (@typeInfo(Token).@"enum".field_values) |v| std.debug.assert(v < Pane.token_base);
}

/// The id `Pane.startup` gives the pane neorex was run in.
const startup_pane_id = 0;

pub fn deinit(self: *Daemon) void {
    self.panes.deinit(self.gpa, self.io);
    self.grids.deinit(self.gpa);
    self.changes.deinit(self.gpa);
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

/// Handles one loop event.
fn handle(self: *Daemon, e: Loop.Event) !void {
    switch (tokenOf(e)) {
        .signal => self.stop(.signal),
        .nvim_socket => try self.onNvim(),
        .rex_socket => try self.onRex(),
        .helper_listener => {},
        _ => try self.onPane(e.token),
    }
}

/// After each batch of events: tells Neovim whether any pane has focus.
fn afterBatch(self: *Daemon) !void {
    var known = false;
    var any = false;
    for (self.panes.list.items) |p| if (p.terminal_surface) |s| if (s.forwarder.focused) |f| {
        known = true;
        any = any or f;
    };
    if (!known or any == self.nvim.ui_focused) return;
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
    try self.sizeWindow(pane);
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
    surface.view.resize(window_size.col, window_size.row);
    try self.sizeWindow(pane);
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

    surface.forwarder.grid = self.gridOfPane(pane) orelse 0;
    _ = try surface.forwarder.feed(self.nvim.client, bytes);
}

/// Typed into a pane Rex hasn't focused, as `rex send` can. Focus reports
/// don't count: Rex sends them as it moves focus away.
fn typedIntoUnfocusedPane(self: *const Daemon, pane: *const Pane, bytes: []const u8) bool {
    const win = pane.neovim_window_handle orelse return false;
    return win != self.nvim.current_win and
        !self.rex.hasFocused(pane.rex_block) and
        !input.onlyFocusReports(bytes);
}

fn newPane(self: *Daemon, win: i64) !void {
    if (self.rex.conn == .closed) return; // no Rex: the window stays in Neovim
    const sp = self.changes.splitOf(win);
    // beside the window it came from, else any pane Rex knows
    // a copy: appending below can move every pane
    const anchor: Pane.RexBlock = blk: {
        if (self.splitFrom(sp)) |f| if (f.rex_block) |b| break :blk b;
        for (self.panes.list.items) |q| if (q.rex_block) |b| break :blk b;
        return; // no anchor yet: next flush
    };
    const pane_id = (try self.panes.addForWindow(self.gpa, win)).id;
    self.changes.forgetSplit(win);

    var id_buf: [16]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{pane_id});
    try self.rex.request(.{ .new_split = pane_id }, "session.new_split", .{
        .session_id = self.rex.session_id,
        .anchor_id = @as([]const u8, &anchor),
        .direction = if (sp.side_by_side) "horizontal" else "vertical",
        .side = if (sp.before) "before" else "after",
        .layout = .{ .block = .{
            .flavor = "com.superlogical.terminal.shell",
            .label = "neorex",
            .options = .{ .shell = "none", .command = &[_][]const u8{ self.exe, "pane", self.sock, id } },
        } },
    });
}

/// The helper or terminal went away: Rex closed the pane. Close its
/// window, or end if it was the last pane.
fn paneGone(self: *Daemon, p: *Pane) !void {
    p.closing = .rex_pane_closed;
    const i = self.panes.indexOf(p.id).?;
    var others = false;
    for (self.panes.list.items) |q| {
        if (q.id != p.id and q.closing != .request_failed) others = true;
    }
    if (!others) {
        self.stop(.pane_gone);
        return;
    }
    const maybe_win = p.neovim_window_handle;
    self.panes.remove(self.gpa, self.io, i);
    const win = maybe_win orelse return;
    try self.changes.markClosing(self.gpa, win);
    try windows.close(self.nvim.client, win);
    try self.nvim.client.flush();
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
            } else if (try windows.parseNote(n.method, &params)) |note| switch (note) {
                .current => |win| try self.onCurrent(win),
                .reopen => |win| if (self.panes.byWin(win) != null) try self.changes.markReopening(self.gpa, win),
                .split => |sp| if (self.panes.byWin(sp.win) == null) try self.changes.noteSplit(self.gpa, sp),
            };
        },
        .request => |r| try self.nvim.client.respondError(r.id, "neorex serves no requests"),
        .response => |r| {
            var result = r.result;
            if (r.id == self.nvim.current_win_req) self.nvim.current_win_req = null;
            if (r.err) |e| {
                std.debug.print("neovim error: {s}\n", .{e});
            } else if (r.id == self.nvim.channel_req) {
                const size = windowSize(self.panes.byId(startup_pane_id).?);
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

/// Neovim's current window changed: focus its pane in Rex.
fn onCurrent(self: *Daemon, win: i64) !void {
    // sent before our own change ran; the report after it is coming
    if (self.nvim.current_win_req != null) return;
    self.nvim.current_win = win;
    const p = self.panes.byWin(win) orelse return;
    try self.nvim.fitUiTo(p);
    try self.draw();
    try self.rex.focus(p.rex_block);
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
        if (self.changes.takeReopening(win)) {
            p.neovim_window_handle = null;
            continue;
        }
        p.closing = .window_closed;
        self.panes.remove(self.gpa, self.io, i);
    }
    if (self.panes.list.items.len == 0) {
        self.stop(.pane_gone);
        return;
    }
    self.changes.forgetGone(&self.grids);

    for (self.grids.wins.values()) |w| switch (w.kind) {
        .ordinary => {
            if (!try self.changes.shouldAdopt(self.gpa, w.win)) continue;
            const size = if (self.panes.byWin(w.win)) |p| windowSize(p) else self.newWindowSize(w.win);
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
    try self.nvim.client.flush();
}

/// A pane kept for a reopened window.
fn waitingPane(self: *const Daemon) ?*Pane {
    for (self.panes.list.items) |*p| if (p.neovim_window_handle == null and p.terminal_surface != null) return p;
    return null;
}

/// A guess until the new pane says its size: half the pane it splits.
fn newWindowSize(self: *const Daemon, win: i64) [2]u32 {
    const sp = self.changes.splitOf(win);
    const p = self.splitFrom(sp) orelse return .{ 80, 24 };
    const s = windowSize(p);
    if (sp.side_by_side) return .{ @max(s[0] / 2, 1), s[1] };
    return .{ s[0], @max(s[1] / 2, 1) };
}

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
        .split_failed => |failed| if (self.panes.byId(failed.pane)) |p| {
            p.closing = .request_failed;
        },
        .focus_moved => |block| try self.onRexFocus(block),
    };
}

/// Rex made the pane's split: link the block and let Rex size it.
fn onSplitMade(self: *Daemon, pane_id: u32, block: []const u8) !void {
    const p = self.panes.byId(pane_id) orelse return;
    p.rex_block = Pane.rexBlock(block) catch blk: {
        std.debug.print("neorex daemon: not a block id: {s}\n", .{block});
        break :blk null;
    };
    try self.rex.disown(block);
    if (p.neovim_window_handle == self.nvim.current_win) try self.rex.focus(p.rex_block);
}

/// The user focused one of our panes in Rex: make its window current.
fn onRexFocus(self: *Daemon, block: []const u8) !void {
    const p = self.panes.byBlock(block) orelse return;
    const win = p.neovim_window_handle orelse return;
    if (win == self.nvim.current_win) return;
    try self.makeCurrent(p);
    try self.nvim.client.flush();
    try self.draw();
}

// shared

/// Draws every pane that changed.
fn draw(self: *Daemon) !void {
    const focused = self.focusedPane();
    var i = self.panes.list.items.len;
    while (i > 0) {
        i -= 1;
        // backwards, so removing this pane leaves the ones still to draw in place
        const p = &self.panes.list.items[i];
        const s = p.terminal_surface orelse continue;
        const grid = self.gridOfPane(p);
        const drawn = s.view.frame(&self.grids, grid, p == focused, &s.terminal.writer) catch false;
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

/// Asks Neovim for the window to fit the pane, unless it already was.
fn sizeWindow(self: *Daemon, p: *Pane) !void {
    const s = p.terminal_surface orelse return;
    const win = p.neovim_window_handle orelse return;
    const grid = self.grids.gridOf(win) orelse return;
    const size = s.windowSize();
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

/// No terminal yet: the smallest window, as Neovim allows.
fn windowSize(p: *const Pane) [2]u32 {
    return if (p.terminal_surface) |s| s.windowSize() else .{ 1, 1 };
}
