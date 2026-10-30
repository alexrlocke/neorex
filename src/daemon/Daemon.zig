//! The running daemon: Neovim, its grids, the Rex connection, and a pane
//! per window. After each Neovim flush, `reconcile` gives new windows panes
//! and hangs up panes whose windows closed; then every pane is drawn.
// TODO: Needs a pretty major rewrite

const std = @import("std");
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const input = @import("../term/input.zig");
const Nvim = @import("../nvim/Nvim.zig");
const msgpack = @import("../nvim/msgpack.zig");
const windows = @import("../nvim/windows.zig");
const Grids = @import("../screen/Grids.zig");
const Client = @import("../rex/Client.zig");
const Loop = @import("Loop.zig");
const Pane = @import("Pane.zig");
const Panes = @import("Panes.zig");
const Surface = @import("Surface.zig");
const fdpass = @import("fdpass.zig");
const pane_helper = @import("pane_helper.zig");

const Daemon = @This();

allocator: Allocator,
io: std.Io,
loop: *Loop,
nvim: *Nvim,
rex: *Client,
session_id: []const u8,
/// Our executable and the helpers' socket, for new panes' command.
exe: []const u8,
sock: []const u8,
grids: Grids = .{},
panes: Panes = .{},
/// Neovim's current window, as the Lua last said; 0 before setup.
current: i64 = 0,
/// A `nvim_set_current_win` of ours not answered yet. Reports sent before
/// it ran are stale.
current_req: ?u32 = null,
chan_req: u32 = 0,
setup_req: u32 = 0,
/// Setup answered: windows can be adopted and given panes.
ready: bool = false,
/// Windows asked to become external and not seen external since.
asked: std.AutoArrayHashMapUnmanaged(i64, void) = .empty,
/// Windows we asked Neovim to close because their pane went away.
closing: std.AutoArrayHashMapUnmanaged(i64, void) = .empty,
/// Windows closing to reopen (`:close` on the last one): their panes wait
/// for the new window instead of hanging up.
reopening: std.AutoArrayHashMapUnmanaged(i64, void) = .empty,
/// New windows without panes yet, and where Neovim put them.
splits: std.AutoArrayHashMapUnmanaged(i64, windows.Split) = .empty,
/// Rex requests waiting for an answer.
rex_reqs: std.ArrayList(RexReq) = .empty,
/// False once Rex hangs up: windows keep working, but no new panes or focus.
rex_open: bool = true,
/// The block Rex has focused, as we last saw or asked; owned.
rex_focused: ?[]u8 = null,
/// The newest session view we've read, and whether one is on its way.
view_rev: i64 = -1,
view_req: bool = false,
view_again: bool = false,
/// Focus requests in flight; views older than the last one's answer are stale.
focus_reqs: u32 = 0,
focus_rev: i64 = 0,
/// Whether some pane's terminal has focus, as Neovim was last told.
ui_focused: bool = true,
/// Set by `stop`; `run` returns it.
stopped: ?StopReason = null,

pub const StopReason = enum { nvim_exited, pane_gone, signal };

/// What a loop event's token names; pane tokens fall in `_`.
pub const Token = enum(usize) { signal, nvim_socket, helper_listener, rex_socket, _ };

comptime {
    // the fixed tokens must stay below the pane tokens
    for (@typeInfo(Token).@"enum".field_values) |v| std.debug.assert(v < Pane.token_base);
}

/// The id `Pane.startup` gives the pane neorex was run in.
const startup_pane_id = 0;

const RexReq = struct {
    id: u64,
    kind: enum { split, focus, view, other },
    pane: u32 = 0,
};

pub fn deinit(self: *Daemon) void {
    self.panes.deinit(self.gpa, self.io);
    self.grids.deinit(self.gpa);
    self.asked.deinit(self.gpa);
    self.closing.deinit(self.gpa);
    self.reopening.deinit(self.gpa);
    self.splits.deinit(self.gpa);
    self.rex_reqs.deinit(self.gpa);
    if (self.rex_focused) |b| self.gpa.free(b);
    self.* = undefined;
}

/// Adds the launcher's pane, already connected, and starts talking to
/// Neovim and Rex.
pub fn start(self: *Daemon, launch_pane: Pane) !void {
    // only ever called on startup
    std.debug.assert(self.panes.list.items.len == 0);

    const pane = try self.panes.add(self.allocator, launch_pane);

    try pane.registerWith(self.loop);
    const view = pane.terminal_surface.?.view;
    try self.attachNvimUi(view.cols, view.rows);
    try self.joinRexSession();
}

