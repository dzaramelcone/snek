//! snek hello world server — the first real snek app.
//!
//! Wires: TCP listener → HTTP parser → router → JSON serializer → response.
//! Single-threaded blocking. Multi-threaded async comes with scheduler integration.
//!
//! Usage:
//!   cd /path/to/snek
//!   zig build-exe -OReleaseFast example/hello/main.zig -femit-bin=hello && ./hello
//!   curl http://localhost:8080/
//!   curl http://localhost:8080/users/42
//!   curl http://localhost:8080/health

const std = @import("std");
const posix = std.posix;

const PORT: u16 = 8080;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Set up routes
    var rtr = Router.init(allocator);
    defer rtr.deinit();

    try rtr.addRoute(.GET, "/", 0);
    try rtr.addRoute(.GET, "/health", 1);
    try rtr.addRoute(.GET, "/users/{id}", 2);

    // Create TCP listener
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(fd);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, PORT);
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 128);

    std.debug.print(
        \\
        \\  snek is listening on http://127.0.0.1:{d}/
        \\
        \\  Routes:
        \\    GET /            -> hello world
        \\    GET /health      -> health check
        \\    GET /users/{{id}} -> user by ID
        \\
        \\
    , .{PORT});

    // Accept loop
    while (true) {
        var client_addr: posix.sockaddr = undefined;
        var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const client_fd = posix.accept(fd, &client_addr, &client_addr_len, 0) catch continue;
        handleConnection(client_fd, &rtr) catch {};
        posix.close(client_fd);
    }
}

fn handleConnection(client_fd: posix.socket_t, rtr: *const Router) !void {
    var read_buf: [4096]u8 = undefined;
    const n = posix.recv(client_fd, &read_buf, 0) catch return;
    if (n == 0) return;

    // Parse
    var parse_buf: [8192]u8 = undefined;
    var parser = Parser.init(&parse_buf);
    _ = parser.feed(read_buf[0..n]) catch {
        _ = posix.send(client_fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", 0) catch {};
        return;
    };

    // Extract method and path
    const method_str = if (parser.method) |m| @tagName(m) else "GET";
    const method = RouterMethod.fromString(method_str) orelse .GET;
    const path = parser.uri orelse "/";

    // Route
    const result = rtr.match(method, path);

    // Dispatch
    var resp_buf: [4096]u8 = undefined;
    const response: []const u8 = switch (result) {
        .found => |found| blk: {
            const body = switch (found.handler_id) {
                0 => "{\"message\":\"hello from snek\"}",
                1 => "{\"status\":\"ok\"}",
                2 => user_json: {
                    // Get the {id} param
                    var json_buf: [256]u8 = undefined;
                    const id_val = if (found.param_count > 0) found.params[0].value else "?";
                    break :user_json std.fmt.bufPrint(&json_buf, "{{\"user_id\":\"{s}\",\"name\":\"snek user\"}}", .{id_val}) catch "{\"error\":\"format\"}";
                },
                else => "{\"error\":\"unknown route\"}",
            };
            break :blk std.fmt.bufPrint(&resp_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch "HTTP/1.1 500\r\n\r\n";
        },
        .method_not_allowed => "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n",
        .not_found => "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 23\r\n\r\n{\"error\":\"not found\"}",
    };

    _ = posix.send(client_fd, response, 0) catch {};
}

// Imports — using relative paths from example/hello/
const Router = @import("../../src/http/router.zig").Router;
const RouterMethod = @import("../../src/http/router.zig").Method;
const Parser = @import("../../src/net/http1.zig").Parser;
