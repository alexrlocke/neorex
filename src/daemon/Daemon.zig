//! The running daemon: Neovim, its grids, the Rex connection, a pane per
//! window and a floating pane per group of large floats. After each Neovim
//! flush, `reconcile` gives new windows and float groups panes and hangs up
//! panes whose windows closed; then every pane is drawn.
// TODO: Needs a pretty major rewrite

const std = @import("std");
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const input = @import("../term/input.zig");
const Nvim = @import("../nvim/Nvim.zig");
const msgpack = @import("../nvim/msgpack.zig");
const rpc = @import("../nvim/rpc.zig");
const windows = @import("../nvim/windows.zig");
const Forwarder = @import("../nvim/Forwarder.zig");
const Grids = @import("../screen/Grids.zig");
const FloatGroups = @import("../screen/FloatGroups.zig");
const PaneView = @import("../screen/PaneView.zig");
const Client = @import("../rex/Client.zig");
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
pub const Token = enum(usize) { signal, nvim_socket, helper_listener, rex_socket, focus_timer, layout_timer, _ };
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

/// A new Rex terminal's size, cols x rows, until the app lays it out.
const rex_default_size = [2]u32{ 80, 24 };

/// About how many cells a Rex floating pane's frame takes, across and down.
/// Only a first guess: once made, its floats fit whatever size it is.
const layer_frame = [2]i32{ 3, 2 };

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
        .helper_listener => {},
        _ => try self.onPane(e.token),
    }
}

/// After each batch of events: tells Neovim whether any pane has focus.
/// Losing it waits a moment, in case another pane gains it.
fn afterBatch(self: *Daemon) !void {
    try self.sendFocus(false);
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
        if (v.cols != rex_default_size[0] or v.rows != rex_default_size[1]) {
            pane.awaiting_layout = false;
        } else try self.addTimer(.layout_timer, layout_wait_ms);
    }
    try self.sizeWindow(pane);
    if (pane.layer) |*l| if (try self.followLayer(pane)) |req| {
        l.fit = .{ .asked = req };
    };
    try self.nvim.client.flush();
    try self.draw();
}

