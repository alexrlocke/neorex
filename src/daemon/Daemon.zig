//! The running daemon: Neovim, its grids, the Rex connection, and a pane
//! per window. After each Neovim flush, `reconcile` gives new windows panes
//! and hangs up panes whose windows closed; then every pane is drawn.

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
const Pane = @import("RexPane.zig");
const fdpass = @import("fdpass.zig");
const pane_helper = @import("pane.zig");

const Daemon = @This();

gpa: Allocator,
io: std.Io,
loop: *Loop,
nvim: *Nvim,
rex: *Client,
session_id: []const u8,
/// Our executable and the helpers' socket, for new panes' command.
exe: []const u8,
sock: []const u8,
grids: Grids = .{},
panes: std.ArrayList(*Pane) = .empty,
next_pane_id: u32 = 1,
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
end: ?End = null,

pub const End = enum { nvim_exited, pane_gone, signal };

pub const token_signal = 0;
pub const token_nvim = 1;
pub const token_listener = 2;
pub const token_rex = 3;

const RexReq = struct {
    id: u64,
    kind: enum { split, focus, view, other },
    pane: u32 = 0,
};

pub fn deinit(self: *Daemon) void {
    for (self.panes.items) |p| {
        p.deinit(self.gpa, self.io);
        self.gpa.destroy(p);
    }
    self.panes.deinit(self.gpa);
    self.grids.deinit(self.gpa);
    self.asked.deinit(self.gpa);
    self.closing.deinit(self.gpa);
    self.splits.deinit(self.gpa);
    self.rex_reqs.deinit(self.gpa);
    if (self.rex_focused) |b| self.gpa.free(b);
    self.* = undefined;
}

/// Adds the launcher's pane, already connected, and starts talking to
/// Neovim and Rex.
pub fn start(self: *Daemon, launch: *Pane) !void {
    try self.panes.append(self.gpa, launch);
    try self.watch(launch);
    const ws = launch.view;
    try self.nvim.uiAttach(ws.cols, ws.rows, .{ .ext_termcolors = true, .ext_multigrid = true });
    self.chan_req = try windows.askChannel(self.nvim);
    try self.nvim.flush();
    try self.rexRequest(.other, 0, "session.attach", .{ .session_id = self.session_id });
}

/// Handles one loop event.
pub fn handle(self: *Daemon, e: Loop.Event) !void {
    switch (e.token) {
        token_signal => self.end = .signal,
        token_nvim => if (!try self.onNvim()) {
            self.end = .nvim_exited;
        },
        token_rex => try self.onRex(),
        token_listener => {},
        else => {
            const t = Pane.fromToken(e.token);
            // gone already if closed earlier in this batch
            const p = self.paneById(t.id) orelse return;
            switch (t.source) {
                .socket => try self.onHelper(p),
                .tty => try self.onInput(p),
            }
        },
    }
}

/// After each batch of events: tells Neovim whether any pane has focus.
pub fn afterBatch(self: *Daemon) !void {
    var known = false;
    var any = false;
    for (self.panes.items) |p| if (p.forwarder.focused) |f| {
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
pub fn accept(self: *Daemon, server: *net.Server) !void {
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
    const p = if (id) |i| self.paneById(i) else null;
    if (p == null or p.?.conn != null) {
        std.debug.print("neorex daemon: a helper nobody asked for\n", .{});
        _ = std.c.close(tty);
        stream.close(self.io);
        return;
    }
    const pane = p.?;
    pane.connect(stream, tty) catch |err| {
        _ = std.c.close(tty);
        stream.close(self.io);
        return err;
    };
    try self.watch(pane);
    try self.sizeWindow(pane);
    try self.nvim.flush();
    try self.draw();
}

fn watch(self: *Daemon, p: *Pane) !void {
    const c = p.conn.?;
    try self.loop.addRead(c.stream.socket.handle, p.token(.socket));
    try self.loop.addRead(c.term.fd, p.token(.tty));
}

fn paneById(self: *const Daemon, id: u32) ?*Pane {
    for (self.panes.items) |p| if (p.id == id) return p;
    return null;
}

fn paneByWin(self: *const Daemon, win: i64) ?*Pane {
    if (win == 0) return null;
    for (self.panes.items) |p| if (p.win == win) return p;
    return null;
}

fn paneByBlock(self: *const Daemon, block: []const u8) ?*Pane {
    for (self.panes.items) |p| if (p.block) |b| if (std.mem.eql(u8, b, block)) return p;
    return null;
}

/// The pane showing Neovim's current window; before setup, the launcher's.
fn focusedPane(self: *const Daemon) ?*Pane {
    if (self.current == 0) return self.paneById(0);
    return self.paneByWin(self.current);
}

// Neovim

fn onNvim(self: *Daemon) !bool {
    if (!try self.nvim.read(self.gpa)) return false;
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
                .reopen => |win| if (self.paneByWin(win)) |p| {
                    p.reuse = true;
                },
                .split => |sp| if (self.paneByWin(sp.win) == null) try self.splits.put(self.gpa, sp.win, sp),
            };
        },
        .request => |r| try self.nvim.respondError(r.id, "neorex serves no requests"),
        .response => |r| {
            var result = r.result;
            if (r.id == self.current_req) self.current_req = null;
            if (r.err) |e| {
                std.debug.print("neovim error: {s}\n", .{e});
            } else if (r.id == self.chan_req) {
                const launch = self.paneById(0).?;
                const size = launch.windowSize();
                self.setup_req = try windows.setup(self.nvim, try windows.parseChannel(&result), size[0], size[1]);
                try self.nvim.flush();
            } else if (r.id == self.setup_req) {
                const wins = try windows.parseSetup(&result);
                if (self.paneById(0)) |launch| launch.win = wins[0];
                self.ready = true;
                try self.reconcile();
                try self.draw();
            }
        },
    };
    return true;
}

