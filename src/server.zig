//! Integrated snek HTTP server.
//!
//! Per-worker accept architecture:
//!   - Each worker thread binds its own listen socket (SO_REUSEPORT)
//!   - Kernel load-balances incoming connections across workers
//!   - Each worker runs: accept → recv → parse → route → respond → close
//!   - No cross-thread handoff for the hot path
//!
//! This matches zzz, http.zig, nginx, and Go net/http.

const std = @import("std");
const posix = std.posix;
const router_mod = @import("http/router.zig");
const http1 = @import("net/http1.zig");
const response_mod = @import("http/response.zig");

pub const HandlerFn = *const fn (*const http1.Parser) response_mod.Response;

pub const Config = struct {
    num_threads: u32 = 0, // 0 = auto-detect CPU count
};

pub const Server = struct {
    router: router_mod.Router,
    handlers: [64]?HandlerFn,
    handler_count: u32,
    allocator: std.mem.Allocator,
    num_threads: u32,
    bind_addr: []const u8,
    bind_port: u16,
    listen_fd: ?posix.socket_t, // main thread's listen fd (for getPort)
    running: std.atomic.Value(bool),
    workers: []std.Thread,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Server {
        const num_threads = if (config.num_threads == 0)
            @as(u32, @intCast(@max(1, std.Thread.getCpuCount() catch 1)))
        else
            config.num_threads;

        return .{
            .router = router_mod.Router.init(allocator),
            .handlers = .{null} ** 64,
            .handler_count = 0,
            .allocator = allocator,
            .num_threads = num_threads,
            .bind_addr = "127.0.0.1",
            .bind_port = 0,
            .listen_fd = null,
            .running = std.atomic.Value(bool).init(false),
            .workers = &.{},
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.listen_fd) |fd| {
            posix.close(fd);
            self.listen_fd = null;
        }
        if (self.workers.len > 0) {
            self.allocator.free(self.workers);
        }
        self.router.deinit();
    }

    pub fn addRoute(self: *Server, method: router_mod.Method, path: []const u8, handler: HandlerFn) !void {
        const id = self.handler_count;
        if (id >= 64) return error.TooManyHandlers;
        self.handlers[id] = handler;
        self.handler_count = id + 1;
        self.router.addRoute(method, path, id) catch |err| return err;
    }

    pub fn listen(self: *Server, addr: []const u8, port: u16) !void {
        self.bind_addr = addr;
        self.bind_port = port;
        // Create one listen fd on main thread to get the bound port
        const fd = try createListenSocket(addr, port);
        self.listen_fd = fd;
        // Read back actual port (for ephemeral port 0)
        var bound: posix.sockaddr.in = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        try posix.getsockname(fd, @ptrCast(&bound), &len);
        self.bind_port = std.mem.bigToNative(u16, bound.port);
    }

    pub fn getPort(self: *const Server) u16 {
        return self.bind_port;
    }

    /// Run the server. Blocks until shutdown() is called.
    /// Spawns N worker threads, each with its own listen socket (SO_REUSEPORT).
    pub fn run(self: *Server) !void {
        self.running.store(true, .release);

        self.workers = try self.allocator.alloc(std.Thread, self.num_threads);
        errdefer self.allocator.free(self.workers);

        // Spawn worker threads — each creates its own listen socket
        var spawned: u32 = 0;
        errdefer {
            self.running.store(false, .release);
            for (self.workers[0..spawned]) |w| w.join();
        }

        for (0..self.num_threads) |i| {
            self.workers[i] = try std.Thread.spawn(.{}, workerLoop, .{self});
            spawned += 1;
        }

        // Main thread also accepts (use the existing listen fd)
        workerAcceptLoop(self, self.listen_fd.?);

        // Wait for all workers
        for (self.workers[0..self.num_threads]) |w| w.join();
    }

    pub fn shutdown(self: *Server) void {
        self.running.store(false, .release);
        // Close the main thread's listen fd to unblock its accept
        if (self.listen_fd) |fd| {
            posix.close(fd);
            self.listen_fd = null;
        }
    }

    // ── Worker logic ─────────────────────────────────────────────

    fn workerLoop(self: *Server) void {
        // Each worker creates its own listen socket on the same port
        const fd = createListenSocket(self.bind_addr, self.bind_port) catch return;
        defer posix.close(fd);
        workerAcceptLoop(self, fd);
    }

    fn workerAcceptLoop(self: *Server, fd: posix.socket_t) void {
        var poll_fds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        while (self.running.load(.acquire)) {
            const ready = posix.poll(&poll_fds, 10) catch continue;
            if (ready == 0) continue;

            // Drain all pending connections
            while (self.running.load(.acquire)) {
                var client_addr: posix.sockaddr = undefined;
                var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
                const client_fd = posix.accept(fd, &client_addr, &client_addr_len, 0) catch |err| {
                    if (err == error.WouldBlock) break;
                    break;
                };
                self.handleConnection(client_fd);
            }
        }
    }

    fn handleConnection(self: *const Server, fd: posix.socket_t) void {
        defer posix.close(fd);

        // Clear non-blocking flag — on macOS, accepted sockets inherit
        // O_NONBLOCK from the listener. We want blocking recv/send.
        const fl = posix.fcntl(fd, posix.F.GETFL, @as(usize, 0)) catch unreachable;
        const nonblock: usize = @intCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
        _ = posix.fcntl(fd, posix.F.SETFL, fl & ~nonblock) catch unreachable;

        var read_buf: [4096]u8 = undefined;
        const n = posix.recv(fd, &read_buf, 0) catch |err| {
            std.debug.panic("recv failed: {}", .{err});
        };
        if (n == 0) return; // client closed cleanly

        var parse_buf: [8192]u8 = undefined;
        var parser = http1.Parser.init(&parse_buf);
        _ = parser.feed(read_buf[0..n]) catch {
            const bad = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = posix.send(fd, bad, 0) catch |err| std.debug.panic("send failed: {}", .{err});
            return;
        };

        const method_str = if (parser.method) |m| @tagName(m) else "GET";
        const method = router_mod.Method.fromString(method_str) orelse .GET;
        const path = parser.uri orelse "/";
        const match_result = self.router.match(method, path);

        var resp_buf: [8192]u8 = undefined;
        const response_bytes: []const u8 = switch (match_result) {
            .found => |found| blk: {
                if (found.handler_id < self.handler_count) {
                    if (self.handlers[found.handler_id]) |handler| {
                        var resp = handler(&parser);
                        _ = resp.setHeader("Connection", "close");
                        const resp_n = resp.serialize(&resp_buf) catch |err| std.debug.panic("serialize failed: {}", .{err});
                        break :blk resp_buf[0..resp_n];
                    }
                }
                break :blk "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            },
            .not_found => blk: {
                var resp = response_mod.Response.notFound();
                _ = resp.setHeader("Connection", "close");
                const resp_n = resp.serialize(&resp_buf) catch |err| std.debug.panic("serialize failed: {}", .{err});
                break :blk resp_buf[0..resp_n];
            },
            .method_not_allowed => "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        };

        _ = posix.send(fd, response_bytes, 0) catch |err| std.debug.panic("send failed: {}", .{err});
    }
};

fn createListenSocket(addr: []const u8, port: u16) !posix.socket_t {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));

    // Non-blocking for poll-based accept
    const flags = try posix.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    const nonblock: usize = @intCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock);

    var bind_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = parseIpv4(addr),
    };
    try posix.bind(fd, @ptrCast(&bind_addr), @sizeOf(posix.sockaddr.in));
    try posix.listen(fd, 128);

    return fd;
}