/// The app never resized a new split: its terminal's size is the real one.
fn layoutWaitOver(self: *Daemon) !void {
    var any = false;
    for (self.panes.list.items) |*p| if (p.awaiting_layout and p.terminal_surface != null) {
        p.awaiting_layout = false;
        any = true;
        try self.sizeWindow(p);
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
    _ = try self.followLayer(pane);
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
        for (self.panes.list.items) |q| if (q.layer == null) if (q.rex_block) |b| break :blk b;
        return; // no anchor yet: next flush
    };
    // starts at the guess, not Rex's default
    const size = self.newPaneSize(win);
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
        self.panes.remove(self.gpa, self.io, i);
        for (l.group.topGrids()) |top| if (self.grids.winOn(top)) |w| try windows.close(self.nvim.client, w.win);
        try self.nvim.client.flush();
        return;
    }
    var others = false;
    for (self.panes.list.items) |q| {
        if (q.id != p.id and q.closing != .request_failed and q.layer == null) others = true;
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
                .float => |win| try self.onCurrentFloat(win),
                .reopen => |win| if (self.panes.byWin(win) != null) try self.changes.markReopening(self.gpa, win),
                .split => |sp| if (self.panes.byWin(sp.win) == null) try self.changes.noteSplit(self.gpa, sp),
            };
        },
        .request => |r| try self.nvim.client.respondError(r.id, "neorex serves no requests"),
        .response => |r| {
            var result = r.result;
            if (r.id == self.nvim.current_win_req) self.nvim.current_win_req = null;
            var show_now = false;
            for (self.panes.list.items) |*p| if (p.layer) |*l| if (l.fit == .asked and l.fit.asked == r.id) {
                // nothing moved, so no redraw is coming: show it now
                var res = r.result;
                const moved = r.err == null and (rpc.expectBool(&res) catch false);
                l.fit = if (moved) .answered else .none;
                show_now = !moved;
            };
            if (show_now) try self.draw();
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

/// Matches panes to windows: new external windows get panes, ordinary ones
/// are made external, and panes whose windows closed hang up.
fn reconcile(self: *Daemon) !void {
    if (!self.nvim.ready) return;
    // this flush has the refitted floats
    for (self.panes.list.items) |*p| if (p.layer) |*l| if (l.fit == .answered) {
        l.fit = .none;
    };
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
        // hanging up closes the Rex pane only once its helper has connected
        if (p.terminal_surface == null) if (p.rex_block) |*b| try self.rex.closeBlock(b);
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
    try self.reconcileLayers();
    try self.nvim.client.flush();
}

/// A pane kept for a reopened window.
fn waitingPane(self: *const Daemon) ?*Pane {
    for (self.panes.list.items) |*p| if (p.layer == null and p.neovim_window_handle == null and p.terminal_surface != null) return p;
    return null;
}

/// A guess until the new pane says its size: half the pane it splits.
fn newWindowSize(self: *const Daemon, win: i64) [2]u32 {
    const size = self.newPaneSize(win);
    return .{ size[0], @max(size[1] -| 1, 1) };
}

/// A guess at a new split's terminal size, cols x rows: half the pane it splits.
fn newPaneSize(self: *const Daemon, win: i64) [2]u32 {
    const sp = self.changes.splitOf(win);
    const p = self.splitFrom(sp) orelse return rex_default_size;
    const s = p.terminal_surface orelse return rex_default_size;
    const cols = @max(s.view.cols, 1);
    const rows = @max(s.view.rows, 2);
    if (sp.side_by_side) return .{ @max(cols / 2, 1), rows };
    return .{ cols, @max(rows / 2, 2) };
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
        // a floating pane that failed leaves its floats drawn in the pane
        .split_failed, .layer_failed => |failed| if (self.panes.byId(failed.pane)) |p| {
            p.closing = .request_failed;
        },
        .layer_made => |made| try self.onLayerMade(made.pane, made.block, made.layer),
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
    self.readLayout(wins);
    if (self.focusedPane()) |f| try self.nvim.fitUiTo(f);
    try self.nvim.client.flush();
    try self.draw();
}

/// Remembers which Rex window holds our panes, and where each sits in it.
fn readLayout(self: *Daemon, wins: []const std.json.Value) void {
    for (wins) |w| {
        const layers = Client.get(w, "layers") orelse continue;
        if (layers != .array) continue;
        var found = false;
        for (layers.array.items) |layer| {
            if (!std.mem.eql(u8, Client.getStr(layer, "kind") orelse "", "tiled")) {
                self.readLayerBounds(layer);
                continue;
            }
            if (Client.get(layer, "layout")) |l| found = self.readRects(l) or found;
        }
        if (!found) continue;
        const id = Client.getStr(w, "window_id") orelse continue;
        if (id.len == 43) self.rex.window = id[0..43].*;
    }
}

/// A floating layer of ours somewhere else: the user moved it, so its
/// floats follow.
fn readLayerBounds(self: *Daemon, layer: std.json.Value) void {
    const bounds = rect4(Client.get(layer, "bounds")) orelse return;
    const blocks = Client.get(layer, "blocks") orelse return;
    if (blocks != .array or blocks.array.items.len == 0) return;
    const p = self.panes.byBlock(Client.getStr(blocks.array.items[0], "block_id") orelse return) orelse return;
    const l = if (p.layer) |*l| l else return;
    if (self.sameBounds(bounds, l.bounds)) return;
    l.bounds = bounds;
    _ = self.followLayer(p) catch {};
}

/// Finds our panes' blocks under layout node `node` and keeps their rects.
fn readRects(self: *Daemon, node: std.json.Value) bool {
    var found = false;
    switch (node) {
        .object => |o| {
            if (Client.str(o.get("block_id"))) |b| if (self.panes.byBlock(b)) |p| if (rect4(o.get("rect"))) |r| {
                p.rect = r;
                found = true;
            };
            var it = o.iterator();
            while (it.next()) |e| found = self.readRects(e.value_ptr.*) or found;
        },
        .array => |a| for (a.items) |x| {
            found = self.readRects(x) or found;
        },
        else => {},
    }
    return found;
}

/// `[x, y, w, h]` as fractions.
fn rect4(v: ?std.json.Value) ?[4]f64 {
    const a = v orelse return null;
    if (a != .array or a.array.items.len != 4) return null;
    var out: [4]f64 = undefined;
    for (a.array.items, &out) |x, *o| o.* = switch (x) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => return null,
    };
    return out;
}

