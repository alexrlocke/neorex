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
    return launch.run(gpa, io, args[1..]);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test {
    // every file, reached from here; golden.zig is its own test module
    _ = @import("term/Terminal.zig");
    _ = @import("term/Signals.zig");
    _ = @import("term/input.zig");
    _ = @import("nvim/msgpack.zig");
    _ = @import("nvim/Framer.zig");
    _ = @import("nvim/rpc.zig");
    _ = @import("nvim/Nvim.zig");
    _ = @import("nvim/Forwarder.zig");
    _ = @import("nvim/windows.zig");
    _ = @import("screen/Grid.zig");
    _ = @import("screen/Grids.zig");
    _ = @import("screen/Style.zig");
    _ = @import("screen/PaneView.zig");
    _ = @import("screen/render.zig");
    _ = @import("daemon/Loop.zig");
    _ = @import("daemon/fdpass.zig");
    _ = @import("daemon/pane_helper.zig");
    _ = @import("daemon/Pane.zig");
    _ = @import("daemon/Panes.zig");
    _ = @import("daemon/Surface.zig");
    _ = @import("daemon/Daemon.zig");
    _ = @import("term/modes.zig");
    _ = launch;
    _ = serve;
    _ = @import("rex/WebSocket.zig");
    _ = @import("rex/Client.zig");
    _ = @import("debug/PaneHost.zig");
    _ = debug_keys;
    _ = debug_events;
    _ = debug_tui;
    _ = debug_panes;
    _ = debug_rex;
}
