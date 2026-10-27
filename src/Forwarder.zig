//! Turns terminal input into Neovim API calls: keys, pastes, focus and mouse.

const std = @import("std");
const Writer = std.Io.Writer;
const input = @import("input.zig");
const msgpack = @import("msgpack.zig");
const Nvim = @import("Nvim.zig");

const Forwarder = @This();

parser: input.Parser = .{},
/// The next `nvim_paste` phase: 1 starts a paste, 2 continues it.
paste_phase: i64 = 1,

/// Sends the input in `bytes` to Neovim and flushes. False if the user
/// pressed Ctrl+Q to quit.
pub fn feed(self: *Forwarder, nvim: *Nvim, bytes: []const u8) !bool {
    // keys from one read go in one nvim_input
    var keys_buf: [4096]u8 = undefined;
    var keys: Writer = .fixed(&keys_buf);
    self.parser.feed(bytes);
    while (self.parser.next()) |event| switch (event) {
        .key => |k| {
            if (isQuit(k)) return false;
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
            _ = try nvim.request("nvim_ui_set_focus", 1);
            try msgpack.writeBool(nvim.writer(), focused);
        },
        .mouse => |m| if (MouseArgs.from(m)) |args| {
            // keys typed before the click go first
            try sendKeys(nvim, &keys);
            try args.send(nvim);
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

    fn send(self: *const MouseArgs, nvim: *Nvim) !void {
        _ = try nvim.request("nvim_input_mouse", 6);
        const w = nvim.writer();
        try msgpack.writeStr(w, self.button);
        try msgpack.writeStr(w, self.action);
        try msgpack.writeStr(w, self.mods[0..self.mods_len]);
        try msgpack.writeInt(w, 0); // grid 0: no ext_multigrid
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
