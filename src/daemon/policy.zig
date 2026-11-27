//! The daemon's policy: what it does next, decided from its state alone.
//! Each function here reads the panes and what Neovim last drew, updates the
//! daemon's own bookkeeping, and says what to do; Daemon is the mechanism,
//! doing it by talking to Neovim, Rex and the panes' terminals. So the
//! decisions are tested here, with no Neovim or Rex. A subject that grows
//! big enough gets its own file, as sizing.zig is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Pane = @import("Pane.zig");
const Panes = @import("Panes.zig");
const WindowChanges = @import("WindowChanges.zig");
const Grids = @import("screen").Grids;

/// What matching panes to Neovim's windows calls for, after a flush.
pub const Reconcile = struct {
    /// Windows gone from Neovim that had panes: forget their titles.
    gone: std.ArrayList(i64) = .empty,
    /// Panes whose windows closed, highest index first, so each can be
    /// removed in turn: close their Rex blocks and hang them up.
    closed: std.ArrayList(usize) = .empty,
    /// No pane is left: the daemon ends. Nothing below is set.
    stop: bool = false,
    /// Ordinary windows to make external, each asked once.
    adopt: std.ArrayList(i64) = .empty,
    /// External windows with no pane: ask Rex for one each.
    new_pane: std.ArrayList(i64) = .empty,

    pub fn deinit(self: *Reconcile, gpa: Allocator) void {
        self.gone.deinit(gpa);
        self.closed.deinit(gpa);
        self.adopt.deinit(gpa);
        self.new_pane.deinit(gpa);
        self.* = undefined;
    }
};

/// Matches panes to windows: panes whose windows closed hang up, unless the
/// window is reopening, when the pane waits for its replacement; ordinary
/// windows are made external, and external ones get a pane. Marks closed
/// panes `.window_closed` and gives a waiting pane its window.
pub fn reconcile(gpa: Allocator, panes: *Panes, grids: *const Grids, changes: *WindowChanges) !Reconcile {
    var out: Reconcile = .{};
    errdefer out.deinit(gpa);

    var i = panes.list.items.len;
    while (i > 0) {
        i -= 1;
        const p = &panes.list.items[i];
        const win = p.neovim_window_handle orelse continue;
        if (grids.gridOf(win) != null) continue;
        try out.gone.append(gpa, win);
        if (changes.takeReopening(win)) {
            p.neovim_window_handle = null;
            continue;
        }
        p.closing = .window_closed;
        try out.closed.append(gpa, i);
    }
    if (out.closed.items.len == panes.list.items.len) {
        out.stop = true;
        return out;
    }
    changes.forgetGone(grids);

    for (grids.wins.values()) |w| switch (w.kind) {
        .ordinary => if (try changes.shouldAdopt(gpa, w.win)) try out.adopt.append(gpa, w.win),
        .external => {
            changes.becameExternal(w.win);
            if (panes.byWin(w.win) != null or changes.isClosing(w.win)) continue;
            if (waitingPane(panes)) |p| {
                p.neovim_window_handle = w.win;
            } else try out.new_pane.append(gpa, w.win);
        },
        .float, .hidden => {},
    };
    return out;
}

/// A pane kept for a reopened window. Closed panes keep their windows, so
/// they never count.
fn waitingPane(panes: *const Panes) ?*Pane {
    for (panes.list.items) |*p| if (p.layer == null and p.neovim_window_handle == null and p.terminal_surface != null) return p;
    return null;
}

/// What to tell Neovim about focus.
pub const Focus = union(enum) {
    /// Nothing new, or no pane has said.
    none,
    /// Every pane lost focus: wait a moment before saying, as focus moving
    /// between panes arrives as an out, then an in.
    wait,
    /// Whether some pane has focus.
    tell: bool,
};

/// Whether some pane's terminal has focus, against `told`, what Neovim was
/// last told; `waited` once the wait for a loss is over.
pub fn focus(panes: *const Panes, told: bool, waited: bool) Focus {
    var known = false;
    var any = false;
    for (panes.list.items) |p| if (p.terminal_surface) |s| if (s.forwarder.focused) |f| {
        known = true;
        any = any or f;
    };
    if (!known or any == told) return .none;
    if (!any and !waited) return .wait;
    return .{ .tell = any };
}

const testing = std.testing;
const Surface = @import("Surface.zig");

