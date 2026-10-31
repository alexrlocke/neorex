//! Our side of the Rex session: requests in flight, which block Rex has
//! focused, and the latest session view. Reports only what the daemon
//! has to act on; the rest it handles itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Client = @import("../rex/Client.zig");
const Pane = @import("Pane.zig");

const RexSession = @This();

gpa: Allocator,
client: *Client,
session_id: []const u8,
/// Rex requests waiting for an answer.
pending: std.ArrayList(Request) = .empty,
/// False once Rex hangs up: windows keep working, but no new panes or focus.
open: bool = true,
/// The block Rex has focused, as we last saw or asked; owned.
focused_block: ?[]u8 = null,
/// The newest session view we've read, and whether one is on its way.
view_rev: i64 = -1,
view_pending: bool = false,
view_outdated: bool = false,
/// Focus requests in flight; views older than the last one's answer are stale.
focus_pending: u32 = 0,
focus_rev: i64 = 0,

const Request = struct {
    id: u64,
    kind: enum { split, focus, view, other },
    pane: u32 = 0,
};

/// What Rex said that the daemon has to act on. Slices are only good
/// until the next call to `next`.
pub const Update = union(enum) {
    /// The split asked for `pane` exists, as `block`.
    split_made: struct { pane: u32, block: []const u8 },
    /// Rex refused the split asked for this pane.
    split_failed: u32,
    /// The user focused this block in Rex.
    focus_moved: []const u8,
};

pub fn deinit(self: *RexSession) void {
    self.pending.deinit(self.gpa);
    if (self.focused_block) |b| self.gpa.free(b);
}

/// Attaches to our Rex session, so we hear its events and can split it.
pub fn attach(self: *RexSession) !void {
    try self.request(.other, 0, "session.attach", .{ .session_id = self.session_id });
}

pub fn focus(self: *RexSession, p: *Pane) !void {
    const block: []const u8 = if (p.rex_block) |*b| b else return;
    if (self.focused_block) |f| if (std.mem.eql(u8, f, block)) return;
    try self.rememberFocused(block);
    self.focus_pending += 1;
    try self.request(.focus, 0, "session.focus_block", .{ .session_id = self.session_id, .block_id = block });
}

pub fn rememberFocused(self: *RexSession, block: []const u8) !void {
    const copy = try self.gpa.dupe(u8, block);
    if (self.focused_block) |f| self.gpa.free(f);
    self.focused_block = copy;
}

pub fn hasFocused(self: *const RexSession, p: *const Pane) bool {
    const f = self.focused_block orelse return false;
    const b = if (p.rex_block) |*b| b else return false;
    return std.mem.eql(u8, f, b);
}

pub fn request(self: *RexSession, kind: @FieldType(Request, "kind"), pane: u32, method: []const u8, payload: anytype) !void {
    if (!self.open) return;
    const id = try self.client.request(self.gpa, method, payload);
    try self.pending.append(self.gpa, .{ .id = id, .kind = kind, .pane = pane });
}

pub fn askView(self: *RexSession) !void {
    self.view_pending = true;
    self.view_outdated = false;
    try self.request(.view, 0, "session.view", .{ .session_id = self.session_id });
}

/// The creator owns a block and sizes it; this lets the app size it instead.
pub fn disown(self: *RexSession, block: []const u8) !void {
    try self.request(.other, 0, "session.disown_block", .{ .session_id = self.session_id, .block_ids = &[_][]const u8{block} });
}

/// Reads what Rex sent; false once it hung up. Then call `next` until null.
pub fn read(self: *RexSession) !bool {
    if (!try self.client.read(self.gpa)) {
        std.debug.print("neorex daemon: Rex hung up\n", .{});
        self.open = false;
        return false;
    }
    return true;
}

pub fn next(self: *RexSession) !?Update {
    while (try self.client.next(self.gpa)) |m| switch (m) {
        .response => |r| if (try self.onResponse(r)) |update| return update,
        .event => |ev| if (std.mem.eql(u8, ev.name, "session_view_changed")) {
            const rev = Client.int(Client.get(ev.payload, "revision")) orelse continue;
            if (rev <= self.view_rev) continue;
            if (self.view_pending) {
                self.view_outdated = true;
            } else {
                try self.askView();
            }
        },
        .closed => |c| {
            std.debug.print("neorex daemon: Rex closed {?d} {s}\n", .{ c.code, c.reason });
            self.open = false;
        },
    };
    return null;
}

fn onResponse(self: *RexSession, r: Client.Response) !?Update {
    const i = for (self.pending.items, 0..) |q, i| {
        if (q.id == r.id) break i;
    } else return null;
    const req = self.pending.swapRemove(i);
    var update: ?Update = null;
    switch (req.kind) {
        .focus => {
            self.focus_pending -|= 1;
            if (r.result == .ok) self.focus_rev = @max(self.focus_rev, Client.int(Client.get(r.result.ok, "revision")) orelse 0);
        },
        .view => {
            self.view_pending = false;
            if (r.result == .ok) update = try self.onView(r.result.ok);
            if (self.view_outdated) try self.askView();
        },
        else => {},
    }
    const ok = switch (r.result) {
        .ok => |v| v,
        .err => |e| {
            std.debug.print("neorex daemon: Rex request failed: {s}: {s}\n", .{ e.code, e.message });
            return if (req.kind == .split) .{ .split_failed = req.pane } else null;
        },
    };
    if (req.kind != .split) return update;
    const ids = Client.get(ok, "block_ids") orelse return null;
    if (ids != .array or ids.array.items.len == 0) return null;
    const block = Client.str(ids.array.items[0]) orelse return null;
    return .{ .split_made = .{ .pane = req.pane, .block = block } };
}

/// A session view: reports focus the user moved to another block.
fn onView(self: *RexSession, v: Value) !?Update {
    const rev = Client.int(Client.get(v, "revision")) orelse return null;
    if (rev <= self.view_rev) return null;
    self.view_rev = rev;
    // from before our own focus change landed
    if (self.focus_pending > 0 or rev < self.focus_rev) return null;
    const active = Client.str(Client.get(v, "active_window_id")) orelse return null;
    const wins = Client.get(v, "windows") orelse return null;
    if (wins != .array) return null;
    const block = for (wins.array.items) |w| {
        if (std.mem.eql(u8, Client.str(Client.get(w, "window_id")) orelse "", active)) break Client.str(Client.get(w, "focused_block_id")) orelse return null;
    } else return null;
    // unchanged: any difference is Neovim's move, which focus_block follows
    const known = self.focused_block;
    if (known) |f| if (std.mem.eql(u8, f, block)) return null;
    try self.rememberFocused(block);
    if (known == null) return null;
    return .{ .focus_moved = self.focused_block.? };
}
