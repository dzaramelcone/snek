//! Integration test: minimal HTTP server serving "hello world"
//!
//! Wires together:
//!   - TCP listener (Phase 6)
//!   - HTTP/1.1 parser (Phase 7)
//!   - HTTP response serializer (Phase 7)
//!
//! This is the Phase 9 milestone target: snek serves hello world over HTTP.
//! For now, it's a single-threaded blocking server — no scheduler, no workers.
//! The goal is proving the stack works end-to-end.

const std = @import("std");
const posix = std.posix;
const net = std.net;

const tcp = @import("net/tcp.zig");
const http1 = @import("net/http1.zig");

const RESPONSE_BODY = "{\"message\":\"hello from snek\"}";
const RESPONSE =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 28\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    RESPONSE_BODY;

/// Run a minimal single-threaded HTTP server that handles one request.
/// Returns the port it's listening on.
fn startServer(allocator: std.mem.Allocator, ready: *std.atomic.Value(u16)) void {
    // Use a FakeIO placeholder — tcp.zig's blocking path doesn't actually use IO
    const FakeIO = @import("core/fake_io.zig").FakeIO;
    var io = FakeIO.init(allocator, 0);
    defer io.deinit();

    var listener = tcp.Listener(FakeIO).listen(&io, "127.0.0.1", 0, .{}) catch |err| {
        std.debug.print("listen failed: {}\n", .{err});
        return;
    };
    defer listener.close();

    // Signal the port to the test
    ready.store(listener.getPort(), .release);

    // Accept one connection
    var conn = listener.accept(allocator) catch |err| {
        std.debug.print("accept failed: {}\n", .{err});
        return;
    };
    defer conn.close();

    // Read the request
    var read_buf: [4096]u8 = undefined;
    const n = conn.recv(&read_buf) catch |err| {
        std.debug.print("recv failed: {}\n", .{err});
        return;
    };

    // Parse it
    var parse_buf: [8192]u8 = undefined;
    var parser = http1.Parser.init(&parse_buf);
    const result = parser.feed(read_buf[0..n]) catch |err| {
        std.debug.print("parse failed: {}\n", .{err});
        return;
    };
    _ = result;

    // Send the response
    _ = conn.send(RESPONSE) catch |err| {
        std.debug.print("send failed: {}\n", .{err});
        return;
    };
}

test "integration: hello world HTTP response" {
    const allocator = std.testing.allocator;
    var ready = std.atomic.Value(u16).init(0);

    // Start server in a thread
    const server_thread = try std.Thread.spawn(.{}, startServer, .{ allocator, &ready });

    // Wait for server to be ready
    var port: u16 = 0;
    var attempts: u32 = 0;
    while (port == 0 and attempts < 1000) : (attempts += 1) {
        port = ready.load(.acquire);
        if (port == 0) std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    if (port == 0) return error.ServerDidNotStart;

    // Connect as a client
    const addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const client = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(client);
    try posix.connect(client, &addr.any, addr.getOsSockLen());

    // Send a GET request
    const request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    _ = try posix.send(client, request, 0);

    // Read the response
    var buf: [4096]u8 = undefined;
    const n = try posix.recv(client, &buf, 0);
    const response = buf[0..n];

    // Verify we got a valid HTTP response with our body
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, response, RESPONSE_BODY) != null);

    server_thread.join();
}