/// A pane in a test: its window (0 for none), whether its terminal is
/// connected, and its terminal's focus.
const TestPane = struct {
    win: i64 = 0,
    connected: bool = true,
    focused: ?bool = null,
};

/// Panes for a test, with stand-in terminals: these decisions only check a
/// pane has one, and read its focus.
const TestPanes = struct {
    panes: Panes = .{},
    surfaces: [8]Surface = undefined,

    fn init(self: *TestPanes, specs: []const TestPane) !void {
        for (specs, 0..) |spec, i| {
            self.surfaces[i] = .{ .helper_socket = undefined, .terminal = undefined };
            self.surfaces[i].forwarder.focused = spec.focused;
            try self.panes.list.append(testing.allocator, .{
                .id = @intCast(i),
                .neovim_window_handle = if (spec.win != 0) spec.win else null,
                .terminal_surface = if (spec.connected) &self.surfaces[i] else null,
            });
        }
    }

    fn deinit(self: *TestPanes) void {
        // not Panes.deinit: the terminals are stand-ins
        self.panes.list.deinit(testing.allocator);
    }

    fn win(self: *const TestPanes, i: usize) ?i64 {
        return self.panes.list.items[i].neovim_window_handle;
    }
};

/// Neovim's windows as a flush left them, one grid each.
fn testGrids(wins: []const Grids.Win) !Grids {
    var grids: Grids = .{};
    errdefer grids.deinit(testing.allocator);
    for (wins, 2..) |w, grid| try grids.wins.put(testing.allocator, @intCast(grid), w);
    return grids;
}

fn ext(win: i64) Grids.Win {
    return .{ .win = win, .kind = .external };
}

test reconcile {
    const cases = [_]struct {
        name: []const u8,
        panes: []const TestPane,
        wins: []const Grids.Win,
        reopening: []const i64 = &.{},
        closing: []const i64 = &.{},
        want_gone: []const i64 = &.{},
        want_closed: []const usize = &.{},
        want_stop: bool = false,
        want_adopt: []const i64 = &.{},
        want_new_pane: []const i64 = &.{},
        /// Each pane's window afterwards; null to skip the check.
        want_wins: ?[]const ?i64 = null,
    }{
        .{
            .name = "every window has its pane: nothing to do",
            .panes = &.{ .{ .win = 1000 }, .{ .win = 1001 } },
            .wins = &.{ ext(1000), ext(1001) },
        },
        .{
            .name = "a pane whose window closed hangs up",
            .panes = &.{ .{ .win = 1000 }, .{ .win = 1001 } },
            .wins = &.{ext(1000)},
            .want_gone = &.{1001},
            .want_closed = &.{1},
        },
        .{
            .name = "closed panes come highest first, to remove in turn",
            .panes = &.{ .{ .win = 1000 }, .{ .win = 1001 }, .{ .win = 1002 }, .{ .win = 1003 } },
            .wins = &.{ext(1002)},
            .want_gone = &.{ 1003, 1001, 1000 },
            .want_closed = &.{ 3, 1, 0 },
        },
        .{
            .name = "the last window closing ends the daemon",
            .panes = &.{ .{ .win = 1000 }, .{ .win = 1001 } },
            .wins = &.{.{ .win = 1004, .kind = .ordinary }},
            .want_gone = &.{ 1001, 1000 },
            .want_closed = &.{ 1, 0 },
            .want_stop = true,
        },
        .{
            .name = "a reopening window's pane waits, and takes its replacement",
            .panes = &.{ .{ .win = 1000 }, .{ .win = 1001 } },
            .wins = &.{ ext(1000), ext(1002) },
            .reopening = &.{1001},
            .want_gone = &.{1001},
            .want_wins = &.{ 1000, 1002 },
        },
        .{
            .name = "a waiting pane with no terminal yet takes nothing",
            .panes = &.{ .{ .win = 1000 }, .{ .connected = false } },
            .wins = &.{ ext(1000), ext(1002) },
            .want_new_pane = &.{1002},
            .want_wins = &.{ 1000, null },
        },
        .{
            .name = "one waiting pane: the first new window takes it, the next gets a new pane",
            .panes = &.{ .{ .win = 1000 }, .{} },
            .wins = &.{ ext(1000), ext(1002), ext(1003) },
            .want_new_pane = &.{1003},
            .want_wins = &.{ 1000, 1002 },
        },
        .{
            .name = "new ordinary windows are made external; new external ones get panes",
            .panes = &.{.{ .win = 1000 }},
            .wins = &.{ ext(1000), .{ .win = 1002, .kind = .ordinary }, ext(1003) },
            .want_adopt = &.{1002},
            .want_new_pane = &.{1003},
        },
        .{
            .name = "a window we're closing gets no pane",
            .panes = &.{.{ .win = 1000 }},
            .wins = &.{ ext(1000), ext(1002) },
            .closing = &.{1002},
        },
        .{
            .name = "floats and windows on other tabs get nothing",
            .panes = &.{.{ .win = 1000 }},
            .wins = &.{ ext(1000), .{ .win = 1002, .kind = .float }, .{ .win = 1003, .kind = .hidden } },
        },
    };
    for (cases) |c| {
        errdefer std.debug.print("case: {s}\n", .{c.name});
        const gpa = testing.allocator;
        var tp: TestPanes = .{};
        defer tp.deinit();
        try tp.init(c.panes);
        var grids = try testGrids(c.wins);
        defer grids.deinit(gpa);
        var changes: WindowChanges = .{};
        defer changes.deinit(gpa);
        for (c.reopening) |w| try changes.markReopening(gpa, w);
        for (c.closing) |w| try changes.markClosing(gpa, w);

        var r = try reconcile(gpa, &tp.panes, &grids, &changes);
        defer r.deinit(gpa);

        try testing.expectEqualSlices(i64, c.want_gone, r.gone.items);
        try testing.expectEqualSlices(usize, c.want_closed, r.closed.items);
        try testing.expectEqual(c.want_stop, r.stop);
        try testing.expectEqualSlices(i64, c.want_adopt, r.adopt.items);
        try testing.expectEqualSlices(i64, c.want_new_pane, r.new_pane.items);
        for (c.want_closed) |i| try testing.expectEqual(Pane.Close.window_closed, tp.panes.list.items[i].closing.?);
        if (c.want_wins) |want| for (want, 0..) |w, i| try testing.expectEqual(w, tp.win(i));
    }
}

