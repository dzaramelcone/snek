//! TCP listener, socket options, and connection management.
//! Generic over IO backend for testability and platform abstraction.
//!
//! Design: Two-timeout model (request + keepalive) from http.zig.
//! Connection struct owns two arenas: conn_arena (connection lifetime)
//! and req_arena (per-request, reset between requests).
//! SO_REUSEPORT support for multi-worker accept.
//!
//! Note: Current implementation uses blocking POSIX calls.
//! Async IO integration (io_uring/kqueue) is Phase 6+scheduler integration.

const std = @import("std");
const posix = std.posix;

/// TCP socket wrapper. Thin handle over a file descriptor.
// Reference: refs/http.zig/INSIGHTS.md — socket handle abstraction
pub const Socket = struct {
    fd: posix.fd_t,

    pub fn close(self: Socket) void {
        posix.close(self.fd);
    }
};

/// Configuration for TCP listener and connections.
pub const TcpConfig = struct {
    /// Maximum number of pending connections in the listen backlog.
    backlog: u31 = 128,
    /// Enable SO_REUSEPORT for kernel-level load balancing across workers.
    // Inspired by: http.zig (refs/http.zig/INSIGHTS.md) — SO_REUSEPORT multi-worker accept
    reuseport: bool = true,
    /// Enable TCP_NODELAY (disable Nagle's algorithm).
    nodelay: bool = true,
    /// Timeout in seconds for reading a complete HTTP request.
    // Inspired by: http.zig (refs/http.zig/INSIGHTS.md) — two-timeout model (request + keepalive)
    request_timeout_s: u32 = 30,
    /// Timeout in seconds for idle keepalive connections.
    // Inspired by: http.zig (refs/http.zig/INSIGHTS.md) — two-timeout model (request + keepalive)
    keepalive_timeout_s: u32 = 75,
    /// Maximum requests per keepalive connection (0 = unlimited).
    max_requests_per_conn: u32 = 0,
    /// Maximum total concurrent connections.
    max_connections: u32 = 8192,
};

