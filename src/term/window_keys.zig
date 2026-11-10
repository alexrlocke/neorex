//! Watches the keys typed into a pane for Neovim's `<C-w>` window commands,
//! so neorex can do the same thing to Rex's panes.
//!
//! The keys are still sent to Neovim, which runs the command itself: Neovim
//! keeps deciding what `<C-w>` means (counts, remaps), and neorex only adds
//! the Rex side of the window move. That way `winlayout()` never disagrees
//! with what the panes show.
//!
//! Decoded keys only: paste text and mouse events never reach this, so a
//! `<C-w>H` inside a paste can't move a pane.

const std = @import("std");
const input = @import("input.zig");

const WindowKeys = @This();

/// A split's direction: `vertical` is one above the other, `horizontal` is
/// side by side, as Rex's `resize_pane` names them.
pub const Axis = enum { vertical, horizontal };

pub const Direction = enum { left, right, up, down };

pub const Op = union(enum) {
    /// Put the current block in the place of the block at `direction`'s edge.
    swap: struct { direction: Direction, count: u16 = 1 },
    /// Grow or shrink the current block by `count` cells.
    resize: struct { axis: Axis, grow: bool, count: u16 = 1 },
    /// Give every split in the window an equal share.
    equalize,
};

/// Digits typed before `<C-w>`, as Neovim counts them.
count: u16 = 0,
/// `<C-w>` was the last key, so the next one picks the command.
prefix: bool = false,
/// Ops the caller hasn't taken yet. A single read holds a few keystrokes.
pending: [4]Op = undefined,
pending_len: u8 = 0,
/// Cleared by `NEOREX_WINDOW_KEYS=off`, for users whose own mappings do this.
enabled: bool = true,

pub fn init() WindowKeys {
    return .{ .enabled = enabledFromEnvironment() };
}

fn enabledFromEnvironment() bool {
    const value = std.c.getenv("NEOREX_WINDOW_KEYS") orelse return true;
    const s = std.mem.span(value);
    for ([_][]const u8{ "off", "0", "no", "false" }) |off| {
        if (std.ascii.eqlIgnoreCase(s, off)) return false;
    }
    return true;
}

/// Watches one decoded key.
pub fn observe(self: *WindowKeys, ev: input.KeyEvent) void {
    if (!self.enabled) return;

    if (self.prefix) {
        self.prefix = false;
        const count = @max(self.count, 1);
        self.count = 0;
        if (command(ev, count)) |op| self.push(op);
        return;
    }

    if (isControlW(ev)) {
        self.prefix = true;
        return;
    }
    if (digit(ev)) |d| {
        // 0 is a motion, not a count, as in Neovim
        self.count = if (d == 0) 0 else @min(self.count * 10 + d, 999);
        return;
    }
    self.count = 0;
}

/// The next op the caller hasn't taken, oldest first.
pub fn next(self: *WindowKeys) ?Op {
    if (self.pending_len == 0) return null;
    const op = self.pending[0];
    var i: u8 = 1;
    while (i < self.pending_len) : (i += 1) self.pending[i - 1] = self.pending[i];
    self.pending_len -= 1;
    return op;
}

fn push(self: *WindowKeys, op: Op) void {
    if (self.pending_len == self.pending.len) return; // the next keypress retries
    self.pending[self.pending_len] = op;
    self.pending_len += 1;
}

fn isControlW(ev: input.KeyEvent) bool {
    if (!ev.mods.ctrl or ev.mods.alt or ev.mods.super) return false;
    return switch (ev.key) {
        .codepoint => |cp| cp == 'w',
        .named => false,
    };
}

fn digit(ev: input.KeyEvent) ?u16 {
    if (ev.mods.ctrl or ev.mods.alt or ev.mods.super) return null;
    const cp = switch (ev.key) {
        .codepoint => |c| c,
        .named => return null,
    };
    if (cp < '0' or cp > '9') return null;
    return @intCast(cp - '0');
}

/// The command a key selects after `<C-w>`, if any.
fn command(ev: input.KeyEvent, count: u16) ?Op {
    if (ev.mods.alt or ev.mods.super or ev.mods.ctrl) return null;
    const cp = switch (ev.key) {
        .codepoint => |c| c,
        .named => return null,
    };
    // kitty reports the unshifted key with shift set; a plain terminal sends
    // the shifted character already
    const command_key: u21 = switch (cp) {
        'h', 'j', 'k', 'l' => if (ev.mods.shift) cp - ('a' - 'A') else return null,
        'H', 'J', 'K', 'L' => cp,
        ',', '<' => '<',
        '.', '>' => '>',
        '=' => if (ev.mods.shift) '+' else '=',
        '+', '-' => cp,
        else => return null,
    };
    return switch (command_key) {
        'H' => .{ .swap = .{ .direction = .left, .count = count } },
        'J' => .{ .swap = .{ .direction = .down, .count = count } },
        'K' => .{ .swap = .{ .direction = .up, .count = count } },
        'L' => .{ .swap = .{ .direction = .right, .count = count } },
        '+' => .{ .resize = .{ .axis = .vertical, .grow = true, .count = count } },
        '-' => .{ .resize = .{ .axis = .vertical, .grow = false, .count = count } },
        '>' => .{ .resize = .{ .axis = .horizontal, .grow = true, .count = count } },
        '<' => .{ .resize = .{ .axis = .horizontal, .grow = false, .count = count } },
        '=' => .equalize,
        else => unreachable,
    };
}

