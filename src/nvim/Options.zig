//! What people choose in `vim.g.neorex_config`: which of Neovim's prompts
//! and pickers neorex hands to Rex. The Lua sends the table as it is, in a
//! `neorex_options` notification; `decode` reads it and `diff` lists what
//! going from one set of options to another takes. Neither touches Neovim
//! or Rex, so both are tested with tables alone.
//!
//! ```lua
//! vim.g.neorex_config = {
//!   cmdline = 'rex',                    -- the : line, in Rex's palette
//!   confirm = 'rex',                    -- confirm(), :s///c, the swap file dialog
//!   ui = { select = 'rex', input = 'rex' }, -- vim.ui.select and vim.ui.input
//!   palette = true,                     -- neorex's pickers as Rex actions
//! }
//! ```
//!
//! Everything is Neovim's until chosen. A field added here is read from the
//! table of the same name: `decode` walks this struct's fields.

const std = @import("std");
const msgpack = @import("msgpack.zig");
const rpc = @import("rpc.zig");

const Options = @This();

/// The notification the Lua sends the table in.
pub const method = "neorex_options";

/// Who shows a prompt. Rex can always say no (no app connected, or one too
/// old), and then Neovim shows it as usual.
pub const Surface = enum { neovim, rex };

/// The command line, `:` and `/`.
cmdline: Surface = .neovim,
/// Neovim's own questions: `confirm()`, `:s///c`, the swap file dialog.
confirm: Surface = .neovim,
ui: Ui = .{},
/// neorex's pickers as actions in Rex's command palette.
palette: bool = false,

pub const Ui = struct {
    select: Surface = .neovim,
    input: Surface = .neovim,
};

pub const default: Options = .{};

/// Reads the notification's params, `[config]`. `config` is the table, or
/// nil when unset. A part that's wrong keeps its default and is described,
/// a line each, on `problems`; only a malformed message is an error.
pub fn decode(params: *msgpack.Decoder, problems: *std.Io.Writer) !Options {
    if (try rpc.expectArray(params) < 1) return error.BadMessage;
    var o: Options = .{};
    try readValue(Options, "neorex_config", &o, params, problems);
    return o;
}

/// The UI extensions these options need from Neovim.
pub const Extensions = struct {
    cmdline: bool,
    messages: bool,
};

pub fn extensions(o: Options) Extensions {
    const messages = o.confirm == .rex;
    // Neovim's ext_messages turns on ext_cmdline too
    return .{ .cmdline = o.cmdline == .rex or messages, .messages = messages };
}

/// Something to do because an option changed.
pub const Effect = union(enum) {
    /// `nvim_ui_set_option(name, on)`.
    ui_option: struct { name: UiOption, on: bool },
    /// Hand `vim.ui.<func>` to Rex, or give Neovim's back.
    vim_ui: struct { func: std.meta.FieldEnum(Ui), surface: Surface },
    /// Add neorex's pickers to Rex's palette, or take them away.
    palette: bool,
};

pub const UiOption = enum { ext_cmdline, ext_messages };

/// The most effects one `diff` can give: one per thing it compares.
pub const max_effects = 3 + @typeInfo(Ui).@"struct".field_names.len;

/// What going from `old` to `new` takes, in order, written to `out`.
pub fn diff(old: Options, new: Options, out: *[max_effects]Effect) []const Effect {
    var n: usize = 0;
    const a = old.extensions();
    const b = new.extensions();
    if (a.messages != b.messages) {
        out[n] = .{ .ui_option = .{ .name = .ext_messages, .on = b.messages } };
        n += 1;
    }
    // after ext_messages, which may have changed ext_cmdline with it
    if (a.cmdline != b.cmdline or a.messages != b.messages) {
        out[n] = .{ .ui_option = .{ .name = .ext_cmdline, .on = b.cmdline } };
        n += 1;
    }
    inline for (@typeInfo(Ui).@"struct".field_names) |name| {
        if (@field(old.ui, name) != @field(new.ui, name)) {
            out[n] = .{ .vim_ui = .{ .func = @field(std.meta.FieldEnum(Ui), name), .surface = @field(new.ui, name) } };
            n += 1;
        }
    }
    if (old.palette != new.palette) {
        out[n] = .{ .palette = new.palette };
        n += 1;
    }
    return out[0..n];
}

// Decoding

