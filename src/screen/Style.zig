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
    return if (hl < self.attrs.items.len) self.attrs.items[hl] else .{};
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