const testing = std.testing;

fn key(cp: u21) input.KeyEvent {
    return .{ .key = .{ .codepoint = cp } };
}

fn ctrl(cp: u21) input.KeyEvent {
    return .{ .key = .{ .codepoint = cp }, .mods = .{ .ctrl = true } };
}

fn shift(cp: u21) input.KeyEvent {
    return .{ .key = .{ .codepoint = cp }, .mods = .{ .shift = true } };
}

fn typeKeys(w: *WindowKeys, keys: []const input.KeyEvent) ?Op {
    for (keys) |k| w.observe(k);
    return w.next();
}

test "window swaps" {
    var w: WindowKeys = .{};
    var got = typeKeys(&w, &.{ ctrl('w'), shift('h') });
    try testing.expectEqual(Direction.left, got.?.swap.direction);
    got = typeKeys(&w, &.{ ctrl('w'), shift('j') });
    try testing.expectEqual(Direction.down, got.?.swap.direction);
    got = typeKeys(&w, &.{ ctrl('w'), shift('k') });
    try testing.expectEqual(Direction.up, got.?.swap.direction);
    got = typeKeys(&w, &.{ ctrl('w'), shift('l') });
    try testing.expectEqual(Direction.right, got.?.swap.direction);
}

test "a terminal without kitty sends the same letters unshifted" {
    var w: WindowKeys = .{};
    const got = typeKeys(&w, &.{ ctrl('w'), key('H') });
    try testing.expectEqual(Direction.left, got.?.swap.direction);
}

test "resize keys and their count" {
    var w: WindowKeys = .{};
    var got = typeKeys(&w, &.{ ctrl('w'), key('+') });
    try testing.expectEqual(Axis.vertical, got.?.resize.axis);
    try testing.expect(got.?.resize.grow);
    try testing.expectEqual(@as(u16, 1), got.?.resize.count);

    got = typeKeys(&w, &.{ key('3'), ctrl('w'), key('-') });
    try testing.expectEqual(Axis.vertical, got.?.resize.axis);
    try testing.expect(!got.?.resize.grow);
    try testing.expectEqual(@as(u16, 3), got.?.resize.count);

    got = typeKeys(&w, &.{key('>')});
    try testing.expectEqual(null, got); // not after <C-w>

    got = typeKeys(&w, &.{ ctrl('w'), shift('>') });
    try testing.expectEqual(Axis.horizontal, got.?.resize.axis);
    try testing.expect(got.?.resize.grow);

    got = typeKeys(&w, &.{ ctrl('w'), shift('<') });
    try testing.expect(!got.?.resize.grow);
}

test "equalize" {
    var w: WindowKeys = .{};
    const got = typeKeys(&w, &.{ ctrl('w'), key('=') });
    try testing.expect(got.? == .equalize);
}

test "other <C-w> commands are Neovim's" {
    var w: WindowKeys = .{};
    try testing.expectEqual(null, typeKeys(&w, &.{ ctrl('w'), key('s') }));
    try testing.expectEqual(null, typeKeys(&w, &.{ ctrl('w'), key('v') }));
    try testing.expectEqual(null, typeKeys(&w, &.{ ctrl('w'), key('q') }));
    try testing.expectEqual(null, typeKeys(&w, &.{ ctrl('w'), ctrl('w') }));
}

test "a prefix with nothing after it doesn't stick" {
    var w: WindowKeys = .{};
    try testing.expectEqual(null, typeKeys(&w, &.{ctrl('w')}));
    // the next key is read as a command, not as a new prefix
    try testing.expectEqual(null, typeKeys(&w, &.{key('x')}));
    const got = typeKeys(&w, &.{ ctrl('w'), shift('l') });
    try testing.expectEqual(Direction.right, got.?.swap.direction);
}

test "counts reset when another key comes between" {
    var w: WindowKeys = .{};
    const got = typeKeys(&w, &.{ key('5'), key('j'), ctrl('w'), key('+') });
    try testing.expectEqual(@as(u16, 1), got.?.resize.count);
}

test "typing in insert mode is Neovim's" {
    // the daemon gates on the mode; without <C-w> nothing is produced anyway
    var w: WindowKeys = .{};
    try testing.expectEqual(null, typeKeys(&w, &.{ key('h'), key('j'), key('=') }));
}

test "paste text never reaches the observer" {
    // paste arrives as .paste events, not keys; this documents the boundary
    var w: WindowKeys = .{};
    try testing.expectEqual(null, typeKeys(&w, &.{key('h')}));
}

test "NEOREX_WINDOW_KEYS=off turns it off" {
    var w: WindowKeys = .{ .enabled = false };
    try testing.expectEqual(null, typeKeys(&w, &.{ ctrl('w'), shift('h') }));
    try testing.expectEqual(null, typeKeys(&w, &.{ ctrl('w'), key('+') }));
}