/// Attaches as Neovim's UI at `cols` x `rows` and asks for our channel.
fn attachNvimUi(self: *Daemon, cols: u32, rows: u32) !void {
    try self.nvim.uiAttach(cols, rows, .{ .ext_termcolors = true, .ext_multigrid = true });
    self.chan_req = try windows.askChannel(self.nvim);
    try self.nvim.flush();
}

/// Attaches to our Rex session, so we hear its events and can split it.
fn joinRexSession(self: *Daemon) !void {
    try self.rexRequest(.other, 0, "session.attach", .{ .session_id = self.session_id });
}

/// Runs the loop until something calls `stop`, returns why.
pub fn run(self: *Daemon, server: *net.Server) !StopReason {
    var events: [16]Loop.Event = undefined;
    while (self.stopped == null) {
        var helper_waiting = false;
        for (try self.loop.wait(&events)) |e| {
            if (e.token == @backingInt(Token.helper_listener)) helper_waiting = true;
            try self.handle(e);
            if (self.stopped != null) break;
        }
        // between batches, so no stale event reaches a new pane
        if (helper_waiting and self.stopped == null) self.accept(server) catch |err| std.debug.print("neorex daemon: a pane failed: {t}\n", .{err});
        if (self.stopped == null) try self.afterBatch();
    }
    return self.stopped.?;
}

/// Ends `run` once the current event is handled.
fn stop(self: *Daemon, reason: StopReason) void {
    self.stopped = reason;
}

/// Handles one loop event.
fn handle(self: *Daemon, e: Loop.Event) !void {
    switch (@as(Token, @fromBackingInt(@intCast(e.token)))) {
        .signal => self.stop(.signal),
        .nvim_socket => try self.onNvim(),
        .rex_socket => try self.onRex(),
        .helper_listener => {},
        _ => try self.onPane(e.token),
    }
}

