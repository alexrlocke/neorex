//! Our side of the Rex session: requests in flight, the session view,
//! and which block Rex has focused.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Client = @import("Client.zig");
const WebSocket = @import("WebSocket.zig");
const ids = @import("ids.zig");

const Session = @This();

/// What a request asked for; tags match Rex's methods.
const Request = union(enum) {
    attach,
    new_split: u32, // pane
    new_layer: u32, // pane
    focus_block,
    view,
    disown_block,
    close_block,
    close_layer,
};

/// Sent, not answered yet.
const Pending = struct { id: u64, req: Request };

gpa: Allocator,
client: *Client,
session_id: []const u8,

pending_requests: std.ArrayList(Pending) = .empty,

/// Nothing is sent once closed; windows keep working without Rex.
conn: enum { attaching, attached, closed } = .attaching,

/// The newest view read, and whether one is on its way.
view: struct {
    rev: i64 = -1,
    fetch: enum { idle, running, stale } = .idle,
} = .{},

/// The block Rex has focused, and our change to it still landing.
focused_block: union(enum) {
    unknown,
    settled: ids.Block,
    requesting: struct { block: ids.Block, in_flight: u32, applied_rev: i64 = 0 },
} = .unknown,

/// The Rex window our panes are in, as the daemon last found in a view.
window: ?[43]u8 = null,

/// A focus change from the same view as a `layout` update, sent after it.
queued_focus: ?[]const u8 = null,

/// What the daemon has to act on. Slices are only good until the next
/// call to `next`.
pub const Update = union(enum) {
    /// The split asked for `pane` exists, as `block`.
    split_made: struct { pane: u32, block: []const u8 },
    /// Rex refused the split asked for this pane.
    split_failed: Failed,
    /// The floating layer asked for `pane` exists, as `layer` holding `block`.
    layer_made: struct { pane: u32, block: []const u8, layer: ?[]const u8 },
    /// Rex refused the floating layer asked for this pane.
    layer_failed: Failed,
    /// A newer view's windows, to read where our panes sit.
    layout: []const std.json.Value,
    /// The user focused this block in Rex.
    focus_moved: []const u8,

    pub const Failed = struct { pane: u32 };
};

pub fn deinit(self: *Session) void {
    self.pending_requests.deinit(self.gpa);
}

/// Joins our Rex session, so we hear its events and can split it.
pub fn attach(self: *Session) !void {
    try self.request(.attach, "session.attach", .{ .session_id = self.session_id });
}

/// One read from Rex; false once it hung up. Then call `next` until null.
pub fn read(self: *Session) !bool {
    if (!try self.client.read(self.gpa)) {
        std.debug.print("neorex daemon: Rex hung up\n", .{});
        self.conn = .closed;
        return false;
    }
    return true;
}

/// The next update for the daemon, or null when there are none.
pub fn next(self: *Session) !?Update {
    if (self.queued_focus) |block| {
        self.queued_focus = null;
        return .{ .focus_moved = block };
    }
    while (try self.client.next(self.gpa)) |message| switch (message) {
        .response => |r| if (try self.onResponse(r)) |update| return update,
        .event => |ev| try self.onEvent(ev),
        .closed => |c| self.onClosed(c),
    };
    if (self.conn == .closed) return self.failPendingSplit();
    return null;
}

/// Asks Rex to focus `maybe_block`, unless it already has or will.
pub fn focus(self: *Session, maybe_block: ?ids.Block) !void {
    if (self.conn == .closed) return;
    const block = maybe_block orelse return;
    if (self.hasFocused(block)) return;
    try self.request(.focus_block, "session.focus_block", .{
        .session_id = self.session_id,
        .block_id = @as([]const u8, &block),
    });
    switch (self.focused_block) {
        .requesting => |*pending_focus| {
            pending_focus.block = block;
            pending_focus.in_flight += 1;
        },
        else => self.focused_block = .{ .requesting = .{ .block = block, .in_flight = 1 } },
    }
}

/// Rex has focused `maybe_block`, or will once our request lands.
pub fn hasFocused(self: *const Session, maybe_block: ?ids.Block) bool {
    const focused_block = self.currentFocus() orelse return false;
    return ids.sameBlock(focused_block, maybe_block orelse return false);
}

/// The creator owns a block and sizes it; this lets the app size it instead.
pub fn disown(self: *Session, block: []const u8) !void {
    try self.request(.disown_block, "session.disown_block", .{ .session_id = self.session_id, .block_ids = &[_][]const u8{block} });
}

