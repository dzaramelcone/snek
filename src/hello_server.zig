const std = @import("std");
const server_mod = @import("server.zig");
const http1 = @import("net/http1.zig");
const Response = @import("http/response.zig").Response;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var srv = try server_mod.Server.init(gpa.allocator(), .{ .num_threads = 4 });
    defer srv.deinit();

    try srv.addRoute(.GET, "/", &handleRoot);
    try srv.addRoute(.GET, "/health", &handleHealth);

    try srv.listen("0.0.0.0", 8080);

    std.debug.print(
        \\
        \\  snek listening on http://127.0.0.1:8080/
        \\  {d} worker threads (per-worker accept, SO_REUSEPORT)
        \\
        \\
    , .{srv.num_threads});

    try srv.run();
}

fn handleRoot(_: *const http1.Parser) Response {
    return Response.json("{\"message\":\"hello from snek\"}");
}

fn handleHealth(_: *const http1.Parser) Response {
    return Response.json("{\"status\":\"ok\"}");
}