/// Neovim's current window changed: focus its pane in Rex.
fn onCurrent(self: *Daemon, win: i64) !void {
    // sent before our own change ran; the report after it is coming
    if (self.current_req != null) return;
    self.current = win;
    const p = self.paneByWin(win) orelse return;
    try self.followFocus(p);
    try self.draw();
    try self.focusInRex(p);
}

/// The editor's size follows the focused pane, so messages fit it.
fn followFocus(self: *Daemon, p: *Pane) !void {
    if (p.conn == null) return;
    try self.nvim.uiTryResize(p.view.cols, p.view.rows);
}

fn focusInRex(self: *Daemon, p: *Pane) !void {
    const block = p.block orelse return;
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
    var i = self.panes.items.len;
    while (i > 0) {
        i -= 1;
        const p = self.panes.items[i];
        if (p.win == 0 or self.grids.gridOf(p.win) != null) continue;
        if (p.reuse) {
            p.win = 0;
            p.reuse = false;
            continue;
        }
        self.removePane(i);
    }
    if (self.panes.items.len == 0) {
        self.end = .pane_gone;
        return;
    }
    // forget windows that are gone
    for ([_]*std.AutoArrayHashMapUnmanaged(i64, void){ &self.asked, &self.closing }) |set| {
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
            const size = if (self.paneByWin(w.win)) |p| p.windowSize() else self.newWindowSize(w.win);
            try windows.adopt(self.nvim, w.win, size[0], size[1]);
        },
        .external => {
            _ = self.asked.swapRemove(w.win);
            if (self.paneByWin(w.win) != null or self.closing.contains(w.win)) continue;
            if (self.waitingPane()) |p| {
                p.win = w.win;
            } else {
                try self.newPane(w.win);
            }
        },
        .float, .hidden => {},
    };
    for (self.panes.items) |p| try self.sizeWindow(p);
    try self.nvim.flush();
}

/// A pane kept for a reopened window.
fn waitingPane(self: *const Daemon) ?*Pane {
    for (self.panes.items) |p| if (p.win == 0 and p.conn != null) return p;
    return null;
}

/// A guess until the new pane says its size: half the pane it splits.
fn newWindowSize(self: *const Daemon, win: i64) [2]u32 {
    const sp = self.splitOf(win);
    const p = self.splitFrom(sp) orelse return .{ 80, 24 };
    const s = p.windowSize();
    if (sp.side_by_side) return .{ @max(s[0] / 2, 1), s[1] };
    return .{ s[0], @max(s[1] / 2, 1) };
}

/// Where Neovim put `win`; beside the current window if it didn't say.
fn splitOf(self: *const Daemon, win: i64) windows.Split {
    return self.splits.get(win) orelse .{ .win = win, .side_by_side = true, .before = false, .from = 0 };
}

/// The pane a new window splits: its origin's, else the focused one.
fn splitFrom(self: *const Daemon, sp: windows.Split) ?*Pane {
    if (sp.from != 0) if (self.paneByWin(sp.from)) |p| return p;
    return self.focusedPane();
}

/// Asks Neovim for the window to fit the pane, unless it already was.
fn sizeWindow(self: *Daemon, p: *Pane) !void {
    if (p.conn == null) return;
    const grid = self.grids.gridOf(p.win) orelse return;
    const size = p.windowSize();
    if (p.asked.grid == grid and p.asked.cols == size[0] and p.asked.rows == size[1]) return;
    p.asked = .{ .grid = grid, .cols = size[0], .rows = size[1] };
    try self.nvim.uiTryResizeGrid(grid, size[0], size[1]);
}

/// Draws every pane that changed.
fn draw(self: *Daemon) !void {
    const focused = self.focusedPane();
    var i = self.panes.items.len;
    while (i > 0) {
        i -= 1;
        const p = self.panes.items[i];
        const c = &(p.conn orelse continue);
        const grid = if (p.win != 0) self.grids.gridOf(p.win) else null;
        const drawn = p.view.frame(&self.grids, grid, p == focused, &c.term.writer) catch false;
        if (drawn) c.term.flush() catch try self.paneGone(p);
    }
    // the message grid is drawn into one pane at most; done with it
    if (self.grids.msg_grid) |id| if (self.grids.get(id)) |m| {
        m.dirty.unsetAll();
        m.scrolls_len = 0;
    };
}

