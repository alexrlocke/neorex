//! Links a Rex pane to a Neovim window. The three parts arrive in any
//! order. A plain value: only the Surface needs a stable address.

const std = @import("std");
const Surface = @import("Surface.zig");
const Loop = @import("Loop.zig");

const Pane = @This();

/// Matches a helper's hello. 0 is the startup pane.
id: u32,
rex_block: ?RexBlock = null,
/// Null while a replacement window opens.
neovim_window_handle: ?NeovimWindowHandle = null,
/// Owned.
terminal_surface: ?*Surface = null,
closing: ?Close = null,
last_asked_win_size: struct { grid: u32 = 0, cols: u32 = 0, rows: u32 = 0 } = .{},

/// Never 0: Neovim's API reads 0 as the current window.
pub const NeovimWindowHandle = i64;

/// `block:` and a UUID.
pub const RexBlock = [42]u8;

pub fn rexBlock(id: []const u8) error{BadRexBlock}!RexBlock {
    if (id.len != 42) return error.BadRexBlock;
    return id[0..42].*;
}

pub const Close = enum {
    /// The terminal is already gone, so it isn't restored.
    rex_pane_closed,
    window_closed,
    request_failed,
    shutdown,
};

/// e.g. `<C-w>v`.
pub fn fromNeovimWindow(id: u32, window_handle: NeovimWindowHandle) Pane {
    std.debug.assert(window_handle != 0);
    return .{ .id = id, .neovim_window_handle = window_handle };
}

/// e.g. Cmd+D. Not used yet.
pub fn fromRexPane(id: u32, block: RexBlock, surface: *Surface) Pane {
    return .{ .id = id, .rex_block = block, .terminal_surface = surface };
}

/// The pane `neorex` was run in. `block` is null without REX_BLOCK.
pub fn startup(block: ?RexBlock, surface: *Surface) Pane {
    return .{ .id = 0, .rex_block = block, .terminal_surface = surface };
}

/// Needs no Rex block: drawing only uses the terminal.
pub fn drawable(self: Pane) bool {
    return self.neovim_window_handle != null and
        self.terminal_surface != null and
        self.closing == null;
}

pub const Part = enum { rex_block, terminal_surface, neovim_window };

pub fn missing(self: Pane) std.EnumSet(Part) {
    return .init(.{
        .rex_block = self.rex_block == null,
        .terminal_surface = self.terminal_surface == null,
        .neovim_window = self.neovim_window_handle == null,
    });
}

/// Above Daemon's fixed tokens, so they never clash.
pub const token_base = 8;

pub const PaneFd = enum(u1) { helper_socket, terminal };

/// Holds the pane id, not a pointer, so a stale event can't reach a freed pane.
pub fn token(self: *const Pane, source_fd: PaneFd) usize {
    return token_base + 2 * @as(usize, self.id) + @backingInt(source_fd);
}

/// The pane may be gone; look it up by id.
pub fn fromToken(t: usize) struct { id: u32, source_fd: PaneFd } {
    return .{
        .id = @intCast((t - token_base) / 2),
        .source_fd = @fromBackingInt(@intCast((t - token_base) % 2)),
    };
}

/// Hanging up makes the helper exit, and Rex closes the pane.
pub fn deinit(self: *Pane, gpa: std.mem.Allocator, io: std.Io) void {
    if (self.terminal_surface) |surface| {
        surface.destroy(gpa, io, self.closing != .rex_pane_closed);
    }
    self.* = undefined;
}

/// Give helper and terminal fds to the loop
pub fn registerWith(self: *Pane, loop: *Loop) !void {
    const surface = self.terminal_surface.?;
    try loop.addRead(surface.helper_socket.socket.handle, self.token(.helper_socket));
    try loop.addRead(surface.terminal.fd, self.token(.terminal));
}

const testing = std.testing;
const test_id = "block:01a17fb6-c5b4-7d9c-8e1e-9fd2a65e8a50";
const test_block: RexBlock = test_id[0..42].*;

// Panes below point at a Surface that's never touched, so never deinit them.

test "each constructor starts with the parts it was given" {
    var surface: Surface = undefined;

    const from_window = fromNeovimWindow(3, 1000);
    try testing.expectEqual(@as(u32, 3), from_window.id);
    try testing.expectEqual(@as(i64, 1000), from_window.neovim_window_handle.?);
    try testing.expect(from_window.missing().eql(.initMany(&.{ .rex_block, .terminal_surface })));

    const from_rex = fromRexPane(4, test_block, &surface);
    try testing.expectEqual(@as(u32, 4), from_rex.id);
    try testing.expect(from_rex.missing().eql(.initOne(.neovim_window)));

    const at_startup = startup(test_block, &surface);
    try testing.expectEqual(@as(u32, 0), at_startup.id);
    try testing.expect(at_startup.missing().eql(.initOne(.neovim_window)));

    const without_block = startup(null, &surface);
    try testing.expect(without_block.missing().eql(.initMany(&.{ .rex_block, .neovim_window })));
}

test "missing and drawable, for every mix of parts" {
    var surface: Surface = undefined;
    for (0..8) |bits| {
        const has_block = (bits & 1) != 0;
        const has_surface = (bits & 2) != 0;
        const has_window = (bits & 4) != 0;
        const pane: Pane = .{
            .id = 1,
            .rex_block = if (has_block) test_block else null,
            .terminal_surface = if (has_surface) &surface else null,
            .neovim_window_handle = if (has_window) 1000 else null,
        };

        var want: std.EnumSet(Part) = .empty;
        if (!has_block) want.insert(.rex_block);
        if (!has_surface) want.insert(.terminal_surface);
        if (!has_window) want.insert(.neovim_window);
        try testing.expect(pane.missing().eql(want));

        // the block doesn't matter
        try testing.expectEqual(has_surface and has_window, pane.drawable());
    }
}

test "a closing pane isn't drawable, whatever the reason" {
    var surface: Surface = undefined;
    for (std.enums.values(Close)) |reason| {
        const pane: Pane = .{
            .id = 1,
            .rex_block = test_block,
            .terminal_surface = &surface,
            .neovim_window_handle = 1000,
            .closing = reason,
        };
        try testing.expect(!pane.drawable());
    }
}

test "rexBlock takes 42-byte ids only" {
    const block = try rexBlock(test_id);
    try testing.expectEqualStrings(test_id, &block);
    try testing.expectError(error.BadRexBlock, rexBlock(test_id[0..41]));
    try testing.expectError(error.BadRexBlock, rexBlock(test_id ++ "0"));
    try testing.expectError(error.BadRexBlock, rexBlock(""));
}

test "tokens round-trip and never collide" {
    for ([_]u32{ 0, 1, 7, 100_000 }) |id| {
        const pane: Pane = .{ .id = id };
        for (std.enums.values(PaneFd)) |fd| {
            const t = pane.token(fd);
            try testing.expect(t >= token_base);
            const back = fromToken(t);
            try testing.expectEqual(id, back.id);
            try testing.expectEqual(fd, back.source_fd);
        }
        try testing.expect(pane.token(.helper_socket) != pane.token(.terminal));
        // the next pane's tokens start after this one's
        const next: Pane = .{ .id = id + 1 };
        try testing.expect(next.token(.helper_socket) > pane.token(.terminal));
    }
}
