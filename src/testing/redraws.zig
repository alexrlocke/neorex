//! Reading a real Neovim's redraws into grids, for tests.

const std = @import("std");
const testing = std.testing;
const Grids = @import("screen").Grids;

/// Applies Neovim's redraws until `done` holds after a flush.
pub fn pumpUntil(nvim_client: anytype, gs: *Grids, comptime done: fn (*Grids) bool) !void {
    const gpa = testing.allocator;
    for (0..100) |_| {
        var fds = [_]std.c.pollfd{.{ .fd = nvim_client.readFd(), .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 2000) <= 0) return error.TestTimedOut;
        if (!try nvim_client.read(gpa)) return error.NvimExited;
        while (try nvim_client.next()) |msg| switch (msg) {
            .notification => |n| if (std.mem.eql(u8, n.method, "redraw")) {
                var params = n.params;
                if (try gs.applyRedraw(gpa, &params) and done(gs)) return;
            },
            .response => |r| if (r.err) |e| {
                std.debug.print("neovim: {s}\n", .{e});
                return error.NvimError;
            },
            else => {},
        };
    }
    return error.TestTimedOut;
}
