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
    // no autostart: a new server wouldn't know this terminal's session
    const out = rexJson(gpa, io, &.{ "server", "status", "--autostart=false", "--json" }) catch return error.NoRexServer;
    defer gpa.free(out);
    return parseEndpoint(gpa, out);
}

/// Whether this terminal is a Rex pane: Rex sets `REX_BLOCK` in every pane.
pub fn inRex() bool {
    return std.c.getenv("REX_BLOCK") != null;
}

/// The session that holds this terminal's pane. Rex doesn't put it in the
/// environment, so asks `rex whoami`, which finds it from `REX_BLOCK`. The
/// caller owns the result.
pub fn sessionId(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    if (!inRex()) return error.NotInRex;
    const out = rexJson(gpa, io, &.{ "whoami", "--json" }) catch return error.NotInRex;
    defer gpa.free(out);
    return parseSessionId(gpa, out);
}

/// Stdout of a `rex` command that succeeded. The caller owns the result.
fn rexJson(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) ![]u8 {
    // the `rex` this terminal came from, else the one on PATH
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = if (std.c.getenv("REX_BIN_DIR")) |dir|
        try std.fmt.bufPrint(&exe_buf, "{s}/rex", .{std.mem.span(dir)})
    else
        "rex";
    var argv_buf: [8][]const u8 = undefined;
    argv_buf[0] = exe;
    @memcpy(argv_buf[1..][0..args.len], args);
    const r = try std.process.run(gpa, io, .{
        .argv = argv_buf[0 .. args.len + 1],
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer gpa.free(r.stderr);
    errdefer gpa.free(r.stdout);
    if (!r.term.success()) return error.RexFailed;
    return r.stdout;
}

/// The `session_id` field of `rex whoami --json`. The caller owns the result.
pub fn parseSessionId(gpa: std.mem.Allocator, whoami_json: []const u8) ![]u8 {
    const Whoami = struct { session_id: []const u8 = "" };
    const parsed = std.json.parseFromSlice(Whoami, gpa, whoami_json, .{
        .ignore_unknown_fields = true,
    }) catch return error.NotInRex;
    defer parsed.deinit();
    if (parsed.value.session_id.len == 0) return error.NotInRex;
    return gpa.dupe(u8, parsed.value.session_id);
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

test "parseSessionId takes the session and fails without one" {
    const json =
        \\{"account": "me", "session_id": "session:s", "block_id": "block:b"}
    ;
    const got = try parseSessionId(testing.allocator, json);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("session:s", got);
    try testing.expectError(error.NotInRex, parseSessionId(testing.allocator, "{\"account\": \"me\"}"));
}
