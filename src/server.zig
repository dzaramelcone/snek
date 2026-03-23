//! Integrated snek HTTP server.
//!
//! Completion-driven architecture using platform-native async I/O:
//!   - macOS: kqueue (readiness-to-completion adapter)
//!   - Linux: io_uring (true completion-based)
//!
//! Per-worker accept architecture:
//!   - Each worker thread binds its own listen socket (SO_REUSEPORT)
//!   - Kernel load-balances incoming connections across workers
//!   - Each worker creates its own IO backend instance
//!   - State machine per connection: ACCEPTING → READING → WRITING → DONE
//!
//! This matches zzz, http.zig, nginx, and Go net/http.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const router_mod = @import("http/router.zig");
const http1 = @import("net/http1.zig");
const response_mod = @import("http/response.zig");
const io_mod = @import("core/io.zig");
const fake_io = @import("core/fake_io.zig");
const py_driver = @import("python/driver.zig");

const IO = io_mod.Backend;
const CompletionEntry = fake_io.CompletionEntry;

pub const HandlerFn = *const fn (*const http1.Parser) response_mod.Response;

pub const Config = struct {
    num_threads: u32 = 0, // 0 = auto-detect CPU count
};

/// Maximum connections tracked per worker.
const MAX_CONNS: usize = 256;

/// Sentinel user_data value for the accept operation.
/// Connection pool indices are 0..MAX_CONNS-1, so MAX_CONNS is unused.
const ACCEPT_USER_DATA: u64 = MAX_CONNS;

const ConnState = enum {
    free, // slot is unused
    reading, // waiting for recv to complete
    writing, // waiting for send to complete
    closing, // waiting for async close to complete
};

const Connection = struct {
    fd: posix.socket_t,
    state: ConnState,
    read_buf: [4096]u8,
    resp_buf: [8192]u8,
    resp_len: usize,

    fn reset(self: *Connection) void {
        self.fd = -1;
        self.state = .free;
        self.resp_len = 0;
    }
};

