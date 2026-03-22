//! Integrated snek HTTP server.
//!
//! Hybrid architecture for minimum viable integration:
//!   - Main thread: blocking POSIX accept, wraps fd, pushes via spawnCoroutine
//!   - Workers: blocking recv/send on accepted fds, parse HTTP, route, respond
//!
//! The scheduler dispatches connections to workers via the existing deque/steal
//! infrastructure. Workers process requests on their own threads.
//!
//! Generic over IO for simulation testing (FakeIO) vs production (Kqueue).

const std = @import("std");
const posix = std.posix;
const scheduler_mod = @import("core/scheduler.zig");
const worker_mod = @import("core/worker.zig");
const coroutine = @import("core/coroutine.zig");
const router_mod = @import("http/router.zig");
const http1 = @import("net/http1.zig");
const response_mod = @import("http/response.zig");

/// Handler function type. Receives parsed parser state, returns a Response.
pub const HandlerFn = *const fn (*const http1.Parser) response_mod.Response;

/// Module-level pointer to the active server's handler table.
/// Workers read this from their threads to dispatch requests.
/// Set by Server.run(), cleared by Server.shutdown().
var g_handlers: [64]?HandlerFn = .{null} ** 64;
var g_handler_count: u32 = 0;
var g_router: ?*const router_mod.Router = null;
var g_allocator: ?std.mem.Allocator = null;