/// A single TCP connection with two-arena memory model.
///
/// - `conn_arena`: Lives for the entire connection lifetime.
/// - `req_arena`: Reset between requests on the same keepalive connection.
// Inspired by: http.zig (refs/http.zig/INSIGHTS.md) — two arenas per connection (conn_arena + req_arena)
pub fn Connection(comptime IO: type) type {
    return struct {
        const Self = @This();

        socket: Socket,
        io: *IO,

        /// Connection-scoped arena. Freed when connection closes.
        conn_arena: std.heap.ArenaAllocator,
        /// Per-request arena. Reset between keepalive requests.
        req_arena: std.heap.ArenaAllocator,

        /// Number of requests served on this connection.
        request_count: u32 = 0,
        /// Whether the connection should be kept alive after the current request.
        keepalive: bool = true,

        /// Timeout state — which timeout is currently active.
        timeout_state: TimeoutState = .request,

        // Inspired by: http.zig (refs/http.zig/INSIGHTS.md) — two-timeout model (request + keepalive)
        pub const TimeoutState = enum {
            /// Waiting for a complete request (headers + body).
            request,
            /// Idle between requests on a keepalive connection.
            keepalive,
        };

        pub fn init(allocator: std.mem.Allocator, socket: Socket, io: *IO) Self {
            return .{
                .socket = socket,
                .io = io,
                .conn_arena = std.heap.ArenaAllocator.init(allocator),
                .req_arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        pub fn close(self: *Self) void {
            self.socket.close();
            self.req_arena.deinit();
            self.conn_arena.deinit();
        }

        pub fn setNodelay(self: *Self, enable: bool) !void {
            const val: c_int = if (enable) 1 else 0;
            try posix.setsockopt(self.socket.fd, posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &std.mem.toBytes(val));
        }

        pub fn setKeepalive(self: *Self, enable: bool) !void {
            const val: c_int = if (enable) 1 else 0;
            try posix.setsockopt(self.socket.fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &std.mem.toBytes(val));
        }

        /// Reset the per-request arena for the next request on a keepalive connection.
        pub fn resetRequestArena(self: *Self) void {
            _ = self.req_arena.reset(.{ .retain_with_limit = 8192 });
        }

        /// Transition timeout state after a request completes.
        pub fn transitionToKeepalive(self: *Self) void {
            self.timeout_state = .keepalive;
        }

        /// Transition timeout state when a new request begins.
        pub fn transitionToRequest(self: *Self) void {
            self.timeout_state = .request;
            self.request_count += 1;
        }

        pub fn send(self: *Self, data: []const u8) !usize {
            return posix.send(self.socket.fd, data, 0);
        }

        pub fn recv(self: *Self, buf: []u8) !usize {
            return posix.recv(self.socket.fd, buf, 0);
        }
    };
}

/// TCP listener with SO_REUSEPORT support, generic over IO backend.
// Inspired by: http.zig (refs/http.zig/INSIGHTS.md) — SO_REUSEPORT with EPOLLEXCLUSIVE thundering-herd mitigation
pub fn Listener(comptime IO: type) type {
    return struct {
        const Self = @This();

        socket: Socket,
        config: TcpConfig,
        io: *IO,
        bound_addr: posix.sockaddr.in,

        pub fn listen(io: *IO, addr: []const u8, port: u16, config: TcpConfig) !Self {
            const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
            errdefer posix.close(fd);

            // SO_REUSEADDR — allow rapid rebind after restart
            try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

            // SO_REUSEPORT if configured
            if (config.reuseport) {
                try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            }

            const net_addr = try std.net.Address.parseIp4(addr, port);
            try posix.bind(fd, &net_addr.any, net_addr.getOsSockLen());

            // Listen
            try posix.listen(fd, config.backlog);

            // Retrieve actual bound address (needed when port=0)
            var bound: posix.sockaddr.in = undefined;
            var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            try posix.getsockname(fd, @ptrCast(&bound), &len);

            return .{
                .socket = .{ .fd = fd },
                .config = config,
                .io = io,
                .bound_addr = bound,
            };
        }

        pub fn accept(self: *Self, allocator: std.mem.Allocator) !Connection(IO) {
            var remote: posix.sockaddr.in = undefined;
            var remote_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            const accepted_fd = try posix.accept(self.socket.fd, @ptrCast(&remote), &remote_len, 0);

            return Connection(IO).init(allocator, .{ .fd = accepted_fd }, self.io);
        }

        pub fn close(self: *Self) void {
            self.socket.close();
        }

        /// Get the port the listener is bound to (useful when binding to port 0).
        pub fn getPort(self: *const Self) u16 {
            return std.mem.bigToNative(u16, self.bound_addr.port);
        }

        /// Enable SO_REUSEPORT for kernel load balancing across workers.
        /// On macOS/BSD, uses SO_REUSEPORT.
        pub fn setReuseport(self: *Self, enable: bool) !void {
            const val: c_int = if (enable) 1 else 0;
            try posix.setsockopt(self.socket.fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(val));
        }
    };
}

// -- Test helpers --
const FakeIO = struct {
    dummy: u8 = 0,
};

test "tcp listener bind and listen" {
    var io = FakeIO{};
    var listener = Listener(FakeIO).listen(&io, "127.0.0.1", 0, .{}) catch unreachable;
    defer listener.close();

    std.testing.expect(listener.socket.fd >= 0) catch unreachable;
    std.testing.expect(listener.getPort() != 0) catch unreachable;
}

test "tcp accept connection" {
    var io = FakeIO{};
    var listener = Listener(FakeIO).listen(&io, "127.0.0.1", 0, .{}) catch unreachable;
    defer listener.close();

    // Client connects
    const client_fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch unreachable;
    defer posix.close(client_fd);
    posix.connect(client_fd, @ptrCast(&listener.bound_addr), @sizeOf(posix.sockaddr.in)) catch unreachable;

    // Accept
    var conn = listener.accept(std.testing.allocator) catch unreachable;
    defer conn.close();

    std.testing.expect(conn.socket.fd >= 0) catch unreachable;
}

test "tcp connection socket options" {
    var io = FakeIO{};
    var listener = Listener(FakeIO).listen(&io, "127.0.0.1", 0, .{}) catch unreachable;
    defer listener.close();

    const client_fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch unreachable;
    defer posix.close(client_fd);
    posix.connect(client_fd, @ptrCast(&listener.bound_addr), @sizeOf(posix.sockaddr.in)) catch unreachable;

    var conn = listener.accept(std.testing.allocator) catch unreachable;
    defer conn.close();

    // These should not error on a valid socket
    conn.setNodelay(true) catch unreachable;
    conn.setKeepalive(true) catch unreachable;
    conn.setNodelay(false) catch unreachable;
    conn.setKeepalive(false) catch unreachable;
}

test "tcp send and recv" {
    var io = FakeIO{};
    var listener = Listener(FakeIO).listen(&io, "127.0.0.1", 0, .{}) catch unreachable;
    defer listener.close();

    const client_fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch unreachable;
    defer posix.close(client_fd);
    posix.connect(client_fd, @ptrCast(&listener.bound_addr), @sizeOf(posix.sockaddr.in)) catch unreachable;

    var conn = listener.accept(std.testing.allocator) catch unreachable;
    defer conn.close();

    // Client sends, server recvs
    _ = posix.send(client_fd, "hello", 0) catch unreachable;
    var buf: [64]u8 = undefined;
    const n = conn.recv(&buf) catch unreachable;
    try std.testing.expectEqualStrings("hello", buf[0..n]);

    // Server sends, client recvs
    _ = conn.send("world") catch unreachable;
    const n2 = posix.recv(client_fd, &buf, 0) catch unreachable;
    try std.testing.expectEqualStrings("world", buf[0..n2]);
}

test "tcp listener close" {
    var io = FakeIO{};
    var listener = Listener(FakeIO).listen(&io, "127.0.0.1", 0, .{}) catch unreachable;
    const fd = listener.socket.fd;
    try std.testing.expect(fd >= 0);
    listener.close();
    // Verify: opening a new socket can now reuse the fd range (close succeeded).
    // No crash = close worked. We can't portably check EBADF in Zig's posix
    // wrapper because it marks BADF as unreachable.
}

test "tcp so_reuseport" {
    var io = FakeIO{};
    // Listen with reuseport=true (default)
    var l1 = Listener(FakeIO).listen(&io, "127.0.0.1", 0, .{ .reuseport = true }) catch unreachable;
    defer l1.close();

    // Disable reuseport on the same listener
    l1.setReuseport(false) catch unreachable;
    // Re-enable
    l1.setReuseport(true) catch unreachable;
}

test "tcp two-timeout model" {
    var io = FakeIO{};
    var listener = Listener(FakeIO).listen(&io, "127.0.0.1", 0, .{}) catch unreachable;
    defer listener.close();

    const client_fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch unreachable;
    defer posix.close(client_fd);
    posix.connect(client_fd, @ptrCast(&listener.bound_addr), @sizeOf(posix.sockaddr.in)) catch unreachable;

    var conn = listener.accept(std.testing.allocator) catch unreachable;
    defer conn.close();

    // Initial state: request, count=0
    try std.testing.expectEqual(Connection(FakeIO).TimeoutState.request, conn.timeout_state);
    try std.testing.expectEqual(@as(u32, 0), conn.request_count);

    // Transition to keepalive (request complete)
    conn.transitionToKeepalive();
    try std.testing.expectEqual(Connection(FakeIO).TimeoutState.keepalive, conn.timeout_state);

    // Transition to request (new request arrives), increments count
    conn.transitionToRequest();
    try std.testing.expectEqual(Connection(FakeIO).TimeoutState.request, conn.timeout_state);
    try std.testing.expectEqual(@as(u32, 1), conn.request_count);

    // Another cycle
    conn.transitionToKeepalive();
    conn.transitionToRequest();
    try std.testing.expectEqual(@as(u32, 2), conn.request_count);
}

test "tcp connection arena reset" {
    var io = FakeIO{};
    var listener = Listener(FakeIO).listen(&io, "127.0.0.1", 0, .{}) catch unreachable;
    defer listener.close();

    const client_fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch unreachable;
    defer posix.close(client_fd);
    posix.connect(client_fd, @ptrCast(&listener.bound_addr), @sizeOf(posix.sockaddr.in)) catch unreachable;

    var conn = listener.accept(std.testing.allocator) catch unreachable;
    defer conn.close();

    // Allocate from req_arena
    const alloc = conn.req_arena.allocator();
    const slice = alloc.alloc(u8, 128) catch unreachable;
    @memset(slice, 0xAA);

    // Reset
    conn.resetRequestArena();

    // Allocate again — should succeed (arena reuses memory)
    const slice2 = alloc.alloc(u8, 128) catch unreachable;
    _ = slice2;

    // conn_arena should be independent
    const conn_alloc = conn.conn_arena.allocator();
    const conn_slice = conn_alloc.alloc(u8, 64) catch unreachable;
    _ = conn_slice;
}

test "tcp keepalive multiple requests" {
    var io = FakeIO{};
    var listener = Listener(FakeIO).listen(&io, "127.0.0.1", 0, .{}) catch unreachable;
    defer listener.close();

    const client_fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch unreachable;
    defer posix.close(client_fd);
    posix.connect(client_fd, @ptrCast(&listener.bound_addr), @sizeOf(posix.sockaddr.in)) catch unreachable;

    var conn = listener.accept(std.testing.allocator) catch unreachable;
    defer conn.close();

    // First request
    _ = posix.send(client_fd, "GET /1", 0) catch unreachable;
    var buf: [64]u8 = undefined;
    const n1 = conn.recv(&buf) catch unreachable;
    try std.testing.expectEqualStrings("GET /1", buf[0..n1]);

    // Transition: request done -> keepalive -> new request
    conn.transitionToKeepalive();
    conn.resetRequestArena();
    conn.transitionToRequest();

    // Second request on same connection
    _ = posix.send(client_fd, "GET /2", 0) catch unreachable;
    const n2 = conn.recv(&buf) catch unreachable;
    try std.testing.expectEqualStrings("GET /2", buf[0..n2]);

    try std.testing.expectEqual(@as(u32, 1), conn.request_count);
}