// panes

fn newPane(self: *Daemon, win: i64) !void {
    const sp = self.splitOf(win);
    // beside the window it came from, else any pane Rex knows
    const anchor = blk: {
        if (self.splitFrom(sp)) |f| if (f.block) |b| break :blk b;
        for (self.panes.items) |q| if (q.block) |b| break :blk b;
        return; // no anchor yet: next flush
    };
    const p = try self.gpa.create(Pane);
    p.* = .{ .id = self.next_pane_id, .win = win };
    self.next_pane_id += 1;
    errdefer self.gpa.destroy(p);
    try self.panes.append(self.gpa, p);
    _ = self.splits.swapRemove(win);

    var id_buf: [16]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{p.id});
    try self.rexRequest(.split, p.id, "session.new_split", .{
        .session_id = self.session_id,
        .anchor_id = anchor,
        .direction = if (sp.side_by_side) "horizontal" else "vertical",
        .side = if (sp.before) "before" else "after",
        .layout = .{ .block = .{
            .flavor = "com.superlogical.terminal.shell",
            .label = "neorex",
            .options = .{ .shell = "none", .command = &[_][]const u8{ self.exe, "pane", self.sock, id } },
        } },
    });
}

/// Hangs up pane `i` and forgets it.
fn removePane(self: *Daemon, i: usize) void {
    const p = self.panes.orderedRemove(i);
    p.deinit(self.gpa, self.io);
    self.gpa.destroy(p);
}

/// The helper or terminal went away: Rex closed the pane. Close its
/// window, or end if it was the last pane.
fn paneGone(self: *Daemon, p: *Pane) !void {
    p.gone = true;
    const i = std.mem.indexOfScalar(*Pane, self.panes.items, p).?;
    var others = false;
    for (self.panes.items) |q| {
        if (q != p and !q.failed) others = true;
    }
    if (!others) {
        self.end = .pane_gone;
        return;
    }
    const win = p.win;
    self.removePane(i);
    if (win == 0) return;
    try self.closing.put(self.gpa, win, {});
    try windows.close(self.nvim, win);
    try self.nvim.flush();
}

fn onHelper(self: *Daemon, p: *Pane) !void {
    var buf: [64]u8 = undefined;
    const r = fdpass.recv(p.conn.?.stream, self.io, &buf) catch return self.paneGone(p);
    if (r.fd) |fd| _ = std.c.close(fd);
    if (r.len == 0) return self.paneGone(p);
    for (buf[0..r.len]) |b| if (@as(pane_helper.Message, @enumFromInt(b)) == .resized) {
        const ws = p.conn.?.term.size() catch return self.paneGone(p);
        p.view.resize(ws.col, ws.row);
        try self.sizeWindow(p);
        if (p == self.focusedPane()) try self.followFocus(p);
        try self.nvim.flush();
        try self.draw();
    };
}

fn onInput(self: *Daemon, p: *Pane) !void {
    var buf: [4096]u8 = undefined;
    const c = &p.conn.?;
    const n = std.c.read(c.term.fd, &buf, buf.len);
    if (n <= 0) return self.paneGone(p);
    const bytes = buf[0..@intCast(n)];
    // typed in a pane Rex hasn't focused, as `rex send` can: that window first.
    // Not focus reports: Rex sends them as it moves focus away.
    if (p.win != 0 and p.win != self.current and !self.rexFocuses(p) and !input.onlyFocusReports(bytes)) {
        self.current = p.win;
        self.current_req = try windows.setCurrent(self.nvim, p.win);
        try self.followFocus(p);
        try self.focusInRex(p);
    }
    p.forwarder.grid = self.grids.gridOf(p.win) orelse 0;
    _ = try p.forwarder.feed(self.nvim, bytes);
}

fn rexFocuses(self: *const Daemon, p: *const Pane) bool {
    const f = self.rex_focused orelse return false;
    const b = p.block orelse return false;
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
            if (req.kind == .split) if (self.paneById(req.pane)) |p| {
                p.failed = true;
            };
            return;
        },
    };
    if (req.kind != .split) return;
    const p = self.paneById(req.pane) orelse return;
    const ids = Client.get(ok, "block_ids") orelse return;
    if (ids != .array or ids.array.items.len == 0) return;
    const block = Client.str(ids.array.items[0]) orelse return;
    p.block = try self.gpa.dupe(u8, block);
    // the creator owns the block and sizes it; let the app size it instead
    try self.rexRequest(.other, 0, "session.disown_block", .{ .session_id = self.session_id, .block_ids = &[_][]const u8{block} });
    if (p.win == self.current) try self.focusInRex(p);
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
    const p = self.paneByBlock(block) orelse return;
    if (p.win == 0 or p.win == self.current) return;
    self.current = p.win;
    self.current_req = try windows.setCurrent(self.nvim, p.win);
    try self.followFocus(p);
    try self.nvim.flush();
    try self.draw();
}
