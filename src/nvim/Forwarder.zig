//! Turns terminal input into Neovim API calls: keys, pastes, focus and mouse.

const std = @import("std");
const Writer = std.Io.Writer;
const input = @import("../term/input.zig");
const msgpack = @import("msgpack.zig");
const Nvim = @import("Nvim.zig");

const Forwarder = @This();

parser: input.Parser = .{},
/// The next `nvim_paste` phase: 1 starts a paste, 2 continues it.
paste_phase: i64 = 1,
/// For the debug commands; the real editor gives Ctrl+Q to Neovim.
ctrl_q_quits: bool = true,
/// The grid mouse events land on; 0 without ext_multigrid.
grid: u32 = 0,
/// Floats drawn over the terminal, lowest first: mouse events on one go
/// to its grid.
targets: [max_targets]Target = undefined,
targets_len: u8 = 0,
/// The float a button went down on: its drags and release go there too.
grab: ?Target = null,
/// Off when the caller tells Neovim about focus itself, from `focused`.
send_focus: bool = true,
/// The last focus report seen.
focused: ?bool = null,

/// A float's grid and where it's drawn, in terminal cells.
pub const Target = struct { grid: u32, row: i32, col: i32, width: u32, height: u32 };

pub const max_targets = 16;

pub fn setTargets(self: *Forwarder, targets: []const Target) void {
    const n = @min(targets.len, max_targets);
    @memcpy(self.targets[0..n], targets[0..n]);
    self.targets_len = @intCast(n);
}

/// The grid a mouse event lands on, and where on it.
fn route(self: *Forwarder, m: input.Mouse) struct { grid: u32, row: u16, col: u16 } {
    const held = m.action == .drag or m.action == .release;
    const hit: ?Target = if (held and self.grab != null) self.grab else for (0..self.targets_len) |j| {
        const t = self.targets[self.targets_len - 1 - j];
        if (m.row >= t.row and m.row < @as(i64, t.row) + t.height and m.col >= t.col and m.col < @as(i64, t.col) + t.width) break t;
    } else null;
    if (m.action == .press and m.button != .wheel_up and m.button != .wheel_down) self.grab = hit;
    if (m.action == .release) self.grab = null;
    const t = hit orelse return .{ .grid = self.grid, .row = m.row, .col = m.col };
    return .{
        .grid = t.grid,
        .row = @intCast(std.math.clamp(@as(i64, m.row) - t.row, 0, std.math.maxInt(u16))),
        .col = @intCast(std.math.clamp(@as(i64, m.col) - t.col, 0, std.math.maxInt(u16))),
    };
}

/// Sends the input in `bytes` to Neovim and flushes. False if the user
/// pressed Ctrl+Q to quit and `ctrl_q_quits` is set.
pub fn feed(self: *Forwarder, nvim: *Nvim, bytes: []const u8) !bool {
    // keys from one read go in one nvim_input
    var keys_buf: [4096]u8 = undefined;
    var keys: Writer = .fixed(&keys_buf);
    self.parser.feed(bytes);
    while (self.parser.next()) |event| switch (event) {
        .key => |k| {
            if (self.ctrl_q_quits and isQuit(k)) return false;
            // room for the longest key name
            if (keys.unusedCapacityLen() < 32) try sendKeys(nvim, &keys);
            try input.writeNvim(k, &keys);
        },
        .paste_start => self.paste_phase = 1,
        .paste => |text| {
            try sendKeys(nvim, &keys);
            try paste(nvim, text, self.paste_phase);
            self.paste_phase = 2;
        },
        .paste_end => if (self.paste_phase == 2) try paste(nvim, "", 3),
        .focus => |focused| {
            self.focused = focused;
            if (self.send_focus) {
                _ = try nvim.request("nvim_ui_set_focus", 1);
                try msgpack.writeBool(nvim.writer(), focused);
            }
        },
        .mouse => |m| if (MouseArgs.from(m)) |found| {
            // keys typed before the click go first
            try sendKeys(nvim, &keys);
            var args = found;
            const to = self.route(m);
            args.row = to.row;
            args.col = to.col;
            try args.send(nvim, to.grid);
        },
        .unknown => {},
    };
    try sendKeys(nvim, &keys);
    try nvim.flush();
    return true;
}

/// Sends buffered keys with `nvim_input`, then empties the buffer.
fn sendKeys(nvim: *Nvim, keys: *Writer) !void {
    if (keys.end == 0) return;
    _ = try nvim.request("nvim_input", 1);
    try msgpack.writeStr(nvim.writer(), keys.buffered());
    keys.end = 0;
}

/// One piece of a streamed `nvim_paste`. Terminals send newlines as CR.
fn paste(nvim: *Nvim, text: []const u8, phase: i64) !void {
    _ = try nvim.request("nvim_paste", 3);
    const w = nvim.writer();
    try msgpack.writeStrHeader(w, std.math.cast(u32, text.len) orelse return error.TooLong);
    for (text) |c| try w.writeByte(if (c == '\r') '\n' else c);
    try msgpack.writeBool(w, true); // crlf: drop any \r\n's \r
    try msgpack.writeInt(w, phase);
}

