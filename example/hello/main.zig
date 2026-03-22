//! snek hello world server — multi-threaded via the Server integration.
//!
//! Uses Server(FakeIO) for the scheduler backend. Workers handle connections
//! with blocking recv/send. Scheduler dispatches accepted fds to workers via
//! the deque/steal infrastructure.
//!
//! Usage:
//!   cd /path/to/snek
//!   zig build-exe -OReleaseFast example/hello/main.zig -femit-bin=hello && ./hello
//!   curl http://localhost:8080/
//!   curl http://localhost:8080/users/42
//!   curl http://localhost:8080/health

const std = @import("std");
const server_mod = @import("../../src/server.zig");
const http1 = @import("../../src/net/http1.zig");
const Response = @import("../../src/http/response.zig").Response;
const FakeIO = @import("../../src/core/fake_io.zig").FakeIO;

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
    try srv.addRoute(.GET, "/users/{id}", &handleUser);

    try srv.listen("0.0.0.0", PORT);

    std.debug.print(
        \\
        \\  snek is listening on http://127.0.0.1:{d}/
        \\
        \\  Routes:
        \\    GET /            -> hello world
        \\    GET /health      -> health check
        \\    GET /users/{{id}} -> user by ID
        \\
        \\  Workers: 4 threads
        \\
        \\
    , .{PORT});

    // Blocks until shutdown (Ctrl-C closes the process)
    try srv.run();
}

fn handleRoot(_: *const http1.Parser) Response {
    return Response.json("{\"message\":\"hello from snek\"}");
}

fn handleHealth(_: *const http1.Parser) Response {
    return Response.json("{\"status\":\"ok\"}");
}

fn handleUser(_: *const http1.Parser) Response {
    // In a real app, we'd extract the {id} param from the match result.
    // The handler currently only has access to the parser, not the match result.
    // For now, return a static response.
    return Response.json("{\"user\":\"snek user\"}");
}
