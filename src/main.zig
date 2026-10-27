const std = @import("std");

const debug_keys = @import("debug/keys.zig");
const debug_events = @import("debug/events.zig");
const debug_tui = @import("debug/tui.zig");
const debug_panes = @import("debug/panes.zig");
const pane = @import("daemon/pane.zig");

const usage =
    \\usage: neorex <command>
    \\
    \\commands:
    \\  debug-keys                 show each key, paste, focus and mouse event as you type
    \\  debug-events [nvim args]   run Neovim and print the redraw events it sends
    \\  debug-tui [nvim args]      run Neovim in this terminal through neorex's renderer
    \\  debug-panes SOCKET         stand-in daemon: drive the terminals of panes that connect
    \\  pane SOCKET                hand this terminal to the daemon at SOCKET, then wait
    \\  help                       show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2 and std.mem.eql(u8, args[1], "debug-events")) {
        return debug_events.run(init.gpa, init.io, args[2..]);
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "debug-tui")) {
        return debug_tui.run(init.gpa, init.io, args[2..]);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "pane")) {
        return pane.run(init.io, args[2]);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "debug-panes")) {
        return debug_panes.run(init.io, args[2]);
    }
    if (args.len == 2) {
        const cmd = args[1];
        if (std.mem.eql(u8, cmd, "debug-keys")) return debug_keys.run();
        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        }
    }
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
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
    _ = @import("screen/Grid.zig");
    _ = @import("screen/render.zig");
    _ = @import("daemon/Loop.zig");
    _ = @import("daemon/fdpass.zig");
    _ = @import("daemon/pane.zig");
    _ = debug_keys;
    _ = debug_events;
    _ = debug_tui;
    _ = debug_panes;
}