/// `nvim_input_mouse`'s arguments for a terminal mouse event.
const MouseArgs = struct {
    button: []const u8,
    action: []const u8,
    mods: [8]u8,
    mods_len: u8,
    row: u16,
    col: u16,

    /// Null for events Neovim has no name for.
    fn from(m: input.Mouse) ?MouseArgs {
        const button: []const u8, const action: []const u8 = switch (m.button) {
            .left, .middle, .right => .{ @tagName(m.button), switch (m.action) {
                .press => "press",
                .drag => "drag",
                .release => "release",
                .motion => return null,
            } },
            .wheel_up => .{ "wheel", "up" },
            .wheel_down => .{ "wheel", "down" },
            .wheel_left => .{ "wheel", "left" },
            .wheel_right => .{ "wheel", "right" },
            .none => if (m.action == .motion) .{ "move", "" } else return null,
        };
        var a: MouseArgs = .{ .button = button, .action = action, .mods = undefined, .mods_len = 0, .row = m.row, .col = m.col };
        // as in key names: C-A-S-D-
        for ([_]struct { bool, u8 }{ .{ m.mods.ctrl, 'C' }, .{ m.mods.alt, 'A' }, .{ m.mods.shift, 'S' }, .{ m.mods.super, 'D' } }) |mod| {
            if (!mod[0]) continue;
            a.mods[a.mods_len] = mod[1];
            a.mods[a.mods_len + 1] = '-';
            a.mods_len += 2;
        }
        return a;
    }

    fn send(self: *const MouseArgs, nvim: *Nvim, grid: u32) !void {
        _ = try nvim.request("nvim_input_mouse", 6);
        const w = nvim.writer();
        try msgpack.writeStr(w, self.button);
        try msgpack.writeStr(w, self.action);
        try msgpack.writeStr(w, self.mods[0..self.mods_len]);
        try msgpack.writeInt(w, grid);
        try msgpack.writeInt(w, self.row);
        try msgpack.writeInt(w, self.col);
    }
};

fn isQuit(k: input.KeyEvent) bool {
    return k.mods.ctrl and !k.mods.alt and k.key == .codepoint and k.key.codepoint == 'q';
}

test "mouse events become nvim_input_mouse args" {
    const t = std.testing;
    const drag = MouseArgs.from(.{ .button = .left, .action = .drag, .mods = .{ .ctrl = true, .shift = true }, .row = 3, .col = 7 }).?;
    try t.expectEqualStrings("left", drag.button);
    try t.expectEqualStrings("drag", drag.action);
    try t.expectEqualStrings("C-S-", drag.mods[0..drag.mods_len]);
    try t.expectEqual(@as(u16, 3), drag.row);

    const wheel = MouseArgs.from(.{ .button = .wheel_down, .action = .press, .row = 0, .col = 0 }).?;
    try t.expectEqualStrings("wheel", wheel.button);
    try t.expectEqualStrings("down", wheel.action);
    try t.expectEqualStrings("", wheel.mods[0..wheel.mods_len]);

    const move = MouseArgs.from(.{ .button = .none, .action = .motion, .row = 1, .col = 1 }).?;
    try t.expectEqualStrings("move", move.button);
    try t.expectEqual(@as(?MouseArgs, null), MouseArgs.from(.{ .button = .none, .action = .release, .row = 0, .col = 0 }));
}

test "mouse events on a float go to its grid" {
    const t = std.testing;
    var f: Forwarder = .{ .grid = 2 };
    f.setTargets(&.{
        .{ .grid = 3, .row = 1, .col = 1, .width = 10, .height = 5 },
        // above the first
        .{ .grid = 4, .row = 2, .col = 2, .width = 3, .height = 1 },
    });
    const off = f.route(.{ .button = .left, .action = .press, .row = 0, .col = 0 });
    try t.expectEqual(@as(u32, 2), off.grid);
    try t.expectEqual(@as(u16, 0), off.row);
    _ = f.route(.{ .button = .left, .action = .release, .row = 0, .col = 0 });

    const top = f.route(.{ .button = .left, .action = .press, .row = 2, .col = 3 });
    try t.expectEqual(@as(u32, 4), top.grid);
    try t.expectEqual(@as(u16, 0), top.row);
    try t.expectEqual(@as(u16, 1), top.col);
    // dragged off it: still that grid, clamped
    const drag = f.route(.{ .button = .left, .action = .drag, .row = 0, .col = 9 });
    try t.expectEqual(@as(u32, 4), drag.grid);
    try t.expectEqual(@as(u16, 0), drag.row);
    try t.expectEqual(@as(u16, 7), drag.col);
    _ = f.route(.{ .button = .left, .action = .release, .row = 0, .col = 9 });
    try t.expectEqual(@as(?Target, null), f.grab);

    const under = f.route(.{ .button = .wheel_down, .action = .press, .row = 4, .col = 1 });
    try t.expectEqual(@as(u32, 3), under.grid);
    try t.expectEqual(@as(u16, 3), under.row);
}
