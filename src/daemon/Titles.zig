//! Names each pane, and our Rex window's tab, after the file its window
//! shows. A pane gets it as its block's label and as its terminal's title:
//! a pane run from a shell shows the running program's title in its header,
//! not the label. The tab takes the current window's file, unless the user
//! named it. What outlives us is put back when we exit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Client = @import("../rex/Client.zig");
const RexSession = @import("../rex/Session.zig");
const windows = @import("../nvim/windows.zig");
const Pane = @import("Pane.zig");
const Panes = @import("Panes.zig");

const Titles = @This();

/// Each window's file name, as the Lua last said; owned.
names: std.AutoArrayHashMapUnmanaged(i64, []u8) = .empty,

/// The launching pane's label before we changed it, to put back; owned.
/// Null for Rex's default.
launch_label: ?[]u8 = null,
/// A view has shown the launching pane's label: until then it isn't
/// relabeled, so there's always one to put back.
launch_label_read: bool = false,

/// The Rex window we're naming, as last found in a view.
window: ?[43]u8 = null,
/// The label we last gave it; owned. Null if we haven't.
window_label: ?[]u8 = null,
/// It has a name that's neither Rex's default nor ours: the user named it,
/// so it keeps that name.
window_named: bool = false,

/// The id `Pane.startup` gives the pane neorex was run in.
const startup_pane_id = 0;

pub fn deinit(self: *Titles, gpa: Allocator) void {
    for (self.names.values()) |n| gpa.free(n);
    self.names.deinit(gpa);
    if (self.launch_label) |l| gpa.free(l);
    if (self.window_label) |l| gpa.free(l);
    self.* = undefined;
}

/// Window `t.win` shows a file named `t.name`.
pub fn set(self: *Titles, gpa: Allocator, t: windows.Title) !void {
    const name = try gpa.dupe(u8, t.name);
    if (try self.names.fetchPut(gpa, t.win, name)) |old| gpa.free(old.value);
}

/// Window `win` closed.
pub fn forget(self: *Titles, gpa: Allocator, win: i64) void {
    if (self.names.fetchSwapRemove(win)) |old| gpa.free(old.value);
}

/// Reads a view's window `w`, the one holding our panes: its label, and
/// the launching pane's.
pub fn readWindow(self: *Titles, gpa: Allocator, panes: *const Panes, rex: *const RexSession, w: std.json.Value) void {
    const id = Client.getStr(w, "window_id") orelse return;
    if (id.len != 43) return;
    if (self.window) |*known| if (!std.mem.eql(u8, known, id)) {
        // our panes moved to another window: name that one afresh
        self.window_named = false;
        if (self.window_label) |l| gpa.free(l);
        self.window_label = null;
    };
    self.window = id[0..43].*;
    self.readWindowLabel(rex, Client.getStr(w, "label") orelse "");
    if (Client.get(w, "layers")) |layers| if (layers == .array) for (layers.array.items) |layer| {
        self.readLaunchLabel(gpa, panes, layer);
    };
}

/// A label we didn't give the window means the user named it.
fn readWindowLabel(self: *Titles, rex: *const RexSession, label: []const u8) void {
    if (self.window_named or rex.windowLabelLanding()) return;
    const w = if (self.window) |*w| w else return;
    if (defaultWindowLabel(w, label)) return;
    if (self.window_label) |l| if (std.mem.eql(u8, l, label)) return;
    self.window_named = true;
}

/// Keeps the launching pane's label, if `layer` holds it, before we first
/// change it.
fn readLaunchLabel(self: *Titles, gpa: Allocator, panes: *const Panes, layer: std.json.Value) void {
    if (self.launch_label_read) return;
    const launch = panes.byId(startup_pane_id) orelse return;
    const block: []const u8 = if (launch.rex_block) |*b| b else return;
    const blocks = Client.get(layer, "blocks") orelse return;
    if (blocks != .array) return;
    for (blocks.array.items) |b| {
        if (!std.mem.eql(u8, Client.getStr(b, "block_id") orelse "", block)) continue;
        self.launch_label_read = true;
        if (Client.getStr(b, "label")) |l| self.launch_label = gpa.dupe(u8, l) catch null;
        return;
    }
}

