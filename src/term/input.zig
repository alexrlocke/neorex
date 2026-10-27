//! AI Generated, needs to be done properly
//! Terminal input: turns the bytes a terminal sends into events.
//!
//! Keys arrive in a few shapes:
//!
//!   a, é, 漢         the character itself (UTF-8, 1 to 4 bytes)
//!   Enter, Tab       single control bytes: 0x0d, 0x09
//!   Ctrl+A .. Ctrl+Z control bytes 0x01 .. 0x1a
//!   Escape           0x1b on its own
//!   Alt+x            0x1b then x
//!   Up, Ctrl+Right   CSI sequences: ESC [ params final, e.g. ESC [ 1 ; 5 C
//!   Delete, F5       CSI ... ~ : ESC [ 3 ~, ESC [ 1 5 ~
//!   F1 (some terms)  SS3 sequences: ESC O P
//!
//! That "legacy" encoding loses information: Ctrl+I and Tab are the same byte,
//! and a lone ESC could be the Escape key or the start of a sequence. The
//! kitty keyboard protocol fixes this. Write `kitty_push` to turn it on and
//! `kitty_pop` to turn it off. While it's on, any key the legacy encoding
//! would garble arrives as a "CSI u" sequence instead:
//!
//!   ESC [ code : shifted ; mods : event u
//!
//!   Escape           ESC [ 27 u
//!   Ctrl+I           ESC [ 105 ; 5 u        (Tab is still 0x09)
//!   Alt+Shift+1      ESC [ 49 : 33 ; 4 u    (33 is '!')
//!
//! Plain typing, arrows and F-keys keep their legacy forms, so the parser
//! handles both. Spec: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
//!
//! The parser is a small state machine fed one byte at a time, in the style of
//! Ghostty's VT parser (which follows vt100.net/emu/dec_ansi_parser). Its state
//! survives between reads, so a sequence split across two reads just carries
//! on where it left off.
//!
//! Usage:
//!
//!     var parser: Parser = .{};
//!     parser.feed(bytes_from_read);
//!     while (parser.next()) |event| { ... }

const std = @import("std");

/// Turns the kitty keyboard protocol on, with flags 1 (disambiguate: use CSI u
/// for keys the legacy encoding garbles) and 4 (report the shifted key, so
/// Alt+Shift+1 can be `<M-!>`). The terminal keeps a stack of flags, one per
/// screen (main and alternate), so push after switching screens.
pub const kitty_push = "\x1b[>5u";
/// Turns it back off: pops what `kitty_push` pushed.
pub const kitty_pop = "\x1b[<u";

/// Modifier keys held with a key or mouse event.
pub const Mods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    _padding: u4 = 0,

    /// From the modifier parameter in sequences like `ESC [ 1 ; 5 C`. The
    /// value minus one is a set of bits: 1 shift, 2 alt, 4 ctrl, 8 super.
    /// Higher bits (hyper, meta, caps lock, num lock) are ignored.
    pub fn fromParam(param: u32) Mods {
        if (param <= 1) return .{};
        const bits = param - 1;
        return .{
            .shift = bits & 1 != 0,
            .alt = bits & 2 != 0,
            .ctrl = bits & 4 != 0,
            .super = bits & 8 != 0,
        };
    }

    pub fn isEmpty(self: Mods) bool {
        return !self.shift and !self.alt and !self.ctrl and !self.super;
    }
};