/// Closes a block we made. Its helper, if it ever connects, finds no pane and leaves.
pub fn closeBlock(self: *Session, block: []const u8) !void {
    try self.request(.close_block, "block.close", .{ .session_id = self.session_id, .block_id = block });
}

/// Closes a floating layer we made.
pub fn closeLayer(self: *Session, layer: []const u8) !void {
    try self.request(.close_layer, "session.close_layer", .{ .session_id = self.session_id, .layer_id = layer });
}

/// Asks for a floating layer at `bounds` in our window, holding `layout`.
pub fn newLayer(self: *Session, pane_id: u32, bounds: [4]f64, layout: anytype) !void {
    if (self.window) |*w| {
        try self.request(.{ .new_layer = pane_id }, "session.new_layer", .{ .session_id = self.session_id, .window_id = @as([]const u8, w), .bounds = bounds, .layout = layout });
    } else {
        try self.request(.{ .new_layer = pane_id }, "session.new_layer", .{ .session_id = self.session_id, .bounds = bounds, .layout = layout });
    }
}

/// Send a request to the Rex client, add it to list of pending requests
pub fn request(
    self: *Session,
    req: Request,
    method: []const u8,
    payload: anytype,
) !void {
    if (self.conn == .closed) return;
    const id = try self.client.request(self.gpa, method, payload);
    try self.pending_requests.append(self.gpa, .{ .id = id, .req = req });
}

/// Hands an answer to its request's handler.
pub fn onResponse(self: *Session, res: Client.Response) !?Update {
    const req = self.takePendingRequest(res.id) orelse return null;
    if (res.result == .err) logRequestError(req, res.result.err);
    switch (req) {
        .new_split => |pane| return onNewSplitResult(pane, res.result),
        .new_layer => |pane| return onNewLayerResult(pane, res.result),
        .view => return try self.onViewResult(res.result),
        .focus_block => try self.onFocusBlockResult(res.result),
        .attach => try self.onAttachResult(res.result),
        .disown_block, .close_block, .close_layer => {},
    }
    return null;
}

/// Only a newer session view matters.
fn onEvent(self: *Session, event: Client.Event) !void {
    if (!std.mem.eql(u8, event.name, "session_view_changed")) return;
    const rev = Client.getInt(event.payload, "revision") orelse return;
    if (rev > self.view.rev) try self.fetchView();
}

fn onClosed(self: *Session, c: WebSocket.Close) void {
    std.debug.print("neorex daemon: Rex closed {?d} {s}\n", .{ c.code, c.reason });
    self.conn = .closed;
}

/// Closed: no answers will come, so fail the splits still waiting.
fn failPendingSplit(self: *Session) ?Update {
    while (self.pending_requests.pop()) |p| switch (p.req) {
        .new_split => |pane| return .{ .split_failed = .{ .pane = pane } },
        .new_layer => |pane| return .{ .layer_failed = .{ .pane = pane } },
        else => {},
    };
    return null;
}

/// Removes and returns the request `id` answers.
pub fn takePendingRequest(self: *Session, id: u64) ?Request {
    for (self.pending_requests.items, 0..) |p, i| {
        if (p.id == id) return self.pending_requests.swapRemove(i).req;
    }
    return null;
}

/// Attached: a view gives the starting focus.
fn onAttachResult(self: *Session, result: Client.Result) !void {
    switch (result) {
        .ok => {
            self.conn = .attached;
            try self.fetchView();
        },
        .err => self.conn = .closed,
    }
}

/// Always an update: the pane is waiting either way.
pub fn onNewSplitResult(pane_id: u32, result: Client.Result) Update {
    const ok = switch (result) {
        .ok => |val| val,
        .err => return .{ .split_failed = .{ .pane = pane_id } },
    };
    const block = newBlockId(ok) orelse {
        logUnexpectedResponse(.{ .new_split = pane_id }, "block_ids");
        return .{ .split_failed = .{ .pane = pane_id } };
    };
    return .{ .split_made = .{ .pane = pane_id, .block = block } };
}

/// Always an update: the pane is waiting either way.
fn onNewLayerResult(pane_id: u32, result: Client.Result) Update {
    const ok = switch (result) {
        .ok => |val| val,
        .err => return .{ .layer_failed = .{ .pane = pane_id } },
    };
    const block = newBlockId(ok) orelse {
        logUnexpectedResponse(.{ .new_layer = pane_id }, "block_ids");
        return .{ .layer_failed = .{ .pane = pane_id } };
    };
    return .{ .layer_made = .{ .pane = pane_id, .block = block, .layer = Client.getStr(ok, "layer_id") } };
}