fn parseIpv4(addr: []const u8) u32 {
    var octets: [4]u8 = .{ 0, 0, 0, 0 };
    var octet_idx: usize = 0;
    var val: u8 = 0;
    for (addr) |c| {
        if (c == '.') {
            octets[octet_idx] = val;
            octet_idx += 1;
            val = 0;
        } else {
            val = val * 10 + (c - '0');
        }
    }
    octets[octet_idx] = val;
    return @bitCast(octets);
}

// ── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "server starts and stops" {
    var srv = try Server.init(testing.allocator, .{ .num_threads = 2 });
    defer srv.deinit();

    try srv.listen("127.0.0.1", 0);
    try testing.expect(srv.getPort() != 0);

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(s: *Server) void { s.run() catch {}; }
    }.entry, .{&srv});

    std.Thread.sleep(20 * std.time.ns_per_ms);
    srv.shutdown();
    t.join();
}

test "server handles one request" {
    var srv = try Server.init(testing.allocator, .{ .num_threads = 2 });
    defer srv.deinit();

    try srv.addRoute(.GET, "/", &struct {
        fn h(_: *const http1.Parser) response_mod.Response {
            return response_mod.Response.text("hello snek");
        }
    }.h);

    try srv.listen("127.0.0.1", 0);
    const port = srv.getPort();

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(s: *Server) void { s.run() catch {}; }
    }.entry, .{&srv});
    std.Thread.sleep(20 * std.time.ns_per_ms);

    const cfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(cfd);
    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = parseIpv4("127.0.0.1"),
    };
    try posix.connect(cfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    _ = try posix.send(cfd, "GET / HTTP/1.1\r\nHost: h\r\n\r\n", 0);

    std.Thread.sleep(50 * std.time.ns_per_ms);
    var buf: [4096]u8 = undefined;
    const n = try posix.recv(cfd, &buf, 0);
    const resp = buf[0..n];

    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, resp, "hello snek") != null);

    srv.shutdown();
    t.join();
}