/// Keys that aren't characters.
pub const Named = enum {
    enter,
    tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    insert,
    delete,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

/// Which key: a character, or a named key.
pub const Key = union(enum) {
    /// A character, as a Unicode codepoint. Ctrl+A is `'a'` with `ctrl` set.
    codepoint: u21,
    named: Named,
};

pub const KeyEvent = struct {
    key: Key,
    mods: Mods = .{},
};

pub const Mouse = struct {
    pub const Button = enum { left, middle, right, none, wheel_up, wheel_down, wheel_left, wheel_right };
    pub const Action = enum { press, release, drag, motion };

    button: Button,
    action: Action,
    mods: Mods = .{},
    /// The cell under the pointer, counting from 0.
    row: u16,
    col: u16,
};

pub const Event = union(enum) {
    key: KeyEvent,
    /// Bracketed paste: `paste_start`, then the text in one or more `paste`
    /// chunks, then `paste_end`. Pasted text never turns into key events.
    paste_start,
    /// Pasted text. Points into the bytes given to `feed` (or the parser's
    /// own memory), so it is only valid until the next `next` or `feed`.
    paste: []const u8,
    paste_end,
    /// The terminal gained (`true`) or lost (`false`) focus.
    focus: bool,
    mouse: Mouse,
    /// A sequence the parser doesn't know, as raw bytes. Valid until the next
    /// `next` or `feed`.
    unknown: []const u8,

    /// For printing with `{f}`, e.g. in `debug-keys`.
    pub fn format(self: Event, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .key => |k| {
                try w.writeAll("key ");
                try writeNvim(k, w);
            },
            .paste_start => try w.writeAll("paste start"),
            .paste => |text| try w.print("paste \"{f}\"", .{std.ascii.hexEscape(text, .lower)}),
            .paste_end => try w.writeAll("paste end"),
            .focus => |in| try w.writeAll(if (in) "focus in" else "focus out"),
            .mouse => |m| {
                try w.print("mouse {s} {s} row={d} col={d}", .{ @tagName(m.button), @tagName(m.action), m.row, m.col });
                if (!m.mods.isEmpty()) try writeMods(m.mods, w);
            },
            .unknown => |bytes| try w.print("unknown \"{f}\"", .{std.ascii.hexEscape(bytes, .lower)}),
        }
    }
};

/// True if `bytes` hold nothing but focus reports (`CSI I`, `CSI O`).
pub fn onlyFocusReports(bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        if (!std.mem.startsWith(u8, rest, "\x1b[I") and !std.mem.startsWith(u8, rest, "\x1b[O")) return false;
        rest = rest[3..];
    }
    return true;
}

test "focus reports alone" {
    try std.testing.expect(onlyFocusReports("\x1b[O"));
    try std.testing.expect(onlyFocusReports("\x1b[I\x1b[O"));
    try std.testing.expect(!onlyFocusReports("\x1b[Ia"));
    try std.testing.expect(!onlyFocusReports("\x1b[A"));
}

/// Writes a key in Neovim's key notation, the form `nvim_input` takes:
/// `a`, `<lt>`, `<CR>`, `<C-Right>`, `<M-x>`, `<C-Space>`.
pub fn writeNvim(event: KeyEvent, w: *std.Io.Writer) std.Io.Writer.Error!void {
    // Keys that need a name inside <...>.
    const name: ?[]const u8 = switch (event.key) {
        .named => |n| nvimName(n),
        .codepoint => |cp| switch (cp) {
            '<' => "lt", // a bare < would start a key name
            ' ' => if (event.mods.isEmpty()) null else "Space",
            else => null,
        },
    };
    const bracket = name != null or !event.mods.isEmpty();
    if (bracket) try w.writeByte('<');
    if (event.mods.ctrl) try w.writeAll("C-");
    if (event.mods.alt) try w.writeAll("M-");
    if (event.mods.shift) try w.writeAll("S-");
    if (event.mods.super) try w.writeAll("D-");
    if (name) |n| {
        try w.writeAll(n);
    } else {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(event.key.codepoint, &buf) catch blk: {
            // Not encodable (a lone surrogate): send U+FFFD instead.
            buf[0..3].* = "\u{fffd}".*;
            break :blk 3;
        };
        try w.writeAll(buf[0..len]);
    }
    if (bracket) try w.writeByte('>');
}

fn nvimName(n: Named) []const u8 {
    return switch (n) {
        .enter => "CR",
        .tab => "Tab",
        .backspace => "BS",
        .escape => "Esc",
        .up => "Up",
        .down => "Down",
        .left => "Left",
        .right => "Right",
        .home => "Home",
        .end => "End",
        .insert => "Insert",
        .delete => "Del",
        .page_up => "PageUp",
        .page_down => "PageDown",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
    };
}

fn writeMods(m: Mods, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(" (");
    var first = true;
    inline for (.{ "ctrl", "alt", "shift", "super" }) |field| {
        if (@field(m, field)) {
            if (!first) try w.writeByte('+');
            try w.writeAll(field);
            first = false;
        }
    }
    try w.writeByte(')');
}