/// Reads one value into `out`, which keeps its value if this one is wrong.
/// `path` names it in problems, such as `neorex_config.ui.select`.
fn readValue(comptime T: type, comptime path: []const u8, out: *T, d: *msgpack.Decoder, problems: *std.Io.Writer) !void {
    const t = try nextToken(d);
    switch (@typeInfo(T)) {
        .@"enum" => if (t == .str) {
            const s = try rpc.expectBytes(d, t.str);
            if (std.meta.stringToEnum(T, s)) |v| {
                out.* = v;
            } else problem(problems, "{s}: expected {s}, got \"{s}\"", .{ path, comptime expected(T), s });
            return;
        },
        .bool => if (t == .bool) {
            out.* = t.bool;
            return;
        },
        .@"struct" => switch (t) {
            .map => |pairs| return readTable(T, path, out, d, problems, pairs),
            // an empty Lua table is sent as an empty list
            .array => |len| if (len == 0) return,
            // unset
            .nil => if (comptime std.mem.indexOfScalar(u8, path, '.') == null) return,
            else => {},
        },
        else => @compileError("no way to read " ++ @typeName(T)),
    }
    problem(problems, "{s}: expected {s}, got {s}", .{ path, comptime expected(T), kindOf(t) });
    try skipAfter(d, t);
}

fn readTable(comptime T: type, comptime path: []const u8, out: *T, d: *msgpack.Decoder, problems: *std.Io.Writer, pairs: u32) !void {
    for (0..pairs) |_| {
        const kt = try nextToken(d);
        if (kt != .str) {
            problem(problems, "{s}: option names are strings, got {s}", .{ path, kindOf(kt) });
            try skipAfter(d, kt);
            try rpc.skip(d);
            continue;
        }
        const key = try rpc.expectBytes(d, kt.str);
        var known = false;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |name, F| {
            if (std.mem.eql(u8, key, name)) {
                known = true;
                try readValue(F, path ++ "." ++ name, &@field(out, name), d, problems);
            }
        }
        if (!known) {
            problem(problems, "{s}.{s}: no such option", .{ path, key });
            try rpc.skip(d);
        }
    }
}

/// What a value of type `T` should be, for problems.
fn expected(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .@"enum" => |e| blk: {
            var s: []const u8 = "";
            for (e.field_names, 0..) |name, i| {
                const sep = if (i == 0) "" else if (i == e.field_names.len - 1) " or " else ", ";
                s = s ++ sep ++ "\"" ++ name ++ "\"";
            }
            break :blk s;
        },
        .bool => "true or false",
        .@"struct" => "a table",
        else => @compileError("no way to read " ++ @typeName(T)),
    };
}

fn kindOf(t: msgpack.Token) []const u8 {
    return switch (t) {
        .nil => "nil",
        .bool => |b| if (b) "true" else "false",
        .int, .uint, .float => "a number",
        .str => "a string",
        .array => "a list",
        .map => "a table",
        .bin, .ext, .chunk => "something else",
    };
}

fn problem(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    // a full buffer drops what doesn't fit: the first problems matter most
    w.print(fmt ++ "\n", args) catch {};
}

fn nextToken(d: *msgpack.Decoder) !msgpack.Token {
    return (try d.next()) orelse error.BadMessage;
}

/// Skips the rest of a value whose first token was `t`.
fn skipAfter(d: *msgpack.Decoder, t: msgpack.Token) !void {
    switch (t) {
        .array => |n| for (0..n) |_| try rpc.skip(d),
        .map => |n| for (0..@as(u64, n) * 2) |_| try rpc.skip(d),
        .str, .bin => |len| _ = try rpc.expectBytes(d, len),
        .ext => |e| _ = try rpc.expectBytes(d, e.len),
        else => {},
    }
}

// Tests

const testing = std.testing;

/// A Lua value, as the notification would carry it.
const Lua = union(enum) {
    nil,
    boolean: bool,
    int: i64,
    str: []const u8,
    list: []const Lua,
    table: []const Field,

    const Field = struct { []const u8, Lua };

    fn write(v: Lua, w: *std.Io.Writer) !void {
        switch (v) {
            .nil => try msgpack.writeNil(w),
            .boolean => |b| try msgpack.writeBool(w, b),
            .int => |n| try msgpack.writeInt(w, n),
            .str => |s| try msgpack.writeStr(w, s),
            .list => |l| {
                try msgpack.writeArrayHeader(w, @intCast(l.len));
                for (l) |x| try x.write(w);
            },
            .table => |fs| {
                try msgpack.writeMapHeader(w, @intCast(fs.len));
                for (fs) |f| {
                    try msgpack.writeStr(w, f[0]);
                    try f[1].write(w);
                }
            },
        }
    }
};

