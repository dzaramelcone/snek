//! snek hello world server — multi-threaded via the Server integration.
//!
//! Uses Server(FakeIO) for the scheduler backend. Workers handle connections
//! with blocking recv/send. Scheduler dispatches accepted fds to workers via
//! the deque/steal infrastructure.
//!
//! Usage:
//!   cd /path/to/snek
//!   zig run src/hello_server.zig
//!   curl http://localhost:8080/
//!   curl http://localhost:8080/health

const std = @import("std");
const server_mod = @import("server.zig");
const http1 = @import("net/http1.zig");
const Response = @import("http/response.zig").Response;
const FakeIO = @import("core/fake_io.zig").FakeIO;

const PORT: u16 = 8080;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var srv = try server_mod.Server(FakeIO).init(allocator, .{
        .num_threads = 4,
    });
    defer srv.deinit();

    try srv.addRoute(.GET, "/", &handleRoot);
    try srv.addRoute(.GET, "/health", &handleHealth);

    try srv.listen("0.0.0.0", PORT);

    std.debug.print(
        \\
        \\  snek is listening on http://127.0.0.1:{d}/
        \\
        \\  Routes:
        \\    GET /       -> hello world
        \\    GET /health -> health check
        \\
        \\  Workers: 4 threads
        \\
        \\
    , .{PORT});

    try srv.run();
}

fn handleRoot(_: *const http1.Parser) Response {
    return Response.json("{\"message\":\"hello from snek\"}");
}

fn handleHealth(_: *const http1.Parser) Response {
    return Response.json("{\"status\":\"ok\"}");
}