pub const Parser = struct {
    const max_params = 16;
    const max_sequence = 64;

    const State = enum {
        /// Between keys.
        ground,
        /// Partway through a multi-byte UTF-8 character.
        utf8,
        /// Just read ESC.
        escape,
        /// Inside ESC [ ... (a CSI sequence), reading parameters.
        csi,
        /// Just read ESC O (an SS3 sequence); the next byte finishes it.
        ss3,
        /// Inside ESC ] ... (an OSC string): terminal replies, not keys.
        osc,
        /// Read ESC inside an OSC string: `\` ends it.
        osc_escape,
    };

    state: State = .ground,

    /// The bytes from the last `feed`, and how far through them we are.
    input: []const u8 = "",
    pos: usize = 0,

    /// The escape sequence being read, for `unknown` events and pastes.
    sequence: [max_sequence]u8 = undefined,
    sequence_len: usize = 0,

    /// CSI parameters, in order. `ESC [ 1 ; 5 C` has the values 1 and 5.
    /// Parameters can have sub-parameters after a `:`, as in kitty's
    /// `ESC [ 49 : 33 ; 4 u`: those are stored in the same list, with their
    /// bit set in `is_sub`. So that one is 49, 33 (sub), 4. Use `field` to
    /// read them.
    params: [max_params]u32 = undefined,
    is_sub: std.bit_set.IntegerBitSet(max_params) = .empty,
    param_count: usize = 0,
    /// The value being read, whether it has any digits yet, and whether a
    /// `:` came before it.
    current: u32 = 0,
    has_current: bool = false,
    current_is_sub: bool = false,
    /// A marker right after `ESC [`, such as `<` for SGR mouse reports.
    marker: u8 = 0,

    /// A UTF-8 character being collected, and how many bytes it still needs.
    codepoint: u21 = 0,
    utf8_left: u3 = 0,

    /// A lone ESC was followed by a key: that key gets Alt.
    alt: bool = false,
    /// Inside a bracketed paste.
    in_paste: bool = false,

    /// Give the parser the bytes from one read. Call `next` until it returns
    /// null before feeding more.
    pub fn feed(self: *Parser, bytes: []const u8) void {
        std.debug.assert(self.pos >= self.input.len);
        self.input = bytes;
        self.pos = 0;
    }

    /// The next event from the fed bytes, or null when they are used up.
    pub fn next(self: *Parser) ?Event {
        while (self.pos < self.input.len) {
            // Inside a paste, plain bytes pass through in runs; only ESC
            // (which might start the end-of-paste marker) needs a closer look.
            if (self.in_paste and self.state == .ground) {
                const rest = self.input[self.pos..];
                const run = std.mem.indexOfScalar(u8, rest, 0x1b) orelse rest.len;
                if (run > 0) {
                    self.pos += run;
                    return .{ .paste = rest[0..run] };
                }
            }
            const byte = self.input[self.pos];
            self.pos += 1;
            if (self.step(byte)) |event| return event;
        }
        // The read ended right after an ESC. Escape sequences arrive in one
        // read, so this was the Escape key itself.
        if (self.state == .escape) {
            self.state = .ground;
            if (self.in_paste) return .{ .paste = "\x1b" };
            return self.keyEvent(.{ .named = .escape }, .{});
        }
        return null;
    }

    /// Advance the state machine by one byte; returns an event if one
    /// finished.
    fn step(self: *Parser, byte: u8) ?Event {
        switch (self.state) {
            .ground => return self.ground(byte),
            .utf8 => {
                if (byte & 0xc0 != 0x80) {
                    // Not a continuation byte: the character was cut short.
                    // Report that, then read this byte again from `ground`.
                    self.state = .ground;
                    self.pos -= 1;
                    return self.keyEvent(.{ .codepoint = std.unicode.replacement_character }, .{});
                }
                self.codepoint = (self.codepoint << 6) | (byte & 0x3f);
                self.utf8_left -= 1;
                if (self.utf8_left > 0) return null;
                self.state = .ground;
                return self.keyEvent(.{ .codepoint = self.codepoint }, .{});
            },
            .escape => {
                switch (byte) {
                    '[' => {
                        self.record(byte);
                        self.state = .csi;
                        self.param_count = 0;
                        self.is_sub = .empty;
                        self.current = 0;
                        self.has_current = false;
                        self.current_is_sub = false;
                        self.marker = 0;
                    },
                    'O' => {
                        self.record(byte);
                        self.state = .ss3;
                    },
                    ']' => {
                        self.record(byte);
                        self.state = .osc;
                    },
                    0x1b => {
                        // Two ESCs: the first was the Escape key; the second
                        // starts something new.
                        self.startSequence();
                        if (self.in_paste) return .{ .paste = "\x1b" };
                        return self.keyEvent(.{ .named = .escape }, .{});
                    },
                    else => {
                        // ESC followed by a key is Alt + that key. Read the
                        // key again from `ground`, with Alt pending.
                        self.state = .ground;
                        self.pos -= 1;
                        if (self.in_paste) return .{ .paste = "\x1b" };
                        self.alt = true;
                    },
                }
                return null;
            },
            .csi => {
                self.record(byte);
                switch (byte) {
                    '0'...'9' => {
                        // Saturating maths: a silly long number can't overflow.
                        self.current = self.current *| 10 +| (byte - '0');
                        self.has_current = true;
                    },
                    ':' => {
                        self.pushParam();
                        self.current_is_sub = true;
                    },
                    ';' => {
                        self.pushParam();
                        self.current_is_sub = false;
                    },
                    // A marker straight after `ESC [`, like the `<` of mouse
                    // reports or the `?` of terminal replies.
                    '<', '=', '>', '?' => {
                        if (self.sequence_len == 3) self.marker = byte;
                    },
                    // Intermediate bytes: none of the keys we handle use them.
                    0x20...0x2f => {},
                    // The final byte ends the sequence and says what it is.
                    0x40...0x7e => {
                        if (self.has_current or self.param_count > 0) self.pushParam();
                        self.state = .ground;
                        return self.dispatchCsi(byte);
                    },
                    // A new ESC means this sequence was broken; start again.
                    0x1b => self.startSequence(),
                    else => {}, // other control bytes are ignored
                }
                return null;
            },
            .ss3 => {
                self.record(byte);
                self.state = .ground;
                if (self.in_paste) return .{ .paste = self.sequence[0..self.sequence_len] };
                const named: ?Named = switch (byte) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    'P' => .f1,
                    'Q' => .f2,
                    'R' => .f3,
                    'S' => .f4,
                    else => null,
                };
                if (named) |n| return self.keyEvent(.{ .named = n }, .{});
                return .{ .unknown = self.sequence[0..self.sequence_len] };
            },
            .osc => {
                self.record(byte);
                switch (byte) {
                    0x07 => return self.endOsc(), // BEL ends it
                    0x1b => self.state = .osc_escape,
                    else => {},
                }
                return null;
            },
            .osc_escape => {
                self.record(byte);
                if (byte == '\\') return self.endOsc(); // ESC \ ends it
                self.state = .osc;
                return null;
            },
        }
    }

    fn ground(self: *Parser, byte: u8) ?Event {
        switch (byte) {
            0x1b => {
                self.startSequence();
                return null;
            },
            0x0d => return self.keyEvent(.{ .named = .enter }, .{}),
            0x09 => return self.keyEvent(.{ .named = .tab }, .{}),
            0x7f => return self.keyEvent(.{ .named = .backspace }, .{}),
            0x00 => return self.keyEvent(.{ .codepoint = ' ' }, .{ .ctrl = true }),
            // Ctrl+A .. Ctrl+Z (Tab and Enter, 0x09 and 0x0d, are above).
            0x01...0x08, 0x0a...0x0c, 0x0e...0x1a => {
                return self.keyEvent(.{ .codepoint = 'a' + byte - 1 }, .{ .ctrl = true });
            },
            // Ctrl+\ ] ^ _
            0x1c...0x1f => return self.keyEvent(.{ .codepoint = "\\]^_"[byte - 0x1c] }, .{ .ctrl = true }),
            0x20...0x7e => return self.keyEvent(.{ .codepoint = byte }, .{}),
            // The first byte of a multi-byte UTF-8 character says its length.
            0xc0...0xff => {
                const len = std.unicode.utf8ByteSequenceLength(byte) catch {
                    return self.keyEvent(.{ .codepoint = std.unicode.replacement_character }, .{});
                };
                self.codepoint = byte & (@as(u8, 0x7f) >> len);
                self.utf8_left = len - 1;
                self.state = .utf8;
                return null;
            },
            // A continuation byte with no start: invalid UTF-8.
            0x80...0xbf => return self.keyEvent(.{ .codepoint = std.unicode.replacement_character }, .{}),
        }
    }

    fn dispatchCsi(self: *Parser, final: u8) ?Event {
        const sequence = self.sequence[0..self.sequence_len];

        // Inside a paste, only the end-of-paste marker means anything; any
        // other sequence is part of the pasted text.
        if (self.in_paste) {
            if (self.marker == 0 and final == '~' and self.param(0, 0) == 201) {
                self.in_paste = false;
                return .paste_end;
            }
            return .{ .paste = sequence };
        }

        if (self.marker == '<' and (final == 'M' or final == 'm')) return self.mouse(final == 'm');
        if (self.marker != 0) return .{ .unknown = sequence };

        const mods = Mods.fromParam(self.param(1, 1));
        const named: ?Named = switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'P' => .f1,
            'Q' => .f2,
            'R' => .f3,
            'S' => .f4,
            '~' => switch (self.param(0, 0)) {
                1, 7 => .home,
                2 => .insert,
                3 => .delete,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                11 => .f1,
                12 => .f2,
                13 => .f3,
                14 => .f4,
                15 => .f5,
                17 => .f6,
                18 => .f7,
                19 => .f8,
                20 => .f9,
                21 => .f10,
                23 => .f11,
                24 => .f12,
                200 => {
                    self.in_paste = true;
                    return .paste_start;
                },
                else => null,
            },
            'Z' => return self.keyEvent(.{ .named = .tab }, .{ .shift = true }),
            'I' => return .{ .focus = true },
            'O' => return .{ .focus = false },
            'u' => return self.csiU(),
            else => null,
        };
        if (named) |n| return self.keyEvent(.{ .named = n }, mods);
        return .{ .unknown = sequence };
    }

    /// A kitty keyboard protocol key: `ESC [ code : shifted ; mods : event u`.
    /// `code` is the key without Shift (`a`, `1`); `shifted` is what Shift
    /// makes it (`A`, `!`), sent only when Shift is held.
    fn csiU(self: *Parser) ?Event {
        const code = self.field(0, 0, 0);
        const shifted = self.field(0, 1, 0);
        var mods = Mods.fromParam(self.field(1, 0, 1));

        // Event type: 1 press, 2 repeat, 3 release. We only ask for presses,
        // but drop a release if one turns up rather than act on it twice.
        if (self.field(1, 1, 1) == 3) return null;

        if (kittyKey(code)) |key| return self.keyEvent(key, mods);
        // Other codes in Unicode's private use area are keys we don't
        // handle: F13 and up, media keys, the modifier keys themselves.
        if (code >= 0xe000 and code <= 0xf8ff) return .{ .unknown = self.sequence[0..self.sequence_len] };
        if (code > 0x10ffff) return .{ .unknown = self.sequence[0..self.sequence_len] };

        // Shift+key without Ctrl or Super is just the shifted character:
        // Alt+Shift+1 is `<M-!>`, as Neovim expects. With Ctrl, keep the
        // base key and Shift, so Ctrl+Shift+A stays `<C-S-a>` and doesn't
        // collapse into Ctrl+A.
        var cp: u21 = @intCast(code);
        if (mods.shift and !mods.ctrl and !mods.super and shifted != 0 and shifted <= 0x10ffff) {
            cp = @intCast(shifted);
            mods.shift = false;
        }
        return self.keyEvent(.{ .codepoint = cp }, mods);
    }

    /// Kitty key codes that aren't plain characters. Codes from 57344 up
    /// are in Unicode's private use area; the keypad ones become the
    /// character or key they type.
    fn kittyKey(code: u32) ?Key {
        return switch (code) {
            13, 57414 => .{ .named = .enter },
            9 => .{ .named = .tab },
            27 => .{ .named = .escape },
            127 => .{ .named = .backspace },
            57399...57408 => .{ .codepoint = @intCast('0' + (code - 57399)) }, // keypad 0-9
            57409 => .{ .codepoint = '.' },
            57410 => .{ .codepoint = '/' },
            57411 => .{ .codepoint = '*' },
            57412 => .{ .codepoint = '-' },
            57413 => .{ .codepoint = '+' },
            57415 => .{ .codepoint = '=' },
            57416 => .{ .codepoint = ',' },
            57417 => .{ .named = .left },
            57418 => .{ .named = .right },
            57419 => .{ .named = .up },
            57420 => .{ .named = .down },
            57421 => .{ .named = .page_up },
            57422 => .{ .named = .page_down },
            57423 => .{ .named = .home },
            57424 => .{ .named = .end },
            57425 => .{ .named = .insert },
            57426 => .{ .named = .delete },
            else => null,
        };
    }

    /// SGR mouse report: `ESC [ < button ; col ; row M` (press) or `m`
    /// (release). Columns and rows count from 1.
    fn mouse(self: *Parser, release: bool) Event {
        const cb = self.param(0, 0);
        const col: u16 = @intCast(@min(self.param(1, 1) - 1, std.math.maxInt(u16)));
        const row: u16 = @intCast(@min(self.param(2, 1) - 1, std.math.maxInt(u16)));
        // Bits 4, 8 and 16 of the button number are the modifiers.
        const mods: Mods = .{ .shift = cb & 4 != 0, .alt = cb & 8 != 0, .ctrl = cb & 16 != 0 };
        const low = cb & 3;
        // Bit 64: a wheel, not a button.
        if (cb & 64 != 0) {
            const wheels = [_]Mouse.Button{ .wheel_up, .wheel_down, .wheel_left, .wheel_right };
            return .{ .mouse = .{ .button = wheels[low], .action = .press, .mods = mods, .row = row, .col = col } };
        }
        const buttons = [_]Mouse.Button{ .left, .middle, .right, .none };
        const button = buttons[low];
        // Bit 32: the pointer moved (with a button held, that's a drag).
        const action: Mouse.Action = if (release)
            .release
        else if (cb & 32 != 0)
            (if (button == .none) .motion else .drag)
        else
            .press;
        return .{ .mouse = .{ .button = button, .action = action, .mods = mods, .row = row, .col = col } };
    }

    fn endOsc(self: *Parser) Event {
        self.state = .ground;
        const sequence = self.sequence[0..self.sequence_len];
        if (self.in_paste) return .{ .paste = sequence };
        return .{ .unknown = sequence };
    }

    /// CSI parameter `i` (ignoring sub-parameters), or `default` when it is
    /// missing or 0.
    fn param(self: *const Parser, i: usize, default: u32) u32 {
        return self.field(i, 0, default);
    }

    /// Sub-parameter `sub` of parameter `group`, or `default` when it is
    /// missing or 0. In `ESC [ 49 : 33 ; 4 u`, field(0, 0) is 49,
    /// field(0, 1) is 33 and field(1, 0) is 4.
    fn field(self: *const Parser, group: usize, sub: usize, default: u32) u32 {
        // Find where the group starts: every value that isn't a
        // sub-parameter starts a new group.
        var g: usize = 0;
        var start: usize = 0;
        while (start < self.param_count) : (start += 1) {
            if (start > 0 and !self.is_sub.isSet(start)) g += 1;
            if (g == group) break;
        } else return default;

        // Each value up to the one we want must belong to this group.
        const i = start + sub;
        if (i >= self.param_count) return default;
        for (start + 1..i + 1) |j| {
            if (!self.is_sub.isSet(j)) return default;
        }
        return if (self.params[i] == 0) default else self.params[i];
    }

    fn pushParam(self: *Parser) void {
        if (self.param_count < max_params) {
            self.params[self.param_count] = self.current;
            self.is_sub.setValue(self.param_count, self.current_is_sub);
            self.param_count += 1;
        }
        self.current = 0;
        self.has_current = false;
    }

    /// A new escape sequence starts with this ESC.
    fn startSequence(self: *Parser) void {
        self.state = .escape;
        self.sequence[0] = 0x1b;
        self.sequence_len = 1;
    }

    /// Keep a sequence byte, for `unknown` events. Very long sequences are
    /// cut short; they are never keys.
    fn record(self: *Parser, byte: u8) void {
        if (self.sequence_len < max_sequence) {
            self.sequence[self.sequence_len] = byte;
            self.sequence_len += 1;
        }
    }

    /// A key event, with Alt added if a lone ESC came just before.
    fn keyEvent(self: *Parser, key: Key, mods: Mods) Event {
        var m = mods;
        if (self.alt) {
            m.alt = true;
            self.alt = false;
        }
        return .{ .key = .{ .key = key, .mods = m } };
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Feed each of `feeds` in turn (as separate reads) and check the events.
fn expectEvents(feeds: []const []const u8, want: []const Event) !void {
    var parser: Parser = .{};
    var i: usize = 0;
    for (feeds) |bytes| {
        parser.feed(bytes);
        while (parser.next()) |event| {
            if (i >= want.len) {
                std.debug.print("unexpected extra event: {f}\n", .{event});
                return error.TestUnexpectedResult;
            }
            // Compare straight away: events can point into parser memory
            // that the next event reuses.
            try testing.expectEqualDeep(want[i], event);
            i += 1;
        }
    }
    try testing.expectEqual(want.len, i);
}

fn testKey(cp: u21, mods: Mods) Event {
    return .{ .key = .{ .key = .{ .codepoint = cp }, .mods = mods } };
}

fn testNamed(n: Named, mods: Mods) Event {
    return .{ .key = .{ .key = .{ .named = n }, .mods = mods } };
}

test "characters" {
    try expectEvents(&.{"a"}, &.{testKey('a', .{})});
    try expectEvents(&.{"aZ5"}, &.{ testKey('a', .{}), testKey('Z', .{}), testKey('5', .{}) });
    try expectEvents(&.{"é"}, &.{testKey('é', .{})});
    try expectEvents(&.{"漢"}, &.{testKey('漢', .{})});
    try expectEvents(&.{"🙂"}, &.{testKey('🙂', .{})});
}

test "control keys" {
    try expectEvents(&.{"\r"}, &.{testNamed(.enter, .{})});
    try expectEvents(&.{"\t"}, &.{testNamed(.tab, .{})});
    try expectEvents(&.{"\x7f"}, &.{testNamed(.backspace, .{})});
    try expectEvents(&.{"\x01"}, &.{testKey('a', .{ .ctrl = true })});
    try expectEvents(&.{"\x08"}, &.{testKey('h', .{ .ctrl = true })});
    try expectEvents(&.{"\x00"}, &.{testKey(' ', .{ .ctrl = true })});
    try expectEvents(&.{"\x1c"}, &.{testKey('\\', .{ .ctrl = true })});
}

test "escape and alt" {
    try expectEvents(&.{"\x1b"}, &.{testNamed(.escape, .{})});
    try expectEvents(&.{"\x1bx"}, &.{testKey('x', .{ .alt = true })});
    try expectEvents(&.{"\x1bé"}, &.{testKey('é', .{ .alt = true })});
    try expectEvents(&.{"\x1b\x01"}, &.{testKey('a', .{ .ctrl = true, .alt = true })});
    try expectEvents(&.{"\x1b\x1b"}, &.{ testNamed(.escape, .{}), testNamed(.escape, .{}) });
    // A lone ESC at the end of one read, then a key in the next: two keys.
    try expectEvents(&.{ "\x1b", "x" }, &.{ testNamed(.escape, .{}), testKey('x', .{}) });
}

test "csi and ss3 keys" {
    try expectEvents(&.{"\x1b[A"}, &.{testNamed(.up, .{})});
    try expectEvents(&.{"\x1b[1;5C"}, &.{testNamed(.right, .{ .ctrl = true })});
    try expectEvents(&.{"\x1b[1;4D"}, &.{testNamed(.left, .{ .shift = true, .alt = true })});
    // Alt on function keys is a modifier param, as Ghostty sends it
    try expectEvents(&.{"\x1b[1;3A"}, &.{testNamed(.up, .{ .alt = true })});
    // ESC prefix only means Alt for text keys, as in Ghostty
    try expectEvents(&.{"\x1b\x1b[A"}, &.{ testNamed(.escape, .{}), testNamed(.up, .{}) });
    try expectEvents(&.{"\x1b[3~"}, &.{testNamed(.delete, .{})});
    try expectEvents(&.{"\x1b[15~"}, &.{testNamed(.f5, .{})});
    try expectEvents(&.{"\x1b[24;2~"}, &.{testNamed(.f12, .{ .shift = true })});
    try expectEvents(&.{"\x1bOP"}, &.{testNamed(.f1, .{})});
    try expectEvents(&.{"\x1bOA"}, &.{testNamed(.up, .{})});
    try expectEvents(&.{"\x1b[Z"}, &.{testNamed(.tab, .{ .shift = true })});
    try expectEvents(&.{"\x1b[97;5u"}, &.{testKey('a', .{ .ctrl = true })});
    try expectEvents(&.{"\x1b[13;2u"}, &.{testNamed(.enter, .{ .shift = true })});
}

test "kitty keyboard protocol" {
    // Keys the legacy encoding can't tell apart.
    try expectEvents(&.{"\x1b[27u"}, &.{testNamed(.escape, .{})});
    try expectEvents(&.{"\x1b[105;5u"}, &.{testKey('i', .{ .ctrl = true })});
    try expectEvents(&.{"\x1b[104;5u"}, &.{testKey('h', .{ .ctrl = true })});
    try expectEvents(&.{"\x1b[120;3u"}, &.{testKey('x', .{ .alt = true })});
    try expectEvents(&.{"\x1b[13;5u"}, &.{testNamed(.enter, .{ .ctrl = true })});
    // Shift: use the shifted key, unless Ctrl is held too.
    try expectEvents(&.{"\x1b[49:33;4u"}, &.{testKey('!', .{ .alt = true })});
    try expectEvents(&.{"\x1b[97:65;6u"}, &.{testKey('a', .{ .ctrl = true, .shift = true })});
    // Caps lock (64) and num lock (128) bits are ignored: 1 + 4 + 64.
    try expectEvents(&.{"\x1b[97;69u"}, &.{testKey('a', .{ .ctrl = true })});
    // A release (event type 3) makes no event.
    try expectEvents(&.{"\x1b[97;5:3u"}, &.{});
    // Keypad keys, and keys we don't handle.
    try expectEvents(&.{"\x1b[57399u\x1b[57414u"}, &.{ testKey('0', .{}), testNamed(.enter, .{}) });
    try expectEvents(&.{"\x1b[57441;2u"}, &.{.{ .unknown = "\x1b[57441;2u" }});
    // Legacy sequences can carry an event type too.
    try expectEvents(&.{"\x1b[1;5:1C"}, &.{testNamed(.right, .{ .ctrl = true })});
}

test "sequences split across reads" {
    try expectEvents(&.{ "\x1b[1;", "5C" }, &.{testNamed(.right, .{ .ctrl = true })});
    try expectEvents(&.{ "\x1b[", "A" }, &.{testNamed(.up, .{})});
    try expectEvents(&.{ "\xc3", "\xa9" }, &.{testKey('é', .{})});
}

test "unknown and broken input" {
    try expectEvents(&.{"\x1b[99X"}, &.{.{ .unknown = "\x1b[99X" }});
    try expectEvents(&.{"\x1b]11;rgb:0/0/0\x07a"}, &.{ .{ .unknown = "\x1b]11;rgb:0/0/0\x07" }, testKey('a', .{}) });
    try expectEvents(&.{"\xc3a"}, &.{ testKey(std.unicode.replacement_character, .{}), testKey('a', .{}) });
    try expectEvents(&.{"\x80"}, &.{testKey(std.unicode.replacement_character, .{})});
}

test "paste, focus and mouse" {
    try expectEvents(&.{"\x1b[200~hi\r\x1b[201~"}, &.{ .paste_start, .{ .paste = "hi\r" }, .paste_end });
    try expectEvents(&.{ "\x1b[200~a", "b\x1b[201~" }, &.{ .paste_start, .{ .paste = "a" }, .{ .paste = "b" }, .paste_end });
    try expectEvents(&.{"\x1b[200~\x1b[A\x1b[201~"}, &.{ .paste_start, .{ .paste = "\x1b[A" }, .paste_end });
    try expectEvents(&.{"\x1b[I\x1b[O"}, &.{ .{ .focus = true }, .{ .focus = false } });
    try expectEvents(&.{"\x1b[<0;10;5M"}, &.{.{ .mouse = .{ .button = .left, .action = .press, .row = 4, .col = 9 } }});
    try expectEvents(&.{"\x1b[<0;10;5m"}, &.{.{ .mouse = .{ .button = .left, .action = .release, .row = 4, .col = 9 } }});
    try expectEvents(&.{"\x1b[<64;1;1M"}, &.{.{ .mouse = .{ .button = .wheel_up, .action = .press, .row = 0, .col = 0 } }});
    try expectEvents(&.{"\x1b[<48;3;2M"}, &.{.{ .mouse = .{ .button = .left, .action = .drag, .mods = .{ .ctrl = true }, .row = 1, .col = 2 } }});
}

test "neovim notation" {
    const cases = [_]struct { KeyEvent, []const u8 }{
        .{ .{ .key = .{ .codepoint = 'a' } }, "a" },
        .{ .{ .key = .{ .codepoint = '<' } }, "<lt>" },
        .{ .{ .key = .{ .codepoint = ' ' } }, " " },
        .{ .{ .key = .{ .codepoint = ' ' }, .mods = .{ .ctrl = true } }, "<C-Space>" },
        .{ .{ .key = .{ .codepoint = 'x' }, .mods = .{ .alt = true } }, "<M-x>" },
        .{ .{ .key = .{ .codepoint = 'é' } }, "é" },
        .{ .{ .key = .{ .named = .enter } }, "<CR>" },
        .{ .{ .key = .{ .named = .right }, .mods = .{ .ctrl = true } }, "<C-Right>" },
        .{ .{ .key = .{ .named = .f5 }, .mods = .{ .shift = true } }, "<S-F5>" },
        .{ .{ .key = .{ .codepoint = 'i' }, .mods = .{ .ctrl = true } }, "<C-i>" },
        .{ .{ .key = .{ .codepoint = 'a' }, .mods = .{ .ctrl = true, .shift = true } }, "<C-S-a>" },
        .{ .{ .key = .{ .codepoint = '!' }, .mods = .{ .alt = true } }, "<M-!>" },
    };
    for (cases) |c| {
        var buf: [32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeNvim(c[0], &w);
        try testing.expectEqualStrings(c[1], w.buffered());
    }
}