pub fn Server(comptime IO: type) type {
    return struct {
        const Self = @This();
        const Scheduler = scheduler_mod.Scheduler(IO);

        scheduler: Scheduler,
        router: router_mod.Router,
        listen_fd: ?posix.socket_t,
        allocator: std.mem.Allocator,
        handlers: [64]?HandlerFn,
        handler_count: u32,

        pub const Config = struct {
            num_threads: u32 = 0,
            accept_queue_capacity: u32 = 1024,
            tcp_backlog: u31 = 128,
        };

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            return .{
                .scheduler = try Scheduler.init(allocator, .{
                    .num_threads = config.num_threads,
                    .accept_queue_capacity = config.accept_queue_capacity,
                    .tcp_backlog = config.tcp_backlog,
                }),
                .router = router_mod.Router.init(allocator),
                .listen_fd = null,
                .allocator = allocator,
                .handlers = .{null} ** 64,
                .handler_count = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.listen_fd) |fd| {
                posix.close(fd);
                self.listen_fd = null;
            }
            self.router.deinit();
            self.scheduler.deinit();
        }

        /// Register a route with its handler function.
        pub fn addRoute(
            self: *Self,
            method: router_mod.Method,
            path: []const u8,
            handler: HandlerFn,
        ) !void {
            const id = self.handler_count;
            if (id >= 64) return error.TooManyHandlers;
            self.handlers[id] = handler;
            self.handler_count = id + 1;
            self.router.addRoute(method, path, id) catch |err| return err;
        }

        /// Bind and listen on the given address and port.
        /// Port 0 selects an ephemeral port (useful for tests).
        pub fn listen(self: *Self, addr: []const u8, port: u16) !void {
            const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch |err| return err;
            errdefer posix.close(fd);

            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch |err| return err;

            var bind_addr = posix.sockaddr.in{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = parseIpv4(addr),
            };
            posix.bind(fd, @ptrCast(&bind_addr), @sizeOf(posix.sockaddr.in)) catch |err| return err;
            posix.listen(fd, 128) catch |err| return err;
            // Set non-blocking so the accept loop can drain all pending
            // connections in one burst, then yield to tick.
            const flags = posix.fcntl(fd, posix.F.GETFL, @as(usize, 0)) catch |err| return err;
            const nonblock: usize = @intCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
            _ = posix.fcntl(fd, posix.F.SETFL, flags | nonblock) catch |err| return err;
            self.listen_fd = fd;
        }

        /// Get the bound port (useful when listening on port 0).
        pub fn getPort(self: *const Self) u16 {
            const fd = self.listen_fd orelse return 0;
            var bound: posix.sockaddr.in = undefined;
            var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            posix.getsockname(fd, @ptrCast(&bound), &len) catch return 0;
            return std.mem.bigToNative(u16, bound.port);
        }

        /// Run the server. Blocks until shutdown() is called from another thread.
        /// 1. Publishes handler table + router to module globals
        /// 2. Sets worker callbacks
        /// 3. Starts the scheduler (which starts worker pool)
        /// 4. Blocking accept loop: accept fd -> wrap in CoroutineFrame -> spawnCoroutine -> tick
        /// 5. On shutdown: scheduler drains, pool stops
        pub fn run(self: *Self) !void {
            const fd = self.listen_fd orelse return error.NotListening;

            // Publish to module globals so worker callbacks can access
            g_handlers = self.handlers;
            g_handler_count = self.handler_count;
            g_router = &self.router;
            g_allocator = self.allocator;

            // Set worker callbacks
            for (self.scheduler.pool.workers) |*w| {
                w.work_callback = &handleConnection;
            }

            // Start scheduler in a background thread (it starts the pool)
            const sched_thread = std.Thread.spawn(.{}, struct {
                fn entry(sched: *Scheduler) void {
                    sched.run() catch {};
                }
            }.entry, .{&self.scheduler}) catch |err| return err;

            // Wait for scheduler to be running
            while (!self.scheduler.running.load(.acquire)) {
                if (self.scheduler.shut_down.load(.acquire)) break;
                std.Thread.yield() catch {};
            }

            // Accept loop using poll() to avoid busy-spinning.
            // poll() blocks until the listen fd has a pending connection,
            // then we accept all pending connections in a burst.
            var poll_fds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};

            while (!self.scheduler.shut_down.load(.acquire)) {
                // Block until a connection is ready (10ms timeout to check shutdown)
                const ready = posix.poll(&poll_fds, 10) catch continue;
                if (ready == 0) continue; // timeout, check shutdown flag

                // Drain all pending connections
                while (true) {
                    var client_addr: posix.sockaddr = undefined;
                    var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
                    const client_fd = posix.accept(fd, &client_addr, &client_addr_len, 0) catch |err| {
                        if (err == error.WouldBlock) break;
                        if (self.scheduler.shut_down.load(.acquire)) break;
                        if (err == error.ProcessFdQuotaExceeded or err == error.SystemFdQuotaExceeded) {
                            std.Thread.sleep(1 * std.time.ns_per_ms);
                        }
                        continue;
                    };

                    const frame = self.allocator.create(coroutine.CoroutineFrame) catch {
                        posix.close(client_fd);
                        continue;
                    };
                    frame.* = coroutine.CoroutineFrame.create(@intCast(client_fd));

                    self.scheduler.spawnCoroutine(frame) catch {
                        posix.close(client_fd);
                        self.allocator.destroy(frame);
                        continue;
                    };
                }
            }

            // Wait for scheduler thread (which drains + stops pool)
            sched_thread.join();

            // Clear globals
            g_router = null;
            g_handler_count = 0;
            g_handlers = .{null} ** 64;
            g_allocator = null;
        }

        /// Signal the server to stop. Thread-safe.
        pub fn shutdown(self: *Self) void {
            self.scheduler.shutdown();
            // Close listen fd to unblock the accept() call in run()
            if (self.listen_fd) |fd| {
                posix.close(fd);
                self.listen_fd = null;
            }
        }
    };
}

