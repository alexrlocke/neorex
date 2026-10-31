//! Editor-wide drawing state that every grid shares: highlights, default
//! colors and how the cursor looks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("../nvim/msgpack.zig");
const rpc = @import("../nvim/rpc.zig");

const Style = @This();

/// Highlight attributes by id. Id 0 is the default.
attrs: std.ArrayList(Attr) = .empty,
/// Defaults for colors an `Attr` leaves null.
default_fg: ?u24 = null,
default_bg: ?u24 = null,
default_sp: ?u24 = null,
/// Cursor looks by mode, from `mode_info_set`.
cursor_modes: std.ArrayList(CursorMode) = .empty,
/// False when 'guicursor' is empty: leave the terminal's cursor alone.
cursor_style_enabled: bool = false,
mode_idx: u32 = 0,
/// Between busy_start and busy_stop, the cursor is hidden.
busy: bool = false,
/// Highlights made by blending a float over what's under it, with ids
/// from `blend_base`. Good for one frame: cleared by `clearBlends`.
blended: [max_blended]Blended = undefined,
blended_len: u16 = 0,

/// Ids from here are blended highlights, never Neovim's.
pub const blend_base: u32 = 1 << 31;
const max_blended = 512;

const Blended = struct { front: u32, back: u32, through: bool, attr: Attr };

pub const CursorMode = struct {
    shape: Shape = .block,
    blink: bool = false,

    pub const Shape = enum { block, horizontal, vertical };
};

/// A highlight from `hl_attr_define`. Null colors mean the default.
pub const Attr = struct {
    fg: ?u24 = null,
    bg: ?u24 = null,
    sp: ?u24 = null,
    bold: bool = false,
    italic: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
    dim: bool = false,
    blink: bool = false,
    conceal: bool = false,
    overline: bool = false,
    altfont: bool = false,
    underline: Underline = .none,
    /// 0 to 100.
    blend: u8 = 0,

    pub const Underline = enum { none, single, curl, double, dotted, dashed };
};

pub fn deinit(self: *Style, gpa: Allocator) void {
    self.attrs.deinit(gpa);
    self.cursor_modes.deinit(gpa);
    self.* = undefined;
}

/// Highlight `hl`, or the default for an id never defined.
pub fn attr(self: *const Style, hl: u32) Attr {
    if (hl >= blend_base) {
        const i = hl - blend_base;
        return if (i < self.blended_len) self.blended[i].attr else .{};
    }
    return if (hl < self.attrs.items.len) self.attrs.items[hl] else .{};
}

/// Forgets the blended highlights; call at the start of each frame.
pub fn clearBlends(self: *Style) void {
    self.blended_len = 0;
}

/// Float highlight `front` over `back`, as Neovim's compositor blends them
/// by `front`'s blend. `through`: the float's cell is blank and `back`'s
/// text shows. Just `front` when it doesn't blend or colors are unknown.
pub fn blendOver(self: *Style, front: u32, back: u32, through: bool) u32 {
    const f = self.attr(front);
    if (f.blend == 0) return front;
    for (self.blended[0..self.blended_len], 0..) |b, i| {
        if (b.front == front and b.back == back and b.through == through) return blend_base + @as(u32, @intCast(i));
    }
    if (self.blended_len == max_blended) return front;
    const b = self.attr(back);
    const fbg = f.bg orelse self.default_bg orelse return front;
    // null on a transparent background: it stays transparent
    const bbg = b.bg orelse self.default_bg;
    var a = f;
    if (through) {
        a = b;
        a.fg = mix(f.blend, b.fg orelse self.default_fg orelse return front, fbg);
        if (b.sp) |sp| a.sp = mix(f.blend, sp, fbg);
    }
    a.bg = if (bbg) |bg| mix(f.blend, bg, fbg) else null;
    a.blend = 0;
    self.blended[self.blended_len] = .{ .front = front, .back = back, .through = through, .attr = a };
    self.blended_len += 1;
    return blend_base + self.blended_len - 1;
}

/// `ratio` percent of `back`, the rest `front`, per channel.
fn mix(ratio: u8, back: u24, front: u24) u24 {
    const r: u32 = @min(ratio, 100);
    var out: u24 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const cb: u32 = (back >> shift) & 0xff;
        const cf: u32 = (front >> shift) & 0xff;
        out |= @as(u24, @intCast((r * cb + (100 - r) * cf) / 100)) << shift;
    }
    return out;
}

/// How the cursor should look now; null to leave it alone.
pub fn cursorMode(self: *const Style) ?CursorMode {
    if (!self.cursor_style_enabled or self.mode_idx >= self.cursor_modes.items.len) return null;
    return self.cursor_modes.items[self.mode_idx];
}

pub const Event = enum {
    hl_attr_define,
    default_colors_set,
    mode_info_set,
    mode_change,
    busy_start,
    busy_stop,
};

/// Applies one event's args, after their array header of `len`. Returns
/// how many args it read.
pub fn apply(self: *Style, gpa: Allocator, event: Event, d: *msgpack.Decoder, len: u32) !u32 {
    switch (event) {
        .hl_attr_define => {
            if (len < 2) return error.BadMessage;
            const id = try expectInt(d, u32);
            const a = try readAttr(d);
            if (id >= self.attrs.items.len) try self.attrs.appendNTimes(gpa, .{}, id + 1 - self.attrs.items.len);
            self.attrs.items[id] = a;
            return 2;
        },
        .default_colors_set => {
            if (len < 3) return error.BadMessage;
            self.default_fg = try expectColor(d);
            self.default_bg = try expectColor(d);
            self.default_sp = try expectColor(d);
            return 3;
        },
        .mode_info_set => {
            if (len < 2) return error.BadMessage;
            self.cursor_style_enabled = try rpc.expectBool(d);
            const n = try rpc.expectArray(d);
            self.cursor_modes.clearRetainingCapacity();
            for (0..n) |_| try self.cursor_modes.append(gpa, try readCursorMode(d));
            return 2;
        },
        .mode_change => {
            if (len < 2) return error.BadMessage;
            try rpc.skip(d); // mode name
            self.mode_idx = try expectInt(d, u32);
            return 2;
        },
        .busy_start, .busy_stop => {
            self.busy = event == .busy_start;
            return 0;
        },
    }
}

