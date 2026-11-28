const std = @import("std");

const debug_keys = @import("debug/keys.zig");
const debug_events = @import("debug/events.zig");
const debug_tui = @import("debug/tui.zig");
const debug_panes = @import("debug/panes.zig");
const debug_rex = @import("debug/rex.zig");
const pane = @import("daemon/pane_helper.zig");
const launch = @import("daemon/launch.zig");
const serve = @import("daemon/serve.zig");

const usage =
    \\usage: neorex [nvim args]    open Neovim in this pane
    \\       neorex <command>
    \\
    \\commands:
    \\  debug-keys                 show each key, paste, focus and mouse event as you type
    \\  debug-events [nvim args]   run Neovim and print the redraw events it sends
    \\  debug-tui [nvim args]      run Neovim in this terminal through neorex's renderer
    \\  debug-panes SOCKET         stand-in daemon: drive the terminals of panes that connect
    \\  debug-rex SOCKET           open a split in this Rex session and drive its pane; print Rex events
    \\  pane SOCKET [ID]           hand this terminal to the daemon at SOCKET, then wait
    \\  help                       show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const gpa = init.gpa;
    const io = init.io;
    const cmd = if (args.len >= 2) args[1] else "";
    const rest = if (args.len >= 2) args[2..] else args[0..0];

    if (eql(cmd, "help") or eql(cmd, "-h") or eql(cmd, "--help")) {
        std.debug.print("{s}", .{usage});
        return;
    }
    if (eql(cmd, "debug-keys") and rest.len == 0) return debug_keys.run();
    if (eql(cmd, "debug-events")) return debug_events.run(gpa, io, rest);
    if (eql(cmd, "debug-tui")) return debug_tui.run(gpa, io, rest);
    if (eql(cmd, "debug-panes") and rest.len == 1) return debug_panes.run(io, rest[0]);
    if (eql(cmd, "debug-rex") and rest.len == 1) return debug_rex.run(gpa, io, rest[0]);
    if (eql(cmd, "pane")) nameAfterNeovim(args[0]);
    if (eql(cmd, "pane") and rest.len == 1) return pane.run(io, rest[0], null);
    if (eql(cmd, "pane") and rest.len == 2) return pane.run(io, rest[0], std.fmt.parseInt(u32, rest[1], 10) catch {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    });
    // started by the launcher, not by people
    if (eql(cmd, "daemon") and rest.len >= 1) return serve.run(gpa, io, rest[0], rest[1..]);
    for ([_][]const u8{ "debug-keys", "debug-panes", "debug-rex", "pane", "daemon" }) |known| {
        if (eql(cmd, known)) {
            std.debug.print("{s}", .{usage});
            std.process.exit(2);
        }
    }
    nameAfterNeovim(args[0]);
    return launch.run(gpa, io, args[1..]);
}

/// Rex picks a pane's icon from its program's argv[0], so the launcher and
/// the pane helpers overwrite theirs with `nvim`. An argv[0] too short to
/// hold it is left alone.
fn nameAfterNeovim(argv0: [:0]const u8) void {
    const name = "nvim";
    if (argv0.len < name.len) return;
    const buf: []u8 = @constCast(argv0);
    @memcpy(buf[0..name.len], name);
    @memset(buf[name.len..], 0);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test {
    // every file of the app; the modules, integration_tests.zig and
    // golden_tests.zig are their own test modules
    _ = @import("daemon/loop.zig");
    _ = @import("daemon/fdpass.zig");
    _ = @import("daemon/pane_helper.zig");
    _ = @import("daemon/Pane.zig");
    _ = @import("daemon/Panes.zig");
    _ = @import("daemon/NvimSession.zig");
    _ = @import("daemon/WindowChanges.zig");
    _ = @import("daemon/Titles.zig");
    _ = @import("daemon/Surface.zig");
    _ = @import("daemon/sizing.zig");
    _ = @import("daemon/policy.zig");
    _ = @import("daemon/Daemon.zig");
    _ = launch;
    _ = serve;
    _ = @import("debug/PaneHost.zig");
    _ = debug_keys;
    _ = debug_events;
    _ = debug_tui;
    _ = debug_panes;
    _ = debug_rex;
}