/// Names every pane after its window's file, and the tab after the
/// current window's, where they changed.
pub fn sync(self: *Titles, gpa: Allocator, panes: *Panes, rex: *RexSession, current_win: i64) !void {
    for (panes.list.items) |*p| try self.syncPane(gpa, p, rex);
    try self.syncWindow(gpa, rex, current_win);
}

fn syncPane(self: *Titles, gpa: Allocator, p: *Pane, rex: *RexSession) !void {
    if (p.layer != null or p.closing != null) return;
    const win = p.neovim_window_handle orelse return;
    const name = self.names.get(win) orelse return;
    if (p.label == null or !std.mem.eql(u8, p.label.?, name)) {
        const label = try gpa.dupe(u8, name);
        if (p.label) |l| gpa.free(l);
        p.label = label;
        p.labeled = false;
        p.titled = false;
    }
    const label = p.label.?;
    // the launching pane's own label first, to put back
    if (!p.labeled and (p.id != startup_pane_id or self.launch_label_read)) if (p.rex_block) |*b| {
        try rex.setBlockLabel(b, label);
        p.labeled = true;
    };
    if (!p.titled) if (p.terminal_surface) |s| {
        // the next draw finds a terminal that's gone
        writeTitle(&s.terminal.writer, label) catch {};
        s.terminal.flush() catch {};
        p.titled = true;
    };
}

fn syncWindow(self: *Titles, gpa: Allocator, rex: *RexSession, current_win: i64) !void {
    // not before a view has shown its label, so a user's name is never replaced
    if (self.window_named or self.window == null or rex.conn == .closed) return;
    const name = self.names.get(current_win) orelse return;
    if (self.window_label) |l| if (std.mem.eql(u8, l, name)) return;
    const label = try gpa.dupe(u8, name);
    if (self.window_label) |l| gpa.free(l);
    self.window_label = label;
    try rex.setWindowLabel(label);
}

/// Puts back what outlives us: the launching pane's label and title, and
/// the tab's default name.
pub fn restore(self: *Titles, panes: *Panes, rex: *RexSession) void {
    if (self.window_label != null and !self.window_named) rex.setWindowLabel("") catch {};
    const p = panes.byId(startup_pane_id) orelse return;
    if (p.closing == .rex_pane_closed) return;
    // the shell sets its own title again at its next prompt
    if (p.titled) if (p.terminal_surface) |s| writeTitle(&s.terminal.writer, "") catch {};
    if (!p.labeled) return;
    const block: []const u8 = if (p.rex_block) |*b| b else return;
    rex.setBlockLabel(block, self.launch_label orelse "") catch {};
}

/// OSC 2. `title` has no control characters: the Lua strips them.
fn writeTitle(w: *std.Io.Writer, title: []const u8) !void {
    try w.print("\x1b]2;{s}\x1b\\", .{title});
}

/// Rex's default label for window `id`: `Window` and its last 8 characters.
fn defaultWindowLabel(id: []const u8, label: []const u8) bool {
    const prefix = "Window ";
    return id.len >= 8 and std.mem.startsWith(u8, label, prefix) and std.mem.eql(u8, label[prefix.len..], id[id.len - 8 ..]);
}

const testing = std.testing;

test "Rex's default window label" {
    const id = "window:01a1a062-8349-7616-b660-c2da991999f6";
    try testing.expect(defaultWindowLabel(id, "Window 991999f6"));
    try testing.expect(!defaultWindowLabel(id, "Window 12345678"));
    try testing.expect(!defaultWindowLabel(id, "work"));
    try testing.expect(!defaultWindowLabel(id, "Window "));
}

test "a terminal title is OSC 2" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeTitle(&w, "main.zig");
    try testing.expectEqualStrings("\x1b]2;main.zig\x1b\\", w.buffered());
}