/// A `mode_info_set` entry. Only shape and blink are used.
fn readCursorMode(d: *msgpack.Decoder) !CursorMode {
    var m: CursorMode = .{};
    var blinkon: i64 = 0;
    var blinkoff: i64 = 0;
    const n = try rpc.expectMap(d);
    for (0..n) |_| {
        const key = try rpc.expectStr(d);
        if (std.mem.eql(u8, key, "cursor_shape")) {
            m.shape = std.meta.stringToEnum(CursorMode.Shape, try rpc.expectStr(d)) orelse .block;
        } else if (std.mem.eql(u8, key, "blinkon")) {
            blinkon = try rpc.expectInt(d);
        } else if (std.mem.eql(u8, key, "blinkoff")) {
            blinkoff = try rpc.expectInt(d);
        } else {
            try rpc.skip(d);
        }
    }
    // as Neovim's TUI decides
    m.blink = blinkon != 0 and blinkoff != 0;
    return m;
}

/// An `rgb_attr` map. Unknown keys, such as `url`, are skipped.
fn readAttr(d: *msgpack.Decoder) !Attr {
    var a: Attr = .{};
    const n = try rpc.expectMap(d);
    for (0..n) |_| {
        const key = std.meta.stringToEnum(AttrKey, try rpc.expectStr(d)) orelse {
            try rpc.skip(d);
            continue;
        };
        switch (key) {
            .foreground => a.fg = try expectColor(d),
            .background => a.bg = try expectColor(d),
            .special => a.sp = try expectColor(d),
            .blend => a.blend = std.math.cast(u8, try rpc.expectInt(d)) orelse return error.BadMessage,
            .bold => a.bold = try rpc.expectBool(d),
            .italic => a.italic = try rpc.expectBool(d),
            .reverse => a.reverse = try rpc.expectBool(d),
            .strikethrough => a.strikethrough = try rpc.expectBool(d),
            .dim => a.dim = try rpc.expectBool(d),
            .blink => a.blink = try rpc.expectBool(d),
            .conceal => a.conceal = try rpc.expectBool(d),
            .overline => a.overline = try rpc.expectBool(d),
            .altfont => a.altfont = try rpc.expectBool(d),
            .underline => if (try rpc.expectBool(d)) {
                a.underline = .single;
            },
            .undercurl => if (try rpc.expectBool(d)) {
                a.underline = .curl;
            },
            .underdouble => if (try rpc.expectBool(d)) {
                a.underline = .double;
            },
            .underdotted => if (try rpc.expectBool(d)) {
                a.underline = .dotted;
            },
            .underdashed => if (try rpc.expectBool(d)) {
                a.underline = .dashed;
            },
        }
    }
    // cterm_attr and info: only RGB is used
    return a;
}

const AttrKey = enum {
    foreground,
    background,
    special,
    blend,
    bold,
    italic,
    reverse,
    strikethrough,
    dim,
    blink,
    conceal,
    overline,
    altfont,
    underline,
    undercurl,
    underdouble,
    underdotted,
    underdashed,
};

fn expectInt(d: *msgpack.Decoder, comptime T: type) !T {
    return std.math.cast(T, try rpc.expectInt(d)) orelse error.BadMessage;
}

/// An RGB color, or null for -1 (unset).
fn expectColor(d: *msgpack.Decoder) !?u24 {
    const n = try rpc.expectInt(d);
    if (n == -1) return null;
    return std.math.cast(u24, n) orelse error.BadMessage;
}

test "a float blends over what's under it" {
    var style: Style = .{ .default_fg = 0xffffff, .default_bg = 0x000000 };
    defer style.deinit(std.testing.allocator);
    try style.attrs.appendSlice(std.testing.allocator, &.{
        .{},
        .{ .bg = 0x000000, .blend = 60 },
        .{ .fg = 0x6464c8, .bg = 0xc86464 },
        .{ .bg = 0x0000ff },
        .{ .fg = 0xaaaaaa },
    });
    // no blend: unchanged
    try std.testing.expectEqual(@as(u32, 3), style.blendOver(3, 2, false));

    const through = style.blendOver(1, 2, true);
    try std.testing.expect(through >= blend_base);
    const t = style.attr(through);
    try std.testing.expectEqual(@as(?u24, 0x3c3c78), t.fg);
    try std.testing.expectEqual(@as(?u24, 0x783c3c), t.bg);
    try std.testing.expectEqual(@as(u8, 0), t.blend);
    // the same pair again: the same id
    try std.testing.expectEqual(through, style.blendOver(1, 2, true));

    const solid = style.attr(style.blendOver(1, 2, false));
    try std.testing.expectEqual(@as(?u24, null), solid.fg);
    try std.testing.expectEqual(@as(?u24, 0x783c3c), solid.bg);

    style.clearBlends();
    try std.testing.expectEqual(@as(u16, 0), style.blended_len);

    // a transparent background: text still dims, the background stays clear
    style.default_bg = null;
    const clear = style.attr(style.blendOver(1, 4, true));
    try std.testing.expectEqual(@as(?u24, 0x666666), clear.fg);
    try std.testing.expectEqual(@as(?u24, null), clear.bg);
}