fn onPane(self: *Daemon, pane_token: usize) !void {
    const t = Pane.fromToken(pane_token);
    // gone already if closed earlier in this batch
    const p = self.panes.byId(t.id) orelse return;
    switch (t.source_fd) {
        .helper_socket => try self.onHelper(p),
        .terminal => try self.onInput(p),
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
    if (!known or any == self.ui_focused) return;
    self.ui_focused = any;
    _ = try self.nvim.request("nvim_ui_set_focus", 1);
    try msgpack.writeBool(self.nvim.writer(), any);
    try self.nvim.flush();
}

/// A new helper connected: match its hello to a pane waiting for it.
fn accept(self: *Daemon, server: *net.Server) !void {
    const stream = try server.accept(self.io);
    var buf: [16]u8 = undefined;
    const r = fdpass.recv(stream, self.io, &buf) catch {
        stream.close(self.io);
        return;
    };
    const tty = r.fd orelse {
        stream.close(self.io);
        return;
    };
    const id = pane_helper.parseHello(buf[0..r.len]) catch null;
    const p = if (id) |i| self.panes.byId(i) else null;
    if (p == null or p.?.terminal_surface != null) {
        std.debug.print("neorex daemon: a helper nobody asked for\n", .{});
        _ = std.c.close(tty);
        stream.close(self.io);
        return;
    }
    const pane = p.?;
    pane.terminal_surface = Surface.create(self.gpa, stream, tty) catch |err| {
        _ = std.c.close(tty);
        stream.close(self.io);
        return err;
    };
    try pane.registerWith(self.loop);
    try self.sizeWindow(pane);
    try self.nvim.flush();
    try self.draw();
}

/// No terminal yet: the smallest window, as Neovim allows.
fn windowSize(p: *const Pane) [2]u32 {
    return if (p.terminal_surface) |s| s.windowSize() else .{ 1, 1 };
}

/// The pane showing Neovim's current window; before setup, the launcher's.
fn focusedPane(self: *const Daemon) ?*Pane {
    if (self.current == 0) return self.panes.byId(startup_pane_id);
    return self.panes.byWin(self.current);
}

// Neovim

fn onNvim(self: *Daemon) !void {
    if (!try self.nvim.read(self.gpa)) return self.stop(.nvim_exited);
    while (try self.nvim.next()) |msg| switch (msg) {
        .notification => |n| {
            var params = n.params;
            if (std.mem.eql(u8, n.method, "redraw")) {
                if (try self.grids.applyRedraw(self.gpa, &params)) {
                    try self.reconcile();
                    try self.draw();
                }
            } else if (try windows.parseNote(n.method, &params)) |note| switch (note) {
                .current => |win| try self.onCurrent(win),
                .reopen => |win| if (self.panes.byWin(win) != null) try self.reopening.put(self.gpa, win, {}),
                .split => |sp| if (self.panes.byWin(sp.win) == null) try self.splits.put(self.gpa, sp.win, sp),
            };
        },
        .request => |r| try self.nvim.respondError(r.id, "neorex serves no requests"),
        .response => |r| {
            var result = r.result;
            if (r.id == self.current_req) self.current_req = null;
            if (r.err) |e| {
                std.debug.print("neovim error: {s}\n", .{e});
            } else if (r.id == self.chan_req) {
                const size = windowSize(self.panes.byId(startup_pane_id).?);
                self.setup_req = try windows.setup(self.nvim, try windows.parseChannel(&result), size[0], size[1]);
                try self.nvim.flush();
            } else if (r.id == self.setup_req) {
                const wins = try windows.parseSetup(&result);
                if (self.panes.byId(startup_pane_id)) |launch| launch.neovim_window_handle = wins[0];
                self.ready = true;
                try self.reconcile();
                try self.draw();
            }
        },
    };
}

/// Neovim's current window changed: focus its pane in Rex.
fn onCurrent(self: *Daemon, win: i64) !void {
    // sent before our own change ran; the report after it is coming
    if (self.current_req != null) return;
    self.current = win;
    const p = self.panes.byWin(win) orelse return;
    try self.followFocus(p);
    try self.draw();
    try self.focusInRex(p);
}

/// The editor's size follows the focused pane, so messages fit it.
fn followFocus(self: *Daemon, p: *Pane) !void {
    const s = p.terminal_surface orelse return;
    try self.nvim.uiTryResize(s.view.cols, s.view.rows);
}

fn focusInRex(self: *Daemon, p: *Pane) !void {
    const block: []const u8 = if (p.rex_block) |*b| b else return;
    if (self.rex_focused) |f| if (std.mem.eql(u8, f, block)) return;
    try self.setRexFocused(block);
    self.focus_reqs += 1;
    try self.rexRequest(.focus, 0, "session.focus_block", .{ .session_id = self.session_id, .block_id = block });
}

fn setRexFocused(self: *Daemon, block: []const u8) !void {
    const copy = try self.gpa.dupe(u8, block);
    if (self.rex_focused) |f| self.gpa.free(f);
    self.rex_focused = copy;
}

/// Matches panes to windows: new external windows get panes, ordinary ones
/// are made external, and panes whose windows closed hang up.
fn reconcile(self: *Daemon) !void {
    if (!self.ready) return;
    var i = self.panes.list.items.len;
    while (i > 0) {
        i -= 1;
        const p = &self.panes.list.items[i];
        const win = p.neovim_window_handle orelse continue;
        if (self.grids.gridOf(win) != null) continue;
        if (self.reopening.swapRemove(win)) {
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
    // forget windows that are gone
    for ([_]*std.AutoArrayHashMapUnmanaged(i64, void){ &self.asked, &self.closing, &self.reopening }) |set| {
        var j = set.count();
        while (j > 0) {
            j -= 1;
            if (self.grids.gridOf(set.keys()[j]) == null) set.swapRemoveAt(j);
        }
    }
    var j = self.splits.count();
    while (j > 0) {
        j -= 1;
        if (self.grids.gridOf(self.splits.keys()[j]) == null) self.splits.swapRemoveAt(j);
    }

    for (self.grids.wins.values()) |w| switch (w.kind) {
        .ordinary => {
            if (self.asked.contains(w.win)) continue;
            try self.asked.put(self.gpa, w.win, {});
            const size = if (self.panes.byWin(w.win)) |p| windowSize(p) else self.newWindowSize(w.win);
            try windows.adopt(self.nvim, w.win, size[0], size[1]);
        },
        .external => {
            _ = self.asked.swapRemove(w.win);
            if (self.panes.byWin(w.win) != null or self.closing.contains(w.win)) continue;
            if (self.waitingPane()) |p| {
                p.neovim_window_handle = w.win;
            } else {
                try self.newPane(w.win);
            }
        },
        .float, .hidden => {},
    };
    for (self.panes.list.items) |*p| try self.sizeWindow(p);
    try self.nvim.flush();
}

/// A pane kept for a reopened window.
fn waitingPane(self: *const Daemon) ?*Pane {
    for (self.panes.list.items) |*p| if (p.neovim_window_handle == null and p.terminal_surface != null) return p;
    return null;
}

/// A guess until the new pane says its size: half the pane it splits.
fn newWindowSize(self: *const Daemon, win: i64) [2]u32 {
    const sp = self.splitOf(win);
    const p = self.splitFrom(sp) orelse return .{ 80, 24 };
    const s = windowSize(p);
    if (sp.side_by_side) return .{ @max(s[0] / 2, 1), s[1] };
    return .{ s[0], @max(s[1] / 2, 1) };
}

/// Where Neovim put `win`; beside the current window if it didn't say.
fn splitOf(self: *const Daemon, win: i64) windows.Split {
    return self.splits.get(win) orelse .{ .win = win, .side_by_side = true, .before = false, .from = 0 };
}

/// The pane a new window splits: its origin's, else the focused one.
fn splitFrom(self: *const Daemon, sp: windows.Split) ?*Pane {
    if (sp.from != 0) if (self.panes.byWin(sp.from)) |p| return p;
    return self.focusedPane();
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
    try windows.size(self.nvim, win, size[0], size[1]);
}

/// Draws every pane that changed.
fn draw(self: *Daemon) !void {
    const focused = self.focusedPane();
    var i = self.panes.list.items.len;
    while (i > 0) {
        i -= 1;
        // backwards, so removing this pane leaves the ones still to draw in place
        const p = &self.panes.list.items[i];
        const s = p.terminal_surface orelse continue;
        const grid = if (p.neovim_window_handle) |win| self.grids.gridOf(win) else null;
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

// panes

fn newPane(self: *Daemon, win: i64) !void {
    const sp = self.splitOf(win);
    // beside the window it came from, else any pane Rex knows
    // a copy: appending below can move every pane
    const anchor: Pane.RexBlock = blk: {
        if (self.splitFrom(sp)) |f| if (f.rex_block) |b| break :blk b;
        for (self.panes.list.items) |q| if (q.rex_block) |b| break :blk b;
        return; // no anchor yet: next flush
    };
    const pane_id = (try self.panes.addForWindow(self.gpa, win)).id;
    _ = self.splits.swapRemove(win);

    var id_buf: [16]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{pane_id});
    try self.rexRequest(.split, pane_id, "session.new_split", .{
        .session_id = self.session_id,
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
    try self.closing.put(self.gpa, win, {});
    try windows.close(self.nvim, win);
    try self.nvim.flush();
}

fn onHelper(self: *Daemon, p: *Pane) !void {
    const s = p.terminal_surface.?;
    var buf: [64]u8 = undefined;
    const r = fdpass.recv(s.helper_socket, self.io, &buf) catch return self.paneGone(p);
    if (r.fd) |fd| _ = std.c.close(fd);
    if (r.len == 0) return self.paneGone(p);
    // once, however many: the size is read fresh, and drawing can move `p`
    const resized = for (buf[0..r.len]) |b| {
        if (@as(pane_helper.Message, @fromBackingInt(@intCast(b))) == .resized) break true;
    } else false;
    if (!resized) return;
    const ws = s.terminal.size() catch return self.paneGone(p);
    s.view.resize(ws.col, ws.row);
    try self.sizeWindow(p);
    if (p == self.focusedPane()) try self.followFocus(p);
    try self.nvim.flush();
    try self.draw();
}

fn onInput(self: *Daemon, p: *Pane) !void {
    var buf: [4096]u8 = undefined;
    const s = p.terminal_surface.?;
    const n = std.c.read(s.terminal.fd, &buf, buf.len);
    if (n <= 0) return self.paneGone(p);
    const bytes = buf[0..@intCast(n)];
    // typed in a pane Rex hasn't focused, as `rex send` can: that window first.
    // Not focus reports: Rex sends them as it moves focus away.
    if (p.neovim_window_handle) |win| if (win != self.current and !self.rexFocuses(p) and !input.onlyFocusReports(bytes)) {
        self.current = win;
        self.current_req = try windows.setCurrent(self.nvim, win);
        try self.followFocus(p);
        try self.focusInRex(p);
    };
    s.forwarder.grid = if (p.neovim_window_handle) |win| self.grids.gridOf(win) orelse 0 else 0;
    _ = try s.forwarder.feed(self.nvim, bytes);
}

fn rexFocuses(self: *const Daemon, p: *const Pane) bool {
    const f = self.rex_focused orelse return false;
    const b = if (p.rex_block) |*b| b else return false;
    return std.mem.eql(u8, f, b);
}

// Rex

fn rexRequest(self: *Daemon, kind: @FieldType(RexReq, "kind"), pane: u32, method: []const u8, payload: anytype) !void {
    if (!self.rex_open) return;
    const id = try self.rex.request(self.gpa, method, payload);
    try self.rex_reqs.append(self.gpa, .{ .id = id, .kind = kind, .pane = pane });
}

fn onRex(self: *Daemon) !void {
    if (!try self.rex.read(self.gpa)) {
        std.debug.print("neorex daemon: Rex hung up\n", .{});
        self.rex_open = false;
        try self.loop.remove(self.rex.fd());
        return;
    }
    while (try self.rex.next(self.gpa)) |m| switch (m) {
        .response => |r| try self.onRexResponse(r),
        .event => |ev| if (std.mem.eql(u8, ev.name, "session_view_changed")) {
            const rev = Client.int(Client.get(ev.payload, "revision")) orelse continue;
            if (rev <= self.view_rev) continue;
            if (self.view_req) {
                self.view_again = true;
            } else {
                try self.askView();
            }
        },
        .closed => |c| {
            std.debug.print("neorex daemon: Rex closed {?d} {s}\n", .{ c.code, c.reason });
            self.rex_open = false;
        },
    };
}

fn askView(self: *Daemon) !void {
    self.view_req = true;
    self.view_again = false;
    try self.rexRequest(.view, 0, "session.view", .{ .session_id = self.session_id });
}

fn onRexResponse(self: *Daemon, r: Client.Response) !void {
    const i = for (self.rex_reqs.items, 0..) |q, i| {
        if (q.id == r.id) break i;
    } else return;
    const req = self.rex_reqs.swapRemove(i);
    switch (req.kind) {
        .focus => {
            self.focus_reqs -|= 1;
            if (r.result == .ok) self.focus_rev = @max(self.focus_rev, Client.int(Client.get(r.result.ok, "revision")) orelse 0);
        },
        .view => {
            self.view_req = false;
            if (r.result == .ok) try self.onView(r.result.ok);
            if (self.view_again) try self.askView();
        },
        else => {},
    }
    const ok = switch (r.result) {
        .ok => |v| v,
        .err => |e| {
            std.debug.print("neorex daemon: Rex request failed: {s}: {s}\n", .{ e.code, e.message });
            if (req.kind == .split) if (self.panes.byId(req.pane)) |p| {
                p.closing = .request_failed;
            };
            return;
        },
    };
    if (req.kind != .split) return;
    const p = self.panes.byId(req.pane) orelse return;
    const ids = Client.get(ok, "block_ids") orelse return;
    if (ids != .array or ids.array.items.len == 0) return;
    const block = Client.str(ids.array.items[0]) orelse return;
    p.rex_block = Pane.rexBlock(block) catch blk: {
        std.debug.print("neorex daemon: not a block id: {s}\n", .{block});
        break :blk null;
    };
    // the creator owns the block and sizes it; let the app size it instead
    try self.rexRequest(.other, 0, "session.disown_block", .{ .session_id = self.session_id, .block_ids = &[_][]const u8{block} });
    if (p.neovim_window_handle == self.current) try self.focusInRex(p);
}

/// A session view: if Rex focused one of our panes, make its window current.
fn onView(self: *Daemon, v: Value) !void {
    const rev = Client.int(Client.get(v, "revision")) orelse return;
    if (rev <= self.view_rev) return;
    self.view_rev = rev;
    // from before our own focus change landed
    if (self.focus_reqs > 0 or rev < self.focus_rev) return;
    const active = Client.str(Client.get(v, "active_window_id")) orelse return;
    const wins = Client.get(v, "windows") orelse return;
    if (wins != .array) return;
    const block = for (wins.array.items) |w| {
        if (std.mem.eql(u8, Client.str(Client.get(w, "window_id")) orelse "", active)) break Client.str(Client.get(w, "focused_block_id")) orelse return;
    } else return;
    // unchanged: any difference is Neovim's move, which focus_block follows
    const known = self.rex_focused;
    if (known) |f| if (std.mem.eql(u8, f, block)) return;
    try self.setRexFocused(block);
    if (known == null) return;
    const p = self.panes.byBlock(block) orelse return;
    const win = p.neovim_window_handle orelse return;
    if (win == self.current) return;
    self.current = win;
    self.current_req = try windows.setCurrent(self.nvim, win);
    try self.followFocus(p);
    try self.nvim.flush();
    try self.draw();
}