/// Decodes `[config]` as the notification sends it. Problems go in `problems_buf`.
fn decodeLua(config: Lua, problems_buf: []u8) !struct { Options, []const u8 } {
    var bytes: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&bytes);
    try msgpack.writeArrayHeader(&w, 1);
    try config.write(&w);
    var d: msgpack.Decoder = .{};
    d.feed(w.buffered());
    var problems: std.Io.Writer = .fixed(problems_buf);
    const o = try decode(&d, &problems);
    // the whole message was read, and no more
    try testing.expectEqual(@as(?msgpack.Token, null), try d.next());
    return .{ o, problems.buffered() };
}

test decode {
    const cases = [_]struct {
        name: []const u8,
        config: Lua,
        want: Options,
        problems: []const u8 = "",
    }{
        .{ .name = "unset", .config = .nil, .want = .default },
        .{ .name = "empty table", .config = .{ .table = &.{} }, .want = .default },
        .{ .name = "empty table as a list", .config = .{ .list = &.{} }, .want = .default },
        .{
            .name = "everything",
            .config = .{ .table = &.{
                .{ "cmdline", .{ .str = "rex" } },
                .{ "confirm", .{ .str = "rex" } },
                .{ "ui", .{ .table = &.{ .{ "select", .{ .str = "rex" } }, .{ "input", .{ .str = "rex" } } } } },
                .{ "palette", .{ .boolean = true } },
            } },
            .want = .{ .cmdline = .rex, .confirm = .rex, .ui = .{ .select = .rex, .input = .rex }, .palette = true },
        },
        .{
            .name = "naming neovim is the same as leaving it out",
            .config = .{ .table = &.{ .{ "cmdline", .{ .str = "neovim" } }, .{ "palette", .{ .boolean = false } } } },
            .want = .default,
        },
        .{
            .name = "part of ui",
            .config = .{ .table = &.{.{ "ui", .{ .table = &.{.{ "input", .{ .str = "rex" } }} } }} },
            .want = .{ .ui = .{ .input = .rex } },
        },
        .{
            .name = "unknown option",
            .config = .{ .table = &.{ .{ "cmdlin", .{ .str = "rex" } }, .{ "confirm", .{ .str = "rex" } } } },
            .want = .{ .confirm = .rex },
            .problems = "neorex_config.cmdlin: no such option\n",
        },
        .{
            .name = "unknown option in ui, with a table for its value",
            .config = .{ .table = &.{.{ "ui", .{ .table = &.{
                .{ "pick", .{ .table = &.{.{ "a", .{ .int = 1 } }} } },
                .{ "select", .{ .str = "rex" } },
            } } }} },
            .want = .{ .ui = .{ .select = .rex } },
            .problems = "neorex_config.ui.pick: no such option\n",
        },
        .{
            .name = "unknown choice",
            .config = .{ .table = &.{ .{ "cmdline", .{ .str = "tui" } }, .{ "palette", .{ .boolean = true } } } },
            .want = .{ .palette = true },
            .problems = "neorex_config.cmdline: expected \"neovim\" or \"rex\", got \"tui\"\n",
        },
        .{
            .name = "wrong types keep their defaults",
            .config = .{ .table = &.{
                .{ "cmdline", .{ .boolean = true } },
                .{ "palette", .{ .str = "yes" } },
                .{ "ui", .{ .list = &.{ .{ .str = "select" }, .{ .str = "input" } } } },
                .{ "confirm", .{ .str = "rex" } },
            } },
            .want = .{ .confirm = .rex },
            .problems = "neorex_config.cmdline: expected \"neovim\" or \"rex\", got true\n" ++
                "neorex_config.palette: expected true or false, got a string\n" ++
                "neorex_config.ui: expected a table, got a list\n",
        },
        .{
            .name = "ui set to nil is wrong, unlike the whole table",
            .config = .{ .table = &.{.{ "ui", .nil }} },
            .want = .default,
            .problems = "neorex_config.ui: expected a table, got nil\n",
        },
        .{
            .name = "not a table",
            .config = .{ .str = "rex" },
            .want = .default,
            .problems = "neorex_config: expected a table, got a string\n",
        },
        .{
            .name = "a list",
            .config = .{ .list = &.{.{ .str = "cmdline" }} },
            .want = .default,
            .problems = "neorex_config: expected a table, got a list\n",
        },
    };
    for (cases) |c| {
        var buf: [512]u8 = undefined;
        const got, const problems = decodeLua(c.config, &buf) catch |err| {
            std.debug.print("case \"{s}\": {t}\n", .{ c.name, err });
            return err;
        };
        testing.expectEqual(c.want, got) catch |err| {
            std.debug.print("case \"{s}\"\n", .{c.name});
            return err;
        };
        testing.expectEqualStrings(c.problems, problems) catch |err| {
            std.debug.print("case \"{s}\"\n", .{c.name});
            return err;
        };
    }
}