test "server handles concurrent requests" {
    var srv = try Server.init(testing.allocator, .{ .num_threads = 2 });
    defer srv.deinit();

    try srv.addRoute(.GET, "/ping", &struct {
        fn h(_: *const http1.Parser) response_mod.Response {
            return response_mod.Response.text("pong");
        }
    }.h);

    try srv.listen("127.0.0.1", 0);
    const port = srv.getPort();

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(s: *Server) void { s.run() catch {}; }
    }.entry, .{&srv});
    std.Thread.sleep(20 * std.time.ns_per_ms);

    var success = std.atomic.Value(u32).init(0);
    var threads: [10]std.Thread = undefined;
    for (&threads) |*th| {
        th.* = try std.Thread.spawn(.{}, struct {
            fn req(p: u16, cnt: *std.atomic.Value(u32)) void {
                const cfd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return;
                defer posix.close(cfd);
                var a = posix.sockaddr.in{ .family = posix.AF.INET, .port = std.mem.nativeToBig(u16, p), .addr = parseIpv4("127.0.0.1") };
                posix.connect(cfd, @ptrCast(&a), @sizeOf(posix.sockaddr.in)) catch return;
                _ = posix.send(cfd, "GET /ping HTTP/1.1\r\nHost: h\r\n\r\n", 0) catch return;
                std.Thread.sleep(50 * std.time.ns_per_ms);
                var buf: [4096]u8 = undefined;
                const n = posix.recv(cfd, &buf, 0) catch return;
                if (n > 0 and std.mem.indexOf(u8, buf[0..n], "pong") != null)
                    _ = cnt.fetchAdd(1, .monotonic);
            }
        }.req, .{ port, &success });
    }
    for (&threads) |*th| th.join();

    srv.shutdown();
    t.join();

    try testing.expectEqual(@as(u32, 10), success.load(.acquire));
}

test "server handles 404" {
    var srv = try Server.init(testing.allocator, .{ .num_threads = 1 });
    defer srv.deinit();

    try srv.addRoute(.GET, "/exists", &struct {
        fn h(_: *const http1.Parser) response_mod.Response {
            return response_mod.Response.text("here");
        }
    }.h);

    try srv.listen("127.0.0.1", 0);
    const port = srv.getPort();

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(s: *Server) void { s.run() catch {}; }
    }.entry, .{&srv});
    std.Thread.sleep(20 * std.time.ns_per_ms);

    const cfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(cfd);
    var addr = posix.sockaddr.in{ .family = posix.AF.INET, .port = std.mem.nativeToBig(u16, port), .addr = parseIpv4("127.0.0.1") };
    try posix.connect(cfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    _ = try posix.send(cfd, "GET /nope HTTP/1.1\r\nHost: h\r\n\r\n", 0);

    std.Thread.sleep(50 * std.time.ns_per_ms);
    var buf: [4096]u8 = undefined;
    const n = try posix.recv(cfd, &buf, 0);

    try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 404"));

    srv.shutdown();
    t.join();
}
