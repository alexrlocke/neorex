//! Our side of the Rex session: requests in flight, the session view,
//! and which block Rex has focused.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Client = @import("../rex/Client.zig");
const Pane = @import("Pane.zig");
const WebSocket = @import("../rex/WebSocket.zig");

const RexSession = @This();

/// What a request asked for; tags match Rex's methods.
const Request = union(enum) {
    attach,
    new_split: u32, // pane
    focus_block,
    view,
    disown_block,
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
    settled: Pane.RexBlock,
    requesting: struct { block: Pane.RexBlock, in_flight: u32, applied_rev: i64 = 0 },
} = .unknown,

/// What the daemon has to act on. Slices are only good until the next
/// call to `next`.
pub const Update = union(enum) {
    /// The split asked for `pane` exists, as `block`.
    split_made: struct { pane: u32, block: []const u8 },
    /// Rex refused the split asked for this pane.
    split_failed: struct { pane: u32 },
    /// The user focused this block in Rex.
    focus_moved: []const u8,
};

pub fn deinit(self: *RexSession) void {
    self.pending_requests.deinit(self.gpa);
}

/// Joins our Rex session, so we hear its events and can split it.
pub fn attach(self: *RexSession) !void {
    try self.request(.attach, "session.attach", .{ .session_id = self.session_id });
}

/// One read from Rex; false once it hung up. Then call `next` until null.
pub fn read(self: *RexSession) !bool {
    if (!try self.client.read(self.gpa)) {
        std.debug.print("neorex daemon: Rex hung up\n", .{});
        self.conn = .closed;
        return false;
    }
    return true;
}

/// The next update for the daemon, or null when there are none.
pub fn next(self: *RexSession) !?Update {
    while (try self.client.next(self.gpa)) |message| switch (message) {
        .response => |r| if (try self.onResponse(r)) |update| return update,
        .event => |ev| try self.onEvent(ev),
        .closed => |c| self.onClosed(c),
    };
    if (self.conn == .closed) return self.failPendingSplit();
    return null;
}

/// Asks Rex to focus the pane's block, unless it already has or will.
pub fn focus(self: *RexSession, pane: *const Pane) !void {
    if (self.conn == .closed) return;
    const block = pane.rex_block orelse return;
    if (self.isFocusedOrAsked(block)) return;
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

/// Rex has focused the pane's block, or will once our request lands.
pub fn hasFocused(self: *const RexSession, pane: *const Pane) bool {
    return self.isFocusedOrAsked(pane.rex_block orelse return false);
}

/// The creator owns a block and sizes it; this lets the app size it instead.
pub fn disown(self: *RexSession, block: []const u8) !void {
    try self.request(.disown_block, "session.disown_block", .{ .session_id = self.session_id, .block_ids = &[_][]const u8{block} });
}

/// Send a request to the Rex client, add it to list of pending requests
pub fn request(
    self: *RexSession,
    req: Request,
    method: []const u8,
    payload: anytype,
) !void {
    if (self.conn == .closed) return;
    const id = try self.client.request(self.gpa, method, payload);
    try self.pending_requests.append(self.gpa, .{ .id = id, .req = req });
}

/// Hands an answer to its request's handler.
pub fn onResponse(self: *RexSession, res: Client.Response) !?Update {
    const req = self.takePendingRequest(res.id) orelse return null;
    if (res.result == .err) logRequestError(req, res.result.err);
    switch (req) {
        .new_split => |pane| return onNewSplitResult(pane, res.result),
        .view => return try self.onViewResult(res.result),
        .focus_block => try self.onFocusBlockResult(res.result),
        .attach => try self.onAttachResult(res.result),
        .disown_block => {},
    }
    return null;
}

/// Only a newer session view matters.
fn onEvent(self: *RexSession, event: Client.Event) !void {
    if (!std.mem.eql(u8, event.name, "session_view_changed")) return;
    const rev = Client.getInt(event.payload, "revision") orelse return;
    if (rev > self.view.rev) try self.fetchView();
}

fn onClosed(self: *RexSession, c: WebSocket.Close) void {
    std.debug.print("neorex daemon: Rex closed {?d} {s}\n", .{ c.code, c.reason });
    self.conn = .closed;
}

/// Closed: no answers will come, so fail the splits still waiting.
fn failPendingSplit(self: *RexSession) ?Update {
    while (self.pending_requests.pop()) |p| switch (p.req) {
        .new_split => |pane| return .{ .split_failed = .{ .pane = pane } },
        else => {},
    };
    return null;
}

/// Removes and returns the request `id` answers.
pub fn takePendingRequest(self: *RexSession, id: u64) ?Request {
    for (self.pending_requests.items, 0..) |p, i| {
        if (p.id == id) return self.pending_requests.swapRemove(i).req;
    }
    return null;
}

/// Attached: a view gives the starting focus.
fn onAttachResult(self: *RexSession, result: Client.Result) !void {
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

/// The block a split made.
fn newBlockId(ok: std.json.Value) ?[]const u8 {
    const ids = Client.get(ok, "block_ids") orelse return null;
    if (ids != .array or ids.array.items.len == 0) return null;
    return Client.str(ids.array.items[0]);
}

/// Records the revision our focus change landed at.
fn onFocusBlockResult(self: *RexSession, result: Client.Result) !void {
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
fn onViewResult(self: *RexSession, result: Client.Result) !?Update {
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
fn fetchView(self: *RexSession) !void {
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

/// Skips views no newer than the last one read.
fn applyView(self: *RexSession, snapshot: std.json.Value) ?Update {
    const rev = Client.getInt(snapshot, "revision") orelse return null;
    if (rev <= self.view.rev) return null;
    self.view.rev = rev;
    const block = findFocusedBlock(snapshot) orelse {
        logUnexpectedResponse(.view, "focused block");
        return null;
    };
    return self.applyFocus(block, rev);
}

/// The focused block of the active window.
fn findFocusedBlock(snapshot: std.json.Value) ?Pane.RexBlock {
    const active_id = Client.getStr(snapshot, "active_window_id") orelse return null;
    const windows = Client.get(snapshot, "windows") orelse return null;
    if (windows != .array) return null;
    for (windows.array.items) |win| {
        const win_id = Client.getStr(win, "window_id") orelse continue;
        if (std.mem.eql(u8, win_id, active_id)) {
            const block = Client.getStr(win, "focused_block_id") orelse return null;
            return Pane.rexBlock(block) catch null;
        }
    }
    return null;
}

/// Reports focus the user moved; echoes of our own change are ignored.
fn applyFocus(self: *RexSession, block: Pane.RexBlock, rev: i64) ?Update {
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
fn currentFocus(self: *const RexSession) ?Pane.RexBlock {
    return switch (self.focused_block) {
        .unknown => null,
        .settled => |last_focused| last_focused,
        .requesting => |pending_focus| pending_focus.block,
    };
}

/// Rex has focused `block`, or will once our request lands.
fn isFocusedOrAsked(self: *const RexSession, block: Pane.RexBlock) bool {
    const focused_block = self.currentFocus() orelse return false;
    return Pane.sameBlock(focused_block, block);
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