test "decode: a full problem buffer keeps the first problems" {
    var buf: [40]u8 = undefined;
    const got, const problems = try decodeLua(.{ .table = &.{
        .{ "a", .{ .int = 1 } },
        .{ "b", .{ .int = 2 } },
        .{ "palette", .{ .boolean = true } },
    } }, &buf);
    try testing.expect(got.palette);
    try testing.expect(std.mem.startsWith(u8, problems, "neorex_config.a: no such option\n"));
}

test "decode: a message without the table is malformed" {
    var bytes: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&bytes);
    try msgpack.writeArrayHeader(&w, 0);
    var d: msgpack.Decoder = .{};
    d.feed(w.buffered());
    var problems: std.Io.Writer = .fixed(&.{});
    try testing.expectError(error.BadMessage, decode(&d, &problems));
}

test diff {
    const cases = [_]struct {
        name: []const u8,
        old: Options = .default,
        new: Options = .default,
        want: []const Effect,
    }{
        .{ .name = "nothing changed", .want = &.{} },
        .{
            .name = "nothing changed, everything rex",
            .old = .{ .cmdline = .rex, .confirm = .rex, .ui = .{ .select = .rex, .input = .rex }, .palette = true },
            .new = .{ .cmdline = .rex, .confirm = .rex, .ui = .{ .select = .rex, .input = .rex }, .palette = true },
            .want = &.{},
        },
        .{
            .name = "cmdline to rex",
            .new = .{ .cmdline = .rex },
            .want = &.{.{ .ui_option = .{ .name = .ext_cmdline, .on = true } }},
        },
        .{
            .name = "cmdline back to neovim",
            .old = .{ .cmdline = .rex },
            .want = &.{.{ .ui_option = .{ .name = .ext_cmdline, .on = false } }},
        },
        .{
            .name = "confirm to rex needs the cmdline too",
            .new = .{ .confirm = .rex },
            .want = &.{
                .{ .ui_option = .{ .name = .ext_messages, .on = true } },
                .{ .ui_option = .{ .name = .ext_cmdline, .on = true } },
            },
        },
        .{
            .name = "confirm back to neovim gives the cmdline back",
            .old = .{ .confirm = .rex },
            .want = &.{
                .{ .ui_option = .{ .name = .ext_messages, .on = false } },
                .{ .ui_option = .{ .name = .ext_cmdline, .on = false } },
            },
        },
        .{
            .name = "confirm back to neovim keeps a cmdline still chosen",
            .old = .{ .confirm = .rex, .cmdline = .rex },
            .new = .{ .cmdline = .rex },
            .want = &.{
                .{ .ui_option = .{ .name = .ext_messages, .on = false } },
                .{ .ui_option = .{ .name = .ext_cmdline, .on = true } },
            },
        },
        .{
            .name = "cmdline to neovim while confirm keeps it",
            .old = .{ .confirm = .rex, .cmdline = .rex },
            .new = .{ .confirm = .rex },
            .want = &.{},
        },
        .{
            .name = "vim.ui functions, each on its own",
            .old = .{ .ui = .{ .input = .rex } },
            .new = .{ .ui = .{ .select = .rex } },
            .want = &.{
                .{ .vim_ui = .{ .func = .select, .surface = .rex } },
                .{ .vim_ui = .{ .func = .input, .surface = .neovim } },
            },
        },
        .{ .name = "palette on", .new = .{ .palette = true }, .want = &.{.{ .palette = true }} },
        .{ .name = "palette off", .old = .{ .palette = true }, .want = &.{.{ .palette = false }} },
        .{
            .name = "everything at once",
            .new = .{ .cmdline = .rex, .confirm = .rex, .ui = .{ .select = .rex, .input = .rex }, .palette = true },
            .want = &.{
                .{ .ui_option = .{ .name = .ext_messages, .on = true } },
                .{ .ui_option = .{ .name = .ext_cmdline, .on = true } },
                .{ .vim_ui = .{ .func = .select, .surface = .rex } },
                .{ .vim_ui = .{ .func = .input, .surface = .rex } },
                .{ .palette = true },
            },
        },
    };
    for (cases) |c| {
        var buf: [max_effects]Effect = undefined;
        const got = diff(c.old, c.new, &buf);
        testing.expectEqualSlices(Effect, c.want, got) catch |err| {
            std.debug.print("case \"{s}\"\n", .{c.name});
            return err;
        };
    }
}
