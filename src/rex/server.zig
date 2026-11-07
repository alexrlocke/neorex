//! Finding the Rex server that owns this terminal.

const std = @import("std");

/// The server's URL, such as `unix:///run/user/1000/rex/server.sock`.
/// `REX_SERVER` when set, since it names the server this terminal belongs
/// to. Rex sets it only for servers a `rex` command started, so otherwise
/// asks `rex server status` for the local server. The caller owns the result.
pub fn url(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    if (std.c.getenv("REX_SERVER")) |v| return gpa.dupe(u8, std.mem.span(v));
    return localUrl(gpa, io);
}

fn localUrl(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    // the `rex` this terminal came from, else the one on PATH
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = if (std.c.getenv("REX_BIN_DIR")) |dir|
        try std.fmt.bufPrint(&exe_buf, "{s}/rex", .{std.mem.span(dir)})
    else
        "rex";
    // no autostart: a new server wouldn't know this terminal's session
    const r = std.process.run(gpa, io, .{
        .argv = &.{ exe, "server", "status", "--autostart=false", "--json" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.NoRexServer;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (!r.term.success()) return error.NoRexServer;
    return parseEndpoint(gpa, r.stdout);
}

/// The `endpoint` field of `rex server status --json`. The caller owns the result.
pub fn parseEndpoint(gpa: std.mem.Allocator, status_json: []const u8) ![]u8 {
    const Status = struct { endpoint: []const u8 };
    const parsed = std.json.parseFromSlice(Status, gpa, status_json, .{
        .ignore_unknown_fields = true,
    }) catch return error.NoRexServer;
    defer parsed.deinit();
    if (parsed.value.endpoint.len == 0) return error.NoRexServer;
    return gpa.dupe(u8, parsed.value.endpoint);
}

const testing = std.testing;

test "parseEndpoint takes the endpoint and skips the rest" {
    const json =
        \\{"endpoint": "unix:///run/user/1000/rex/server.sock", "pid": 805,
        \\ "tailscale": {"state": "running"}}
    ;
    const got = try parseEndpoint(testing.allocator, json);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("unix:///run/user/1000/rex/server.sock", got);
}

test "parseEndpoint fails without an endpoint" {
    try testing.expectError(error.NoRexServer, parseEndpoint(testing.allocator, "{\"pid\": 1}"));
    try testing.expectError(error.NoRexServer, parseEndpoint(testing.allocator, "{\"endpoint\": \"\"}"));
    try testing.expectError(error.NoRexServer, parseEndpoint(testing.allocator, "Error: rex server is not running"));
}