// floating panes

/// Matches floating panes to groups of floats: new groups get one, and
/// those whose group closed hang up. A floating pane's size is Rex's: it's
/// never moved to follow its floats, they follow it.
fn reconcileLayers(self: *Daemon) !void {
    var buf: [FloatGroups.max_groups]FloatGroups.Group = undefined;
    const groups = if (self.rex.conn != .closed) FloatGroups.find(&self.grids, &buf) else buf[0..0];
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
            self.panes.remove(self.gpa, self.io, i);
            continue;
        };
        l.group = g.*;
    }
    for (groups) |g| {
        if (self.panes.byLayerKey(g.key) == null) try self.newLayer(g);
    }
}

/// Bounds for a floating pane around `g`, as fractions of the window,
/// leaving room for the frame Rex draws around it.
fn layerBounds(self: *const Daemon, g: FloatGroups.Group) ?[4]f64 {
    const screen = self.grids.get(1) orelse return null;
    if (screen.width == 0 or screen.height == 0) return null;
    const sw: f64 = @floatFromInt(screen.width);
    const sh: f64 = @floatFromInt(screen.height);
    const fw = layer_frame[0];
    const fh = layer_frame[1];
    const w = @min(@as(f64, @floatFromInt(@as(i64, g.width) + fw)) / sw, 1);
    const h = @min(@as(f64, @floatFromInt(@as(i64, g.height) + fh)) / sh, 1);
    const x = std.math.clamp(@as(f64, @floatFromInt(g.col - @divFloor(fw, 2))) / sw, 0, 1 - w);
    const y = std.math.clamp(@as(f64, @floatFromInt(g.row - @divFloor(fh, 2))) / sh, 0, 1 - h);
    return .{ x, y, w, h };
}

fn newLayer(self: *Daemon, g: FloatGroups.Group) !void {
    const bounds = self.layerBounds(g) orelse return;
    const pane = try self.panes.addForGroup(self.gpa, g);
    pane.layer.?.bounds = bounds;
    const pane_id = pane.id;

    var id_buf: [16]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{pane_id});
    try self.rex.newLayer(pane_id, bounds, .{ .block = .{
        .flavor = "com.superlogical.terminal.shell",
        .label = "neorex",
        .options = .{ .shell = "none", .command = &[_][]const u8{ self.exe, "pane", self.sock, id } },
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
    const row: i32 = @as(i32, @intFromFloat(@round(l.bounds[1] * @as(f64, @floatFromInt(screen.height))))) + @divFloor(layer_frame[1], 2);
    const col: i32 = @as(i32, @intFromFloat(@round(l.bounds[0] * @as(f64, @floatFromInt(screen.width))))) + @divFloor(layer_frame[0], 2);
    const g = l.group;
    if (row == g.row and col == g.col and s.view.cols == g.width and s.view.rows == g.height) return null;
    var wins: [16]i64 = undefined;
    var n: usize = 0;
    for (g.topGrids()) |top| if (self.grids.winOn(top)) |w| {
        wins[n] = w.win;
        n += 1;
    };
    if (n == 0) return null;
    return try windows.placeGroup(self.nvim.client, wins[0..n], row, col, s.view.cols, s.view.rows, .{ g.row, g.col, g.width, g.height });
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
        // a floating pane waiting on its refit shows nothing yet
        if (p.layer != null and !p.layerShown()) continue;
        const drawn = if (p.layer) |*l| blk: {
            var mbuf: [Grids.max_floats]Grids.Placed = undefined;
            const members = FloatGroups.members(&self.grids, &l.group, &mbuf);
            s.forwarder.grid = if (members.len > 0) members[0].grid else 1;
            break :blk s.view.frameFloats(&self.grids, members, .{ l.group.row, l.group.col }, &s.terminal.writer) catch false;
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