/// The block a split made.
fn newBlockId(ok: std.json.Value) ?[]const u8 {
    const block_ids = Client.get(ok, "block_ids") orelse return null;
    if (block_ids != .array or block_ids.array.items.len == 0) return null;
    return Client.str(block_ids.array.items[0]);
}

/// Records the revision our focus change landed at.
fn onFocusBlockResult(self: *Session, result: Client.Result) !void {
    if (self.focused_block != .requesting) return;
    const pending_focus = &self.focused_block.requesting;
    pending_focus.in_flight -= 1;
    switch (result) {
        .ok => |val| {
            const rev = Client.getInt(val, "revision") orelse 0;
            if (rev > pending_focus.applied_rev) pending_focus.applied_rev = rev;
        },
        // refused => need to ask for view
        .err => if (pending_focus.in_flight == 0) try self.fetchView(),
    }
}

/// Applies the view, then fetches again if it was already out of date.
fn onViewResult(self: *Session, result: Client.Result) !?Update {
    const stale = self.view.fetch == .stale;
    self.view.fetch = .idle;
    const update = switch (result) {
        .ok => |val| self.applyView(val),
        .err => null,
    };
    if (stale) try self.fetchView();
    return update;
}

/// Fetches the session view, or another after the one on its way.
fn fetchView(self: *Session) !void {
    switch (self.view.fetch) {
        .idle => {
            if (self.conn == .closed) return;
            try self.request(.view, "session.view", .{ .session_id = self.session_id });
            self.view.fetch = .running;
        },
        // the answer will be out of date: fetch again when it arrives
        .running => self.view.fetch = .stale,
        .stale => {},
    }
}

/// Skips views no newer than the last one read. Layout comes first, then
/// any focus change.
fn applyView(self: *Session, snapshot: std.json.Value) ?Update {
    const rev = Client.getInt(snapshot, "revision") orelse return null;
    if (rev <= self.view.rev) return null;
    self.view.rev = rev;
    const focus_update = if (findFocusedBlock(snapshot)) |block| self.applyFocus(block, rev) else blk: {
        logUnexpectedResponse(.view, "focused block");
        break :blk null;
    };
    const windows = Client.get(snapshot, "windows") orelse return focus_update;
    if (windows != .array) return focus_update;
    if (focus_update) |u| self.queued_focus = u.focus_moved;
    return .{ .layout = windows.array.items };
}

/// The focused block of the active window.
fn findFocusedBlock(snapshot: std.json.Value) ?ids.Block {
    const active_id = Client.getStr(snapshot, "active_window_id") orelse return null;
    const windows = Client.get(snapshot, "windows") orelse return null;
    if (windows != .array) return null;
    for (windows.array.items) |win| {
        const win_id = Client.getStr(win, "window_id") orelse continue;
        if (std.mem.eql(u8, win_id, active_id)) {
            const block = Client.getStr(win, "focused_block_id") orelse return null;
            return ids.block(block) catch null;
        }
    }
    return null;
}

/// Reports focus the user moved; echoes of our own change are ignored.
fn applyFocus(self: *Session, block: ids.Block, rev: i64) ?Update {
    switch (self.focused_block) {
        .requesting => |pending_focus| {
            if (pending_focus.in_flight > 0 or rev < pending_focus.applied_rev) return null;
            if (std.mem.eql(u8, &pending_focus.block, &block)) {
                self.focused_block = .{ .settled = block };
                return null;
            }
        },
        .settled => |last_focused_block| {
            if (std.mem.eql(u8, &last_focused_block, &block)) return null;
        },
        .unknown => {},
    }

    const report = self.focused_block != .unknown;
    self.focused_block = .{ .settled = block };
    return if (report) .{ .focus_moved = &self.focused_block.settled } else null;
}

/// The block Rex has focused, as we last saw or asked.
fn currentFocus(self: *const Session) ?ids.Block {
    return switch (self.focused_block) {
        .unknown => null,
        .settled => |last_focused| last_focused,
        .requesting => |pending_focus| pending_focus.block,
    };
}

// Loggers

/// Rex refused a request.
pub fn logRequestError(req: Request, e: Client.Error) void {
    switch (req) {
        .new_split => |pane| std.debug.print(
            "neorex daemon: Rex new_split for pane {d} failed: {s}: {s}\n",
            .{ pane, e.code, e.message },
        ),
        else => std.debug.print(
            "neorex daemon: Rex {s} failed: {s}: {s}\n",
            .{ @tagName(req), e.code, e.message },
        ),
    }
}

/// Rex said yes, in a shape we can't read.
fn logUnexpectedResponse(req: Request, what: []const u8) void {
    std.debug.print("neorex daemon: Rex {s} answer has no {s}\n", .{ @tagName(req), what });
}