test "reconcile: an ordinary window is asked to become external once" {
    const gpa = testing.allocator;
    var tp: TestPanes = .{};
    defer tp.deinit();
    try tp.init(&.{.{ .win = 1000 }});
    var grids = try testGrids(&.{ ext(1000), .{ .win = 1002, .kind = .ordinary } });
    defer grids.deinit(gpa);
    var changes: WindowChanges = .{};
    defer changes.deinit(gpa);

    var first = try reconcile(gpa, &tp.panes, &grids, &changes);
    defer first.deinit(gpa);
    try testing.expectEqualSlices(i64, &.{1002}, first.adopt.items);

    // the next flush, before Neovim has done it
    var again = try reconcile(gpa, &tp.panes, &grids, &changes);
    defer again.deinit(gpa);
    try testing.expectEqualSlices(i64, &.{}, again.adopt.items);
}

test focus {
    const cases = [_]struct {
        name: []const u8,
        focused: []const ?bool,
        told: bool,
        waited: bool = false,
        want: Focus,
    }{
        .{ .name = "no pane has said", .focused = &.{ null, null }, .told = true, .want = .none },
        .{ .name = "as Neovim was told", .focused = &.{ true, false }, .told = true, .want = .none },
        .{ .name = "a pane gained focus", .focused = &.{ false, true }, .told = false, .want = .{ .tell = true } },
        .{ .name = "every pane lost it: wait", .focused = &.{ false, null }, .told = true, .want = .wait },
        .{ .name = "every pane lost it, and the wait is over", .focused = &.{ false, false }, .told = true, .waited = true, .want = .{ .tell = false } },
        .{ .name = "another pane gained it during the wait", .focused = &.{ false, true }, .told = true, .waited = true, .want = .none },
    };
    for (cases) |c| {
        errdefer std.debug.print("case: {s}\n", .{c.name});
        var specs: [8]TestPane = undefined;
        for (c.focused, 0..) |f, i| specs[i] = .{ .win = 1000 + @as(i64, @intCast(i)), .focused = f };
        var tp: TestPanes = .{};
        defer tp.deinit();
        try tp.init(specs[0..c.focused.len]);
        try testing.expectEqual(c.want, focus(&tp.panes, c.told, c.waited));
    }
}