/// Worker callback: receives @intFromPtr(CoroutineFrame) as u64.
/// The frame's id field carries the accepted fd.
fn handleConnection(frame_ptr: u64) void {
    const frame: *coroutine.CoroutineFrame = @ptrFromInt(frame_ptr);
    const fd: posix.socket_t = @intCast(frame.id);
    // Free the heap-allocated frame now that we have the fd
    if (g_allocator) |alloc| alloc.destroy(frame);
    defer posix.close(fd);

    // Blocking recv
    var read_buf: [4096]u8 = undefined;
    const n = posix.recv(fd, &read_buf, 0) catch return;
    if (n == 0) return;

    // Parse HTTP
    var parse_buf: [8192]u8 = undefined;
    var parser = http1.Parser.init(&parse_buf);
    _ = parser.feed(read_buf[0..n]) catch {
        _ = posix.send(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", 0) catch {};
        return;
    };

    // Route
    const router = g_router orelse {
        _ = posix.send(fd, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", 0) catch {};
        return;
    };

    const method_str = if (parser.method) |m| @tagName(m) else "GET";
    const method = router_mod.Method.fromString(method_str) orelse .GET;
    const path = parser.uri orelse "/";

    const match_result = router.match(method, path);

    // Build and send response
    var resp_buf: [8192]u8 = undefined;
    switch (match_result) {
        .found => |found| {
            if (found.handler_id < g_handler_count) {
                if (g_handlers[found.handler_id]) |handler| {
                    var resp = handler(&parser);
                    // Add Connection: close for simplicity (no keepalive yet)
                    _ = resp.setHeader("Connection", "close");
                    const resp_n = resp.serialize(&resp_buf) catch {
                        _ = posix.send(fd, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", 0) catch {};
                        return;
                    };
                    _ = posix.send(fd, resp_buf[0..resp_n], 0) catch {};
                    return;
                }
            }
            _ = posix.send(fd, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", 0) catch {};
        },
        .not_found => {
            var resp = response_mod.Response.notFound();
            _ = resp.setHeader("Connection", "close");
            const resp_n = resp.serialize(&resp_buf) catch return;
            _ = posix.send(fd, resp_buf[0..resp_n], 0) catch {};
        },
        .method_not_allowed => {
            _ = posix.send(fd, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", 0) catch {};
        },
    }
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

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const FakeIO = @import("core/fake_io.zig").FakeIO;

test "server starts and stops" {
    var srv = try Server(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer srv.deinit();

    try srv.listen("127.0.0.1", 0);
    const port = srv.getPort();
    try testing.expect(port != 0);

    // Run in a thread, then immediately shut down
    const t = try std.Thread.spawn(.{}, struct {
        fn entry(s: *Server(FakeIO)) void {
            s.run() catch {};
        }
    }.entry, .{&srv});

    std.Thread.sleep(10 * std.time.ns_per_ms);
    srv.shutdown();
    t.join();
}

test "server handles one request" {
    var srv = try Server(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer srv.deinit();

    try srv.addRoute(.GET, "/", &struct {
        fn handler(_: *const http1.Parser) response_mod.Response {
            return response_mod.Response.text("hello snek");
        }
    }.handler);

    try srv.listen("127.0.0.1", 0);
    const port = srv.getPort();

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(s: *Server(FakeIO)) void {
            s.run() catch {};
        }
    }.entry, .{&srv});

    // Wait for server to be ready
    std.Thread.sleep(20 * std.time.ns_per_ms);

    // Connect as client
    const client_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);

    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = parseIpv4("127.0.0.1"),
    };
    try posix.connect(client_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

    const req = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    _ = try posix.send(client_fd, req, 0);

    // Read response
    std.Thread.sleep(50 * std.time.ns_per_ms);
    var resp_buf: [4096]u8 = undefined;
    const n = try posix.recv(client_fd, &resp_buf, 0);
    const resp = resp_buf[0..n];

    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, resp, "hello snek") != null);

    srv.shutdown();
    t.join();
}

test "server handles multiple concurrent requests" {
    var srv = try Server(FakeIO).init(testing.allocator, .{ .num_threads = 2 });
    defer srv.deinit();

    try srv.addRoute(.GET, "/ping", &struct {
        fn handler(_: *const http1.Parser) response_mod.Response {
            return response_mod.Response.text("pong");
        }
    }.handler);

    try srv.listen("127.0.0.1", 0);
    const port = srv.getPort();

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(s: *Server(FakeIO)) void {
            s.run() catch {};
        }
    }.entry, .{&srv});

    std.Thread.sleep(20 * std.time.ns_per_ms);

    // Spawn 10 client threads
    var success_count = std.atomic.Value(u32).init(0);
    var threads: [10]std.Thread = undefined;
    for (&threads) |*th| {
        th.* = try std.Thread.spawn(.{}, struct {
            fn clientReq(p: u16, counter: *std.atomic.Value(u32)) void {
                const cfd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return;
                defer posix.close(cfd);

                var caddr = posix.sockaddr.in{
                    .family = posix.AF.INET,
                    .port = std.mem.nativeToBig(u16, p),
                    .addr = parseIpv4("127.0.0.1"),
                };
                posix.connect(cfd, @ptrCast(&caddr), @sizeOf(posix.sockaddr.in)) catch return;
                _ = posix.send(cfd, "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n", 0) catch return;

                std.Thread.sleep(50 * std.time.ns_per_ms);
                var buf: [4096]u8 = undefined;
                const rn = posix.recv(cfd, &buf, 0) catch return;
                if (rn > 0 and std.mem.indexOf(u8, buf[0..rn], "pong") != null) {
                    _ = counter.fetchAdd(1, .monotonic);
                }
            }
        }.clientReq, .{ port, &success_count });
    }

    for (&threads) |*th| th.join();

    srv.shutdown();
    t.join();

    try testing.expectEqual(@as(u32, 10), success_count.load(.acquire));
}

test "server routes correctly" {
    var srv = try Server(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer srv.deinit();

    try srv.addRoute(.GET, "/", &struct {
        fn h(_: *const http1.Parser) response_mod.Response {
            return response_mod.Response.text("root");
        }
    }.h);
    try srv.addRoute(.GET, "/health", &struct {
        fn h(_: *const http1.Parser) response_mod.Response {
            return response_mod.Response.json("{\"ok\":true}");
        }
    }.h);
    try srv.addRoute(.POST, "/data", &struct {
        fn h(_: *const http1.Parser) response_mod.Response {
            return response_mod.Response.text("created");
        }
    }.h);

    try srv.listen("127.0.0.1", 0);
    const port = srv.getPort();

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(s: *Server(FakeIO)) void {
            s.run() catch {};
        }
    }.entry, .{&srv});
    std.Thread.sleep(20 * std.time.ns_per_ms);

    // Helper: send request, return response body-ish
    const doReq = struct {
        fn call(p: u16, req: []const u8) ![]const u8 {
            const cfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
            defer posix.close(cfd);
            var caddr = posix.sockaddr.in{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, p),
                .addr = parseIpv4("127.0.0.1"),
            };
            try posix.connect(cfd, @ptrCast(&caddr), @sizeOf(posix.sockaddr.in));
            _ = try posix.send(cfd, req, 0);
            std.Thread.sleep(50 * std.time.ns_per_ms);

            // Use a thread-local static buffer for reading
            const S = struct {
                threadlocal var buf: [4096]u8 = undefined;
            };
            const n = try posix.recv(cfd, &S.buf, 0);
            return S.buf[0..n];
        }
    }.call;

    // Test root
    const r1 = try doReq(port, "GET / HTTP/1.1\r\nHost: h\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, r1, "root") != null);

    // Test /health
    const r2 = try doReq(port, "GET /health HTTP/1.1\r\nHost: h\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, r2, "{\"ok\":true}") != null);

    // Test POST /data
    const r3 = try doReq(port, "POST /data HTTP/1.1\r\nHost: h\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, r3, "created") != null);

    srv.shutdown();
    t.join();
}

test "server handles 404" {
    var srv = try Server(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer srv.deinit();

    try srv.addRoute(.GET, "/exists", &struct {
        fn h(_: *const http1.Parser) response_mod.Response {
            return response_mod.Response.text("here");
        }
    }.h);

    try srv.listen("127.0.0.1", 0);
    const port = srv.getPort();

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(s: *Server(FakeIO)) void {
            s.run() catch {};
        }
    }.entry, .{&srv});
    std.Thread.sleep(20 * std.time.ns_per_ms);

    const cfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(cfd);
    var caddr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = parseIpv4("127.0.0.1"),
    };
    try posix.connect(cfd, @ptrCast(&caddr), @sizeOf(posix.sockaddr.in));
    _ = try posix.send(cfd, "GET /nonexistent HTTP/1.1\r\nHost: h\r\n\r\n", 0);

    std.Thread.sleep(50 * std.time.ns_per_ms);
    var buf: [4096]u8 = undefined;
    const n = try posix.recv(cfd, &buf, 0);
    const resp = buf[0..n];

    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404"));
    try testing.expect(std.mem.indexOf(u8, resp, "Not Found") != null);

    srv.shutdown();
    t.join();
}
