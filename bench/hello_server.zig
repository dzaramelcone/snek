//! Minimal snek HTTP server for benchmarking.
//!
//! Single-threaded blocking server. Accepts connections, parses HTTP,
//! sends a fixed JSON response. Handles keepalive.
//!
//! Usage:
//!   zig build-exe -OReleaseFast bench/hello_server.zig && ./hello_server
//!   hey -n 10000 -c 50 http://127.0.0.1:8080/
//!
//! Compare against:
//!   - zzz (Zig HTTP framework)
//!   - http.zig (karlseguin)
//!   - Zig stdlib HTTP server
//!   - Go net/http
//!   - Rust actix-web / hyper

const std = @import("std");
const posix = std.posix;

const RESPONSE_BODY = "{\"message\":\"hello from snek\"}";
const RESPONSE_KEEPALIVE =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 28\r\n" ++
    "Connection: keep-alive\r\n" ++
    "\r\n" ++
    RESPONSE_BODY;
const RESPONSE_CLOSE =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 28\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    RESPONSE_BODY;

const PORT: u16 = 8080;

pub fn main() !void {
    // Create, bind, listen
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(fd);

    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, PORT);
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 128);

    std.debug.print("snek hello server listening on http://127.0.0.1:{d}/\n", .{PORT});

    // Accept loop (single-threaded, blocking)
    while (true) {
        var client_addr: posix.sockaddr = undefined;
        var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const client_fd = posix.accept(fd, &client_addr, &client_addr_len, 0) catch continue;

        handleConnection(client_fd) catch {
            posix.close(client_fd);
            continue;
        };
        posix.close(client_fd);
    }
}

fn handleConnection(client_fd: posix.socket_t) !void {
    var buf: [4096]u8 = undefined;

    // Simple keepalive loop
    while (true) {
        const n = posix.recv(client_fd, &buf, 0) catch return;
        if (n == 0) return; // client closed

        // Check if request contains Connection: close
        const request = buf[0..n];
        const close = std.mem.indexOf(u8, request, "Connection: close") != null;

        // Send response
        const response = if (close) RESPONSE_CLOSE else RESPONSE_KEEPALIVE;
        _ = posix.send(client_fd, response, 0) catch return;

        if (close) return;
    }
}