pub const Server = struct {
    router: router_mod.Router,
    handlers: [64]?HandlerFn,
    handler_count: u32,
    /// Python handler IDs indexed by router handler_id.
    /// If py_handler_ids[handler_id] is set, the handler is Python-backed.
    /// The value is the index into the module's py_handlers table.
    py_handler_ids: [64]?u32,
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
            .py_handler_ids = .{null} ** 64,
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
        try self.router.addRoute(method, path, id);
    }

    /// Register a Python handler route. The py_handler_id indexes into the
    /// module's py_handlers table. The Zig router stores a handler_id that
    /// maps to the Python handler via py_handler_ids.
    pub fn addPythonRoute(self: *Server, method: router_mod.Method, path: []const u8, py_handler_id: u32) !void {
        const id = self.handler_count;
        if (id >= 64) return error.TooManyHandlers;
        self.handlers[id] = null; // No native handler
        self.py_handler_ids[id] = py_handler_id;
        self.handler_count = id + 1;
        try self.router.addRoute(method, path, id);
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
    /// Spawns N worker threads, each with its own listen socket and IO backend.
    pub fn run(self: *Server) !void {
        self.running.store(true, .release);

        self.workers = try self.allocator.alloc(std.Thread, self.num_threads);
        errdefer self.allocator.free(self.workers);

        // Spawn worker threads — each creates its own listen socket + IO backend
        var spawned: u32 = 0;
        errdefer {
            self.running.store(false, .release);
            for (self.workers[0..spawned]) |w| w.join();
        }

        for (0..self.num_threads) |i| {
            self.workers[i] = try std.Thread.spawn(.{}, workerLoop, .{self});
            spawned += 1;
        }

        // Main thread also runs the IO-driven accept loop
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

    // ── Worker logic (IO-backend-driven) ─────────────────────────

    fn workerLoop(self: *Server) void {
        // Each worker creates its own listen socket on the same port
        const fd = createListenSocket(self.bind_addr, self.bind_port) catch |err|
            std.debug.panic("worker createListenSocket failed: {}", .{err});
        defer posix.close(fd);
        workerAcceptLoop(self, fd);
    }

    fn workerAcceptLoop(self: *Server, listen_fd: posix.socket_t) void {
        var backend = initBackend(self.allocator);
        defer backend.deinit();

        // Connection pool — heap-allocated. Each Connection is ~12KB
        // (4096 read_buf + 8192 resp_buf), so 256 = ~3MB. macOS worker
        // threads have 512KB stacks — this MUST be on the heap.
        const conns = self.allocator.create([MAX_CONNS]Connection) catch |err|
            std.debug.panic("connection pool alloc failed: {}", .{err});
        defer self.allocator.destroy(conns);
        for (conns) |*c| c.reset();

        // Submit initial accept
        backend.submitAccept(listen_fd, ACCEPT_USER_DATA) catch |err|
            std.debug.panic("initial submitAccept failed: {}", .{err});

        // Completion-driven event loop
        var events: [64]CompletionEntry = undefined;
        while (self.running.load(.acquire)) {
            const count = backend.pollCompletions(&events) catch |err| {
                // On shutdown, the listen fd may be closed causing kevent errors.
                // Check running flag before panicking.
                if (!self.running.load(.acquire)) return;
                std.debug.panic("pollCompletions failed: {}", .{err});
            };

            if (count == 0) continue;

            for (events[0..count]) |ev| {
                if (ev.user_data == ACCEPT_USER_DATA) {
                    // Accept completion
                    self.handleAcceptCompletion(&backend, conns, listen_fd, ev);
                } else {
                    // Connection completion (recv or send)
                    const idx = @as(usize, @intCast(ev.user_data));
                    if (idx >= MAX_CONNS) {
                        std.debug.panic("completion user_data out of range: {}", .{idx});
                    }
                    self.handleConnectionCompletion(&backend, &conns.*[idx], ev);
                }
            }
        }

        // Cleanup: close any open connections
        for (conns) |*c| {
            if (c.state != .free) {
                posix.close(c.fd);
                c.reset();
            }
        }
    }

    fn handleAcceptCompletion(
        self: *Server,
        backend: *IO,
        conns: *[MAX_CONNS]Connection,
        listen_fd: posix.socket_t,
        ev: CompletionEntry,
    ) void {
        // Always re-submit accept to keep accepting
        if (self.running.load(.acquire)) {
            backend.submitAccept(listen_fd, ACCEPT_USER_DATA) catch |err|
                std.debug.panic("re-submitAccept failed: {}", .{err});
        }

        if (ev.result < 0) return; // accept error, skip
        const client_fd: posix.socket_t = @intCast(ev.result);

        // Find a free connection slot
        const slot_idx = findFreeSlot(conns) orelse {
            // No free slots — drop the connection
            posix.close(client_fd);
            return;
        };

        const conn = &conns.*[slot_idx];
        conn.fd = client_fd;
        conn.state = .reading;
        conn.resp_len = 0;

        backend.submitRecv(client_fd, &conn.read_buf, @intCast(slot_idx)) catch |err|
            std.debug.panic("submitRecv failed: {}", .{err});
    }

    fn handleConnectionCompletion(
        self: *const Server,
        backend: *IO,
        conn: *Connection,
        ev: CompletionEntry,
    ) void {
        switch (conn.state) {
            .reading => self.handleRecvCompletion(backend, conn, ev),
            .writing => handleSendCompletion(backend, conn, ev),
            .closing => conn.reset(),
            .free => std.debug.panic("completion on free connection slot", .{}),
        }
    }

    fn handleRecvCompletion(
        self: *const Server,
        backend: *IO,
        conn: *Connection,
        ev: CompletionEntry,
    ) void {
        // recv error or EOF
        if (ev.result <= 0) {
            posix.close(conn.fd);
            conn.reset();
            return;
        }

        const n: usize = @intCast(ev.result);

        var parse_buf: [8192]u8 = undefined;
        var parser = http1.Parser.init(&parse_buf);
        _ = parser.feed(conn.read_buf[0..n]) catch {
            // Bad request — send 400 directly
            const bad = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            @memcpy(conn.resp_buf[0..bad.len], bad);
            conn.resp_len = bad.len;
            conn.state = .writing;

            // The completion event's user_data IS the slot index (set by submitRecv)
            backend.submitSend(conn.fd, conn.resp_buf[0..conn.resp_len], ev.user_data) catch |err|
                std.debug.panic("submitSend (400) failed: {}", .{err});
            return;
        };

        const method_str = if (parser.method) |m| @tagName(m) else "GET";
        const method = router_mod.Method.fromString(method_str) orelse .GET;
        const path = parser.uri orelse "/";
        const match_result = self.router.match(method, path);

        const response_bytes: []const u8 = switch (match_result) {
            .found => |found| blk: {
                if (found.handler_id < self.handler_count) {
                    // Check for Python handler first
                    if (self.py_handler_ids[found.handler_id]) |py_id| {
                        var py_body_buf: [4096]u8 = undefined;
                        var resp = py_driver.invokePythonHandler(
                            py_id,
                            &parser,
                            found.params[0..found.param_count],
                            &py_body_buf,
                        );
                        _ = resp.setHeader("Connection", "close");
                        const resp_n = resp.serialize(&conn.resp_buf) catch |err|
                            std.debug.panic("serialize failed: {}", .{err});
                        conn.resp_len = resp_n;
                        break :blk conn.resp_buf[0..resp_n];
                    }
                    // Native Zig handler
                    if (self.handlers[found.handler_id]) |handler| {
                        var resp = handler(&parser);
                        _ = resp.setHeader("Connection", "close");
                        const resp_n = resp.serialize(&conn.resp_buf) catch |err|
                            std.debug.panic("serialize failed: {}", .{err});
                        conn.resp_len = resp_n;
                        break :blk conn.resp_buf[0..resp_n];
                    }
                }
                break :blk "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            },
            .not_found => blk: {
                var resp = response_mod.Response.notFound();
                _ = resp.setHeader("Connection", "close");
                const resp_n = resp.serialize(&conn.resp_buf) catch |err|
                    std.debug.panic("serialize failed: {}", .{err});
                conn.resp_len = resp_n;
                break :blk conn.resp_buf[0..resp_n];
            },
            .method_not_allowed => "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        };

        // If response is a static string (not in conn.resp_buf), copy it
        if (conn.resp_len == 0) {
            @memcpy(conn.resp_buf[0..response_bytes.len], response_bytes);
            conn.resp_len = response_bytes.len;
        }

        conn.state = .writing;
        // The completion event's user_data IS the slot index (set by submitRecv)
        backend.submitSend(conn.fd, conn.resp_buf[0..conn.resp_len], ev.user_data) catch |err|
            std.debug.panic("submitSend failed: {}", .{err});
    }

    fn handleSendCompletion(backend: *IO, conn: *Connection, ev: CompletionEntry) void {
        // Send done — submit async close instead of blocking posix.close
        conn.state = .closing;
        backend.submitClose(conn.fd, ev.user_data) catch |err|
            std.debug.panic("submitClose failed: {}", .{err});
    }

};

fn findFreeSlot(conns: *[MAX_CONNS]Connection) ?usize {
    for (conns, 0..) |*c, i| {
        if (c.state == .free) return i;
    }
    return null;
}

/// Initialize the platform IO backend.
/// Kqueue takes an allocator; IoUring takes a RingConfig.
fn initBackend(allocator: std.mem.Allocator) IO {
    if (comptime builtin.os.tag == .macos) {
        return IO.init(allocator) catch |err|
            std.debug.panic("kqueue init failed: {}", .{err});
    } else if (comptime builtin.os.tag == .linux) {
        const io_uring_mod = @import("core/io_uring.zig");
        return IO.init(io_uring_mod.RingConfig{ .ring_size = 256, .allocator = allocator }) catch |err|
            std.debug.panic("io_uring init failed: {}", .{err});
    } else {
        @compileError("unsupported platform");
    }
}

fn createListenSocket(addr: []const u8, port: u16) !posix.socket_t {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));

    // Non-blocking for kqueue/io_uring-driven accept
    const flags = try posix.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    const nonblock: usize = @intCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock);

    const net_addr = try std.net.Address.parseIp4(addr, port);
    try posix.bind(fd, &net_addr.any, net_addr.getOsSockLen());
    try posix.listen(fd, 128);

    return fd;
}

// ── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "server starts and stops" {
    var srv = try Server.init(testing.allocator, .{ .num_threads = 2 });
    defer srv.deinit();

    try srv.listen("127.0.0.1", 0);
    try testing.expect(srv.getPort() != 0);

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(s: *Server) void {
            s.run() catch |err| std.debug.panic("server run failed: {}", .{err});
        }
    }.entry, .{&srv});

    std.Thread.sleep(50 * std.time.ns_per_ms);
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
        fn entry(s: *Server) void {
            s.run() catch |err| std.debug.panic("server run failed: {}", .{err});
        }
    }.entry, .{&srv});
    std.Thread.sleep(50 * std.time.ns_per_ms);

    const cfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(cfd);
    const server_addr = try std.net.Address.parseIp4("127.0.0.1", port);
    try posix.connect(cfd, &server_addr.any, server_addr.getOsSockLen());
    _ = try posix.send(cfd, "GET / HTTP/1.1\r\nHost: h\r\n\r\n", 0);

    std.Thread.sleep(100 * std.time.ns_per_ms);
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
        fn entry(s: *Server) void {
            s.run() catch |err| std.debug.panic("server run failed: {}", .{err});
        }
    }.entry, .{&srv});
    std.Thread.sleep(50 * std.time.ns_per_ms);

    var success = std.atomic.Value(u32).init(0);
    var threads: [10]std.Thread = undefined;
    for (&threads) |*th| {
        th.* = try std.Thread.spawn(.{}, struct {
            fn req(p: u16, cnt: *std.atomic.Value(u32)) void {
                const cfd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch unreachable;
                defer posix.close(cfd);
                const sa = std.net.Address.parseIp4("127.0.0.1", p) catch unreachable;
                posix.connect(cfd, &sa.any, sa.getOsSockLen()) catch unreachable;
                _ = posix.send(cfd, "GET /ping HTTP/1.1\r\nHost: h\r\n\r\n", 0) catch unreachable;
                std.Thread.sleep(100 * std.time.ns_per_ms);
                var buf: [4096]u8 = undefined;
                const n = posix.recv(cfd, &buf, 0) catch unreachable;
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
        fn entry(s: *Server) void {
            s.run() catch |err| std.debug.panic("server run failed: {}", .{err});
        }
    }.entry, .{&srv});
    std.Thread.sleep(50 * std.time.ns_per_ms);

    const cfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(cfd);
    const addr = (try std.net.Address.parseIp4("127.0.0.1", port)).any;
    try posix.connect(cfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    _ = try posix.send(cfd, "GET /nope HTTP/1.1\r\nHost: h\r\n\r\n", 0);

    std.Thread.sleep(100 * std.time.ns_per_ms);
    var buf: [4096]u8 = undefined;
    const n = try posix.recv(cfd, &buf, 0);

    try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 404"));

    srv.shutdown();
    t.join();
}

test "server handles param routes" {
    var srv = try Server.init(testing.allocator, .{ .num_threads = 1 });
    defer srv.deinit();

    try srv.addRoute(.GET, "/", &struct {
        fn h(_: *const http1.Parser) response_mod.Response {
            return response_mod.Response.text("root");
        }
    }.h);
    try srv.addRoute(.GET, "/health", &struct {
        fn h(_: *const http1.Parser) response_mod.Response {
            return response_mod.Response.text("ok");
        }
    }.h);
    try srv.addPythonRoute(.GET, "/greet/{name}", 0);

    try srv.listen("127.0.0.1", 0);
    const port = srv.getPort();

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn entry(s: *Server) void {
            s.run() catch |err| std.debug.panic("server run failed: {}", .{err});
        }
    }.entry, .{&srv});
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Test /health specifically
    const cfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(cfd);
    const server_addr = try std.net.Address.parseIp4("127.0.0.1", port);
    try posix.connect(cfd, &server_addr.any, server_addr.getOsSockLen());
    _ = try posix.send(cfd, "GET /health HTTP/1.1\r\nHost: h\r\n\r\n", 0);

    std.Thread.sleep(100 * std.time.ns_per_ms);
    var rbuf: [4096]u8 = undefined;
    const n = try posix.recv(cfd, &rbuf, 0);
    const resp = rbuf[0..n];

    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, resp, "ok") != null);

    srv.shutdown();
    server_thread.join();
}
