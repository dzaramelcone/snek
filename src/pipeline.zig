//! Staged event-driven pipeline.
//!
//! Connections are pure data (fd + recv buffer). Each stage defines its own
//! typed task. The stage processor IS the state machine.
//!
//! DAG:
//!   [kernel recv] → ParseTask → HandleTask ─┬→ SendTask → [kernel sendv] → recv
//!                                            └→ RedisTask ··· → SendTask
//!
//! Response headers use a cached per-second prefix (Server + Date) shared
//! across all responses. sendv scatter-gathers prefix + per-response headers + body.

const std = @import("std");
const posix = std.posix;
const aio = @import("aio/lib.zig");
const IoOp = @import("aio/io_op.zig").IoOp;
const IoResult = @import("aio/io_op.zig").IoResult;
const Task = @import("task.zig").Task;
const Pool = @import("pool.zig").Pool;
const ZeroCopy = @import("zero_copy.zig").ZeroCopy;
const http1 = @import("net/http1.zig");
const handler_mod = @import("handler.zig");
const driver = @import("python/driver.zig");
const ffi = @import("python/ffi.zig");
const c = ffi.c;
const module = @import("python/module.zig");
const router_mod = @import("http/router.zig");
const response_mod = @import("http/response.zig");

const log = std.log.scoped(.@"snek/pipeline");

const MAX_BATCH = 256;
const MAX_IOVECS = 4; // status | common | per-response | body

// ── Cached response prefix ────────────────────────────────────────
// Recomputed once per second. Shared by all responses in the window.
//
//   Server: snek\r\n
//   Date: Thu, 28 Mar 2026 12:34:56 GMT\r\n
//
// ~50 bytes. Every response points to the same buffer.

const COMMON_HDR_CAP = 64;

var cached_common_hdr: [COMMON_HDR_CAP]u8 = undefined;
var cached_common_len: usize = 0;
var cached_epoch: i64 = 0;

fn refreshCommonHeaders() void {
    const now = std.time.timestamp();
    if (now == cached_epoch and cached_common_len > 0) return;
    cached_epoch = now;

    const epoch_secs: u64 = @intCast(now);
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_secs = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const day_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    // Day of week: Jan 1 1970 was Thursday (index 0)
    const days_since_epoch = es.getEpochDay().day;
    const dow = @mod(days_since_epoch + 3, 7); // +3 because Jan 1 1970 = Thursday

    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();

    cached_common_len = (std.fmt.bufPrint(&cached_common_hdr,
        "Server: snek\r\nDate: {s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT\r\n",
        .{
            day_names[dow],
            month_day.day_index + 1,
            month_names[month_day.month.numeric() - 1],
            year_day.year,
            hour, minute, second,
        },
    ) catch &.{}).len;
}

fn commonHeaders() []const u8 {
    return cached_common_hdr[0..cached_common_len];
}

// ── Connection — pure data ────────────────────────────────────────

pub const Conn = struct {
    fd: posix.socket_t = undefined,
    pool_index: u16 = 0,
    zc: ZeroCopy(u8) = undefined,
    recv_slice: []u8 = &.{},
    initialized: bool = false,

    // Streaming SIMD header parser from stdlib
    head_parser: std.http.HeadParser = .{},
    head_fed: usize = 0,

    // Body buffer — Python response body is copied here.
    // Lives until send completes. Eliminates resp_buf[8192].
    body_buf: [4096]u8 = undefined,

    // Embedded Task for backend udata round-trip.
    // The pipeline recovers Conn via @fieldParentPtr.
    task: Task = undefined,

    pub fn ensureInit(self: *Conn, allocator: std.mem.Allocator) !void {
        if (!self.initialized) {
            self.zc = try ZeroCopy(u8).init(allocator, 4096);
            self.initialized = true;
        }
    }

    pub fn resetRecv(self: *Conn) void {
        self.zc.clear_retaining_capacity();
        self.head_parser = .{};
        self.head_fed = 0;
        self.recv_slice = self.zc.get_write_area(4096) catch &.{};
    }
};

// ── Typed tasks ───────────────────────────────────────────────────

pub const ParseTask = struct { conn: u16 };

pub const HandleTask = struct {
    conn: u16,
    header_end: usize,
    content_length: usize,
};

pub const SendTask = struct {
    conn: u16,
    // Per-response header fragment: "Content-Type: ...\r\nContent-Length: N\r\n\r\n"
    hdr: [128]u8,
    hdr_len: usize,
    // Pointers for sendv iovecs
    status_line: []const u8, // static string
    body: ?[]const u8, // points into conn.body_buf or static
};

pub const RedisTask = struct {
    conn: u16,
    py_coro: *ffi.PyObject,
    resp: [256]u8, // pre-built RESP command (Zig-owned, no Python lifetime dependency)
    resp_len: u8,
};

const RedisWaiter = struct {
    conn_idx: u16,
    py_coro: *ffi.PyObject,
};

// ── Typed stage queues ────────────────────────────────────────────

pub fn Queue(comptime T: type) type {
    return struct {
        items: [MAX_BATCH]T = undefined,
        len: usize = 0,

        pub fn push(self: *@This(), item: T) void {
            if (self.len < MAX_BATCH) {
                self.items[self.len] = item;
                self.len += 1;
            }
        }

        pub fn slice(self: *const @This()) []const T {
            return self.items[0..self.len];
        }

        pub fn mutableSlice(self: *@This()) []T {
            return self.items[0..self.len];
        }
    };
}

// ── Pipeline ──────────────────────────────────────────────────────

pub const Pipeline = struct {
    backend: aio.Backend,
    conns: *Pool(Conn),
    allocator: std.mem.Allocator,
    running: bool = true,
    listen_fd: posix.socket_t = undefined,
    accept_task: Task = undefined,
    req_ctx: ?*const handler_mod.RequestContext = null,

    // Typed stage queues
    parse_q: Queue(ParseTask) = .{},
    handle_q: Queue(HandleTask) = .{},
    send_q: Queue(SendTask) = .{},
    redis_q: Queue(RedisTask) = .{},
    close_q: Queue(u16) = .{},

    // iovecs storage — one set of MAX_IOVECS per send task, reused each cycle
    iovecs_buf: [MAX_BATCH][MAX_IOVECS]posix.iovec_const = undefined,

    // ── Redis state ──────────────────────────────────────────────
    redis_fd: ?posix.socket_t = null,
    redis_task: Task = undefined,
    redis_send_buf: [8192]u8 = undefined,
    redis_send_len: usize = 0,
    redis_recv_buf: [8192]u8 = undefined,
    redis_recv_len: usize = 0,
    redis_parse_pos: usize = 0,
    redis_state: enum { idle, sending, receiving, parsing, err } = .idle,
    redis_waiters: [MAX_BATCH]RedisWaiter = undefined,
    redis_waiter_head: usize = 0,
    redis_waiter_tail: usize = 0,
    redis_waiter_count: usize = 0,
    redis_batch_count: usize = 0,
    redis_batch_sent: usize = 0, // bytes in current send batch (for compact)

    // Stage timing stats
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, conns: *Pool(Conn), entries: u16) !Pipeline {
        return .{
            .backend = try aio.Backend.init(allocator, entries),
            .conns = conns,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pipeline, allocator: std.mem.Allocator) void {
        self.backend.deinit(allocator);
    }

    pub fn start(self: *Pipeline, listen_fd: posix.socket_t) !void {
        self.listen_fd = listen_fd;
        // Dummy step fn — pipeline ignores it, just need pending_op storage
        self.accept_task = Task.init(Pipeline, self, dummyStep);
        try self.backend.queue(&self.accept_task, IoOp{ .accept = .{ .socket = listen_fd } });
    }

    fn dummyStep(_: *Pipeline, _: *Task, _: IoResult) ?IoOp {
        return null;
    }

    // ── Main loop ─────────────────────────────────────────────────

    pub fn run(self: *Pipeline) !void {
        refreshCommonHeaders();
        while (self.running) {
            _ = try self.cycle(1);
            while (try self.cycle(0)) {}
        }
    }

    fn cycle(self: *Pipeline, wait_nr: u32) !bool {
        const t0 = std.time.Instant.now() catch unreachable;
        const completions = try self.backend.submitAndWait(wait_nr);
        if (completions.tasks.len == 0) return false;
        const t_io = std.time.Instant.now() catch unreachable;

        // Refresh cached date header (once per second)
        refreshCommonHeaders();

        // Reset queues
        self.parse_q.len = 0;
        self.handle_q.len = 0;
        self.send_q.len = 0;
        self.redis_q.len = 0;
        self.close_q.len = 0;

        // Classify
        for (completions.tasks, completions.results) |task, result| {
            if (task == &self.accept_task) {
                self.onAccept(result);
            } else if (self.redis_fd != null and task == &self.redis_task) {
                self.onRedisIO(result);
            } else {
                self.onConnCompletion(task, result);
            }
        }
        const t_classify = std.time.Instant.now() catch unreachable;

        // DAG
        self.stageParse();
        const t_parse = std.time.Instant.now() catch unreachable;

        // GIL held across handle + redis stages (one acquire for all Python work)
        const py_ctx = if (self.req_ctx) |ctx| ctx.py_ctx else null;
        const need_gil = py_ctx != null and (self.handle_q.len > 0 or self.redis_q.len > 0 or self.redis_state == .parsing or self.redis_state == .err);
        if (need_gil) py_ctx.?.py.acquireGil();

        self.stageHandle();
        const t_handle = std.time.Instant.now() catch unreachable;
        self.stageRedis();
        const t_redis = std.time.Instant.now() catch unreachable;

        if (need_gil) py_ctx.?.py.releaseGil();

        self.stageSerializeAndSend();
        const t_send = std.time.Instant.now() catch unreachable;
        self.stageClose();

        // Accumulate timing stats
        self.stats.cycles += 1;
        self.stats.completions += completions.tasks.len;
        self.stats.ns_io += t_io.since(t0);
        self.stats.ns_classify += t_classify.since(t_io);
        self.stats.ns_parse += t_parse.since(t_classify);
        self.stats.ns_handle += t_handle.since(t_parse);
        self.stats.ns_redis += t_redis.since(t_handle);
        self.stats.ns_send += t_send.since(t_redis);

        // Print every 10000 cycles
        if (self.stats.cycles % 10000 == 0) self.stats.dump();

        return true;
    }

    const Stats = struct {
        cycles: u64 = 0,
        completions: u64 = 0,
        ns_io: u64 = 0,
        ns_classify: u64 = 0,
        ns_parse: u64 = 0,
        ns_handle: u64 = 0,
        ns_redis: u64 = 0,
        ns_send: u64 = 0,

        fn dump(self: *Stats) void {
            const total = self.ns_io + self.ns_classify + self.ns_parse + self.ns_handle + self.ns_redis + self.ns_send;
            const reqs = self.completions;
            const us = struct {
                fn f(ns: u64) u64 {
                    return ns / 1000;
                }
            }.f;
            log.info(
                "PROFILE  cycles={d}  reqs={d}  total={d}us  io={d}us  classify={d}us  parse={d}us  handle={d}us  redis={d}us  send={d}us",
                .{ self.cycles, reqs, us(total), us(self.ns_io), us(self.ns_classify), us(self.ns_parse), us(self.ns_handle), us(self.ns_redis), us(self.ns_send) },
            );
            self.completions = 0;
            self.ns_io = 0;
            self.ns_classify = 0;
            self.ns_parse = 0;
            self.ns_handle = 0;
            self.ns_redis = 0;
            self.ns_send = 0;
        }
    };

    // ── Classify ──────────────────────────────────────────────────

    fn onAccept(self: *Pipeline, result: IoResult) void {
        // Re-arm accept
        self.backend.queue(&self.accept_task, IoOp{ .accept = .{ .socket = self.listen_fd } }) catch {};

        if (result < 0) return;
        const client_fd: posix.socket_t = @intCast(result);

        const idx = self.conns.borrow() catch {
            posix.close(client_fd);
            return;
        };
        const conn = self.conns.get_ptr(idx);
        conn.fd = client_fd;
        conn.pool_index = @intCast(idx);
        conn.task = Task.init(Pipeline, self, dummyStep);
        conn.ensureInit(self.allocator) catch {
            posix.close(client_fd);
            self.conns.release(idx);
            return;
        };
        conn.resetRecv();

        self.submitRecv(conn);
    }

    fn onConnCompletion(self: *Pipeline, task: *Task, result: IoResult) void {
        const conn: *Conn = @fieldParentPtr("task", task);
        const index = conn.pool_index;

        switch (task.pending_op) {
            .recv => {
                if (result <= 0) {
                    self.close_q.push(index);
                    return;
                }
                conn.zc.mark_written(@intCast(result));
                self.parse_q.push(.{ .conn = index });
            },
            .send, .sendv => {
                if (result < 0) {
                    self.close_q.push(index);
                    return;
                }
                // Send complete — keepalive
                conn.resetRecv();
                self.submitRecv(conn);
            },
            else => {},
        }
    }

    // ── Stage: Parse ──────────────────────────────────────────────

    fn stageParse(self: *Pipeline) void {
        for (self.parse_q.slice()) |pt| {
            const conn = self.conns.get_ptr(pt.conn);
            const data = conn.zc.as_slice();

            const new_bytes = data[conn.head_fed..];
            const consumed = conn.head_parser.feed(new_bytes);
            conn.head_fed += consumed;

            if (conn.head_parser.state != .finished) {
                conn.recv_slice = conn.zc.get_write_area(4096) catch {
                    self.close_q.push(pt.conn);
                    continue;
                };
                self.submitRecv(conn);
                continue;
            }

            const header_end = conn.head_fed;
            const content_length = quickContentLength(data[0..header_end]);
            if (content_length > 0) {
                const body_received = data.len - header_end;
                if (body_received < content_length) {
                    conn.recv_slice = conn.zc.get_write_area(
                        content_length - body_received,
                    ) catch {
                        self.close_q.push(pt.conn);
                        continue;
                    };
                    self.submitRecv(conn);
                    continue;
                }
            }

            self.handle_q.push(.{
                .conn = pt.conn,
                .header_end = header_end,
                .content_length = content_length,
            });
        }
    }

    // ── Stage: Handle (batched + SIMD screened) ────────────────
    // 1. SIMD screen: gather first bytes from N requests, vectorized
    //    classify which are GET. For GET-to-root with no_args handler,
    //    skip Request.parse() and dict building entirely.
    // 2. GIL acquired once for the entire batch.
    // 3. Remaining requests: full parse → route → invoke.

    fn stageHandle(self: *Pipeline) void {
        const req_ctx = self.req_ctx orelse return;
        const batch = self.handle_q.slice();
        if (batch.len == 0) return;

        // ── SIMD screen: gather + classify ───────────────────────
        // Gather first byte from each request into contiguous memory,
        // then vectorized compare against 'G' to find GET requests.
        var first_bytes: [MAX_BATCH]u8 = undefined;
        for (batch, 0..) |ht, i| {
            const data = self.conns.get_ptr(ht.conn).zc.as_slice();
            first_bytes[i] = if (data.len > 0) data[0] else 0;
        }
        var is_get: [MAX_BATCH]bool = .{false} ** MAX_BATCH;
        simdScreenBytes(first_bytes[0..batch.len], 'G', is_get[0..batch.len]);

        // GIL already held by cycle() across handle + redis stages
        const py_ctx = req_ctx.py_ctx;

        for (batch, 0..) |ht, i| {
            const conn = self.conns.get_ptr(ht.conn);
            const data = conn.zc.as_slice();

            // Fast path: SIMD told us byte[0]=='G'. Check "GET / " or "GET /x".
            if (is_get[i] and data.len >= 6 and std.mem.eql(u8, data[1..4], "ET ")) {
                // Extract URI: bytes 4..first-space-after-4
                const uri_start = 4;
                const uri_end = std.mem.indexOfScalarPos(u8, data, uri_start, ' ') orelse data.len;
                const uri = data[uri_start..uri_end];

                switch (req_ctx.router.match(.GET, uri)) {
                    .found => |found| {
                        if (req_ctx.py_handler_ids[found.handler_id]) |py_id| {
                            if (py_ctx) |py| {
                                // no_args fast path: skip Request.parse + dict building
                                const flags = module.getHandlerFlags(py.py.snek_module, py_id);
                                if (flags.no_args) {
                                    const result = driver.invokePythonHandler(
                                        py.py.snek_module, py_id, &http1.Request{},
                                        &.{}, &conn.body_buf,
                                    );
                                    switch (result) {
                                        .response => |resp| self.send_q.push(makeResponseSend(ht.conn, resp)),
                                        .redis_yield => |ry| {
                                            if (self.redis_fd != null) {
                                                self.redis_q.push(.{ .conn = ht.conn, .py_coro = ry.py_coro, .resp = ry.resp, .resp_len = ry.resp_len });
                                            } else {
                                                ffi.decref(ry.py_coro);
                                                self.send_q.push(makeErrorSend(ht.conn, 503));
                                            }
                                        },
                                    }
                                    continue;
                                }
                                // Has params or needs request dict — full parse needed
                                const req = http1.Request.parse(data[0..ht.header_end]) catch {
                                    self.send_q.push(makeErrorSend(ht.conn, 400));
                                    continue;
                                };
                                const result = driver.invokePythonHandler(
                                    py.py.snek_module, py_id, &req,
                                    found.params[0..found.param_count], &conn.body_buf,
                                );
                                switch (result) {
                                    .response => |resp| self.send_q.push(makeResponseSend(ht.conn, resp)),
                                    .redis_yield => |ry| {
                                            if (self.redis_fd != null) {
                                                self.redis_q.push(.{ .conn = ht.conn, .py_coro = ry.py_coro, .resp = ry.resp, .resp_len = ry.resp_len });
                                            } else {
                                                ffi.decref(ry.py_coro);
                                                self.send_q.push(makeErrorSend(ht.conn, 503));
                                            }
                                        },
                                }
                                continue;
                            }
                            self.send_q.push(makeErrorSend(ht.conn, 503));
                        } else if (req_ctx.handlers[found.handler_id]) |h| {
                            const req = http1.Request.parse(data[0..ht.header_end]) catch {
                                self.send_q.push(makeErrorSend(ht.conn, 400));
                                continue;
                            };
                            self.send_q.push(makeResponseSend(ht.conn, h(&req)));
                        } else {
                            self.send_q.push(makeErrorSend(ht.conn, 500));
                        }
                        continue;
                    },
                    .not_found => {
                        self.send_q.push(makeErrorSend(ht.conn, 404));
                        continue;
                    },
                    .method_not_allowed => {
                        var r = response_mod.Response.init(405);
                        r.body = "Method Not Allowed";
                        self.send_q.push(makeResponseSend(ht.conn, r));
                        continue;
                    },
                }
            }

            // Slow path: non-GET or SIMD screen missed — full parse
            const req = http1.Request.parse(data[0..ht.header_end]) catch {
                self.send_q.push(makeErrorSend(ht.conn, 400));
                continue;
            };
            const method_str = if (req.method) |m| @tagName(m) else "GET";
            const method = router_mod.Method.fromString(method_str) orelse .GET;

            switch (req_ctx.router.match(method, req.uri orelse "/")) {
                .found => |found| {
                    if (req_ctx.py_handler_ids[found.handler_id]) |py_id| {
                        if (py_ctx) |py| {
                            const result = driver.invokePythonHandler(
                                py.py.snek_module, py_id, &req,
                                found.params[0..found.param_count], &conn.body_buf,
                            );
                            switch (result) {
                                .response => |resp| self.send_q.push(makeResponseSend(ht.conn, resp)),
                                .redis_yield => |ry| {
                                            if (self.redis_fd != null) {
                                                self.redis_q.push(.{ .conn = ht.conn, .py_coro = ry.py_coro, .resp = ry.resp, .resp_len = ry.resp_len });
                                            } else {
                                                ffi.decref(ry.py_coro);
                                                self.send_q.push(makeErrorSend(ht.conn, 503));
                                            }
                                        },
                            }
                        } else {
                            self.send_q.push(makeErrorSend(ht.conn, 503));
                        }
                    } else if (req_ctx.handlers[found.handler_id]) |h| {
                        self.send_q.push(makeResponseSend(ht.conn, h(&req)));
                    } else {
                        self.send_q.push(makeErrorSend(ht.conn, 500));
                    }
                },
                .not_found => self.send_q.push(makeErrorSend(ht.conn, 404)),
                .method_not_allowed => {
                    var r = response_mod.Response.init(405);
                    r.body = "Method Not Allowed";
                    self.send_q.push(makeResponseSend(ht.conn, r));
                },
            }
        }

    }

    // ── Stage: Serialize + Send ───────────────────────────────────
    // Formats per-response headers, builds iovecs, submits sendv.
    //
    // Each response is scattered across up to 4 iovecs:
    //   [0] status line       — static string ("HTTP/1.1 200 OK\r\n")
    //   [1] common headers    — cached per-second ("Server: snek\r\nDate: ...\r\n")
    //   [2] per-response hdrs — "Connection: keep-alive\r\nContent-Type: ...\r\nContent-Length: N\r\n\r\n"
    //   [3] body              — from conn.body_buf or static string

    fn stageSerializeAndSend(self: *Pipeline) void {
        const common = commonHeaders();

        for (self.send_q.mutableSlice(), 0..) |*st, i| {
            const conn = self.conns.get_ptr(st.conn);

            var iov_count: usize = 0;
            // [0] status line
            self.iovecs_buf[i][iov_count] = .{ .base = st.status_line.ptr, .len = st.status_line.len };
            iov_count += 1;
            // [1] common headers
            self.iovecs_buf[i][iov_count] = .{ .base = common.ptr, .len = common.len };
            iov_count += 1;
            // [2] per-response headers
            self.iovecs_buf[i][iov_count] = .{ .base = &st.hdr, .len = st.hdr_len };
            iov_count += 1;
            // [3] body
            if (st.body) |body| {
                self.iovecs_buf[i][iov_count] = .{ .base = body.ptr, .len = body.len };
                iov_count += 1;
            }

            const op = IoOp{ .sendv = .{
                .socket = conn.fd,
                .iovecs = self.iovecs_buf[i][0..iov_count],
            } };
            conn.task.pending_op = op;
            self.backend.queue(&conn.task, op) catch {
                self.close_q.push(st.conn);
            };
        }
    }

    // ── Redis IO ──────────────────────────────────────────────────
    // Redis completions arrive during classify. The state machine drives
    // send → recv transitions. RESP parsing + coroutine resumption happens
    // here with GIL held, pushing completed responses to send_q.

    /// IO state machine only — no Python work. Defers RESP parsing to stageRedis.
    fn onRedisIO(self: *Pipeline, result: IoResult) void {
        switch (self.redis_state) {
            .sending => {
                if (result <= 0) {
                    self.redis_state = .err;
                    return;
                }
                self.redis_recv_len = 0;
                self.redis_parse_pos = 0;
                self.redis_state = .receiving;
                self.submitRedisRecv();
            },
            .receiving => {
                if (result <= 0) {
                    self.redis_state = .err;
                    return;
                }
                self.redis_recv_len += @intCast(result);
                // RESP bytes accumulated. Parsing + coroutine resumption
                // happens in stageRedis under the shared GIL hold.
                self.redis_state = .parsing;
            },
            .idle, .parsing, .err => {},
        }
    }

    /// Process redis: parse deferred RESP responses + enqueue new commands.
    /// GIL is already held from stageHandle.
    fn stageRedis(self: *Pipeline) void {
        if (self.redis_fd == null) return;

        // 1. Handle deferred errors (GIL needed for decref)
        if (self.redis_state == .err) {
            self.failRedisWaiters();
        }

        // 2. Parse RESP responses deferred from classify (redis recv completed)
        if (self.redis_state == .parsing) {
            self.parseRedisResponses();

            if (self.redis_batch_count > 0) {
                // More responses expected — keep receiving
                self.compactRedisRecv();
                self.redis_state = .receiving;
                self.submitRedisRecv();
            } else {
                // Batch done
                self.compactRedisSend();
                self.redis_state = .idle;
            }
        }

        // 2. Enqueue new commands from stageHandle's redis_q
        //    RESP was pre-built in invokePythonHandler while sentinel was alive.
        for (self.redis_q.slice()) |rt| {
            const len: usize = rt.resp_len;
            if (self.redis_send_len + len <= self.redis_send_buf.len) {
                @memcpy(self.redis_send_buf[self.redis_send_len..][0..len], rt.resp[0..len]);
                self.redis_send_len += len;
                self.pushRedisWaiter(rt.conn, rt.py_coro);
            } else {
                ffi.decref(rt.py_coro);
                self.send_q.push(makeErrorSend(rt.conn, 503));
            }
        }

        // 3. If idle with pending commands, start sending
        if (self.redis_state == .idle and self.redis_send_len > 0 and self.redis_waiter_count > 0) {
            self.redis_batch_count = self.redis_waiter_count;
            self.redis_batch_sent = self.redis_send_len;
            self.redis_state = .sending;
            self.submitRedisSend();
        }

        // If idle and we have commands, start sending
        if (self.redis_state == .idle and self.redis_send_len > 0 and self.redis_waiter_count > 0) {
            log.debug("redis: starting send, {d} bytes, {d} waiters", .{ self.redis_send_len, self.redis_waiter_count });
            self.redis_batch_count = self.redis_waiter_count;
            self.redis_batch_sent = self.redis_send_len;
            self.redis_state = .sending;
            self.submitRedisSend();
        }
    }

    fn parseRedisResponses(self: *Pipeline) void {
        while (self.redis_batch_count > 0 and self.redis_waiter_count > 0) {
            if (!self.parseOneResp()) break; // incomplete
        }
    }

    /// Parse one RESP response and resume the head waiter's coroutine.
    fn parseOneResp(self: *Pipeline) bool {
        const data = self.redis_recv_buf[self.redis_parse_pos..self.redis_recv_len];
        if (data.len == 0) return false;

        const crlf_pos = std.mem.indexOf(u8, data, "\r\n") orelse return false;
        const type_byte = data[0];
        const line = data[1..crlf_pos];

        const py_result: *ffi.PyObject = switch (type_byte) {
            '+' => blk: {
                self.redis_parse_pos += crlf_pos + 2;
                break :blk ffi.unicodeFromSlice(line.ptr, line.len) catch return false;
            },
            '-' => {
                self.redis_parse_pos += crlf_pos + 2;
                // Set Python exception, resume waiter with error
                var err_buf: [256:0]u8 = undefined;
                if (line.len < err_buf.len) {
                    @memcpy(err_buf[0..line.len], line);
                    err_buf[line.len] = 0;
                    c.PyErr_SetString(c.PyExc_RuntimeError, err_buf[0..line.len :0]);
                }
                self.failHeadWaiter();
                self.redis_batch_count -= 1;
                return true;
            },
            ':' => blk: {
                self.redis_parse_pos += crlf_pos + 2;
                const val = std.fmt.parseInt(i64, line, 10) catch return false;
                break :blk ffi.longFromLong(val) catch return false;
            },
            '_' => blk: {
                self.redis_parse_pos += crlf_pos + 2;
                break :blk ffi.getNone();
            },
            '$' => blk: {
                const len_val = std.fmt.parseInt(i64, line, 10) catch return false;
                if (len_val < 0) {
                    self.redis_parse_pos += crlf_pos + 2;
                    break :blk ffi.getNone();
                }
                const payload_len: usize = @intCast(len_val);
                const total_needed = crlf_pos + 2 + payload_len + 2;
                if (data.len < total_needed) return false; // incomplete
                // Allocate PyBytes, copy payload
                const py_bytes = c.PyBytes_FromStringAndSize(null, @intCast(payload_len)) orelse return false;
                const dest: [*]u8 = @ptrCast(c.PyBytes_AS_STRING(py_bytes));
                @memcpy(dest[0..payload_len], data[crlf_pos + 2 ..][0..payload_len]);
                self.redis_parse_pos += total_needed;
                break :blk py_bytes;
            },
            else => return false,
        };

        // Resume head waiter's coroutine with the parsed result
        self.resumeRedisWaiter(py_result);
        self.redis_batch_count -= 1;
        return true;
    }

    /// Resume the head waiter's Python coroutine with a redis result.
    /// Uses PyIter_Send — no method lookup, no StopIteration exception overhead.
    fn resumeRedisWaiter(self: *Pipeline, result: *ffi.PyObject) void {
        const waiter = self.popRedisWaiter() orelse return;
        const conn = self.conns.get_ptr(waiter.conn_idx);

        const send = ffi.iterSend(waiter.py_coro, result);
        switch (send.status) {
            .next => {
                // Coroutine yielded again — check for another redis command
                const sentinel = send.result.?;
                defer ffi.decref(sentinel);
                if (driver.checkRedisSentinel(sentinel)) |cmd_info| {
                    const resp_len = driver.writeResp(self.redis_send_buf[self.redis_send_len..], cmd_info.args[0..cmd_info.arg_count]);
                    if (resp_len > 0) {
                        self.redis_send_len += resp_len;
                        self.pushRedisWaiter(waiter.conn_idx, waiter.py_coro);
                        self.redis_batch_count += 1;
                    }
                    return;
                }
                ffi.decref(waiter.py_coro);
                self.send_q.push(makeErrorSend(waiter.conn_idx, 500));
            },
            .@"return" => {
                // Coroutine completed — return value is the response
                ffi.decref(waiter.py_coro);
                const py_res = send.result orelse {
                    self.send_q.push(makeErrorSend(waiter.conn_idx, 500));
                    return;
                };
                defer ffi.decref(py_res);
                const resp = driver.convertPythonResponse(py_res, &conn.body_buf) catch
                    response_mod.Response.init(500);
                self.send_q.push(makeResponseSend(waiter.conn_idx, resp));
            },
            .@"error" => {
                ffi.decref(waiter.py_coro);
                if (ffi.errOccurred()) ffi.errPrint();
                self.send_q.push(makeErrorSend(waiter.conn_idx, 500));
            },
        }
    }

    fn failHeadWaiter(self: *Pipeline) void {
        const waiter = self.popRedisWaiter() orelse return;
        ffi.decref(waiter.py_coro);
        self.send_q.push(makeErrorSend(waiter.conn_idx, 500));
    }

    fn failRedisWaiters(self: *Pipeline) void {
        while (self.redis_waiter_count > 0) {
            self.failHeadWaiter();
        }
        self.redis_state = .idle;
        self.redis_batch_count = 0;
    }

    fn pushRedisWaiter(self: *Pipeline, conn_idx: u16, py_coro: *ffi.PyObject) void {
        if (self.redis_waiter_count >= MAX_BATCH) return;
        self.redis_waiters[self.redis_waiter_tail] = .{ .conn_idx = conn_idx, .py_coro = py_coro };
        self.redis_waiter_tail = (self.redis_waiter_tail + 1) % MAX_BATCH;
        self.redis_waiter_count += 1;
    }

    fn popRedisWaiter(self: *Pipeline) ?RedisWaiter {
        if (self.redis_waiter_count == 0) return null;
        const w = self.redis_waiters[self.redis_waiter_head];
        self.redis_waiter_head = (self.redis_waiter_head + 1) % MAX_BATCH;
        self.redis_waiter_count -= 1;
        return w;
    }

    fn submitRedisSend(self: *Pipeline) void {
        const fd = self.redis_fd orelse return;
        const op = IoOp{ .send = .{ .socket = fd, .buffer = self.redis_send_buf[0..self.redis_send_len] } };
        self.redis_task.pending_op = op;
        self.backend.queue(&self.redis_task, op) catch {};
    }

    fn submitRedisRecv(self: *Pipeline) void {
        const fd = self.redis_fd orelse return;
        const op = IoOp{ .recv = .{ .socket = fd, .buffer = self.redis_recv_buf[self.redis_recv_len..] } };
        self.redis_task.pending_op = op;
        self.backend.queue(&self.redis_task, op) catch {};
    }

    fn compactRedisRecv(self: *Pipeline) void {
        if (self.redis_parse_pos > 0) {
            const remaining = self.redis_recv_len - self.redis_parse_pos;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.redis_recv_buf[0..remaining], self.redis_recv_buf[self.redis_parse_pos..self.redis_recv_len]);
            }
            self.redis_recv_len = remaining;
            self.redis_parse_pos = 0;
        }
    }

    fn compactRedisSend(self: *Pipeline) void {
        if (self.redis_batch_sent == 0) return;
        if (self.redis_batch_sent >= self.redis_send_len) {
            // No new commands arrived during batch — clear all
            self.redis_send_len = 0;
        } else {
            // New commands appended during batch — keep them
            const remaining = self.redis_send_len - self.redis_batch_sent;
            std.mem.copyForwards(u8, self.redis_send_buf[0..remaining], self.redis_send_buf[self.redis_batch_sent..self.redis_send_len]);
            self.redis_send_len = remaining;
        }
        self.redis_batch_sent = 0;
    }

    pub fn initRedis(self: *Pipeline, fd: posix.socket_t) void {
        self.redis_fd = fd;
        self.redis_task = Task.init(Pipeline, self, dummyStep);
        log.info("redis connected fd={d}", .{fd});
    }

    // ── Close ─────────────────────────────────────────────────────

    fn stageClose(self: *Pipeline) void {
        for (self.close_q.slice()) |index| {
            const conn = self.conns.get_ptr(index);
            posix.close(conn.fd);
            self.conns.release(index);
        }
    }

    // ── Helpers ───────────────────────────────────────────────────

    fn submitRecv(self: *Pipeline, conn: *Conn) void {
        const op = IoOp{ .recv = .{ .socket = conn.fd, .buffer = conn.recv_slice } };
        conn.task.pending_op = op;
        self.backend.queue(&conn.task, op) catch {};
    }

    pub fn pushSendTask(self: *Pipeline, task: SendTask) void {
        self.send_q.push(task);
    }
};

/// SIMD batch screen: compare N bytes against a target byte.
/// Writes true/false into `out` for each match.
/// Uses vectorized comparison when available (NEON: 16 lanes, AVX2: 32 lanes).
fn simdScreenBytes(bytes: []const u8, target: u8, out: []bool) void {
    const V = comptime std.simd.suggestVectorLength(u8) orelse 16;
    const splat: @Vector(V, u8) = @splat(target);
    var i: usize = 0;

    while (i + V <= bytes.len) : (i += V) {
        const v: @Vector(V, u8) = bytes[i..][0..V].*;
        const mask = v == splat;
        inline for (0..V) |j| {
            out[i + j] = mask[j];
        }
    }
    // Scalar remainder
    while (i < bytes.len) : (i += 1) {
        out[i] = bytes[i] == target;
    }
}

/// Scan raw header bytes for Content-Length without a full Request.parse().
/// Methods that never carry a body (GET, HEAD, DELETE, OPTIONS) return 0
/// immediately — the common fast path under benchmarks.
fn quickContentLength(data: []const u8) usize {
    if (data.len < 4) return 0;
    switch (data[0]) {
        'G', 'H', 'D', 'O' => return 0,
        else => {},
    }
    const needle = "Content-Length: ";
    const pos = std.mem.indexOf(u8, data, needle) orelse return 0;
    const start = pos + needle.len;
    var end = start;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == start) return 0;
    return std.fmt.parseInt(usize, data[start..end], 10) catch 0;
}

// ── Task constructors ─────────────────────────────────────────────

fn statusLine(code: u16) []const u8 {
    return switch (code) {
        200 => "HTTP/1.1 200 OK\r\n",
        201 => "HTTP/1.1 201 Created\r\n",
        204 => "HTTP/1.1 204 No Content\r\n",
        301 => "HTTP/1.1 301 Moved Permanently\r\n",
        302 => "HTTP/1.1 302 Found\r\n",
        400 => "HTTP/1.1 400 Bad Request\r\n",
        404 => "HTTP/1.1 404 Not Found\r\n",
        405 => "HTTP/1.1 405 Method Not Allowed\r\n",
        500 => "HTTP/1.1 500 Internal Server Error\r\n",
        503 => "HTTP/1.1 503 Service Unavailable\r\n",
        else => "HTTP/1.1 200 OK\r\n",
    };
}

/// Build a SendTask from a Response object.
/// Per-response headers go into st.hdr. Body pointer set from resp.body.
fn makeResponseSend(conn_idx: u16, resp: response_mod.Response) SendTask {
    var st = SendTask{
        .conn = conn_idx,
        .hdr = undefined,
        .hdr_len = 0,
        .status_line = statusLine(resp.status),
        .body = resp.body,
    };
    writePerResponseHeaders(&st, &resp);
    return st;
}

fn makeErrorSend(conn_idx: u16, status: u16) SendTask {
    var st = SendTask{
        .conn = conn_idx,
        .hdr = undefined,
        .hdr_len = 0,
        .status_line = statusLine(status),
        .body = null,
    };
    const suffix = "Connection: close\r\nContent-Length: 0\r\n\r\n";
    @memcpy(st.hdr[0..suffix.len], suffix);
    st.hdr_len = suffix.len;
    return st;
}

/// Format per-response headers into SendTask.hdr:
///   Connection: keep-alive\r\n
///   Content-Type: ...\r\n    (from handler)
///   Content-Length: N\r\n
///   \r\n
fn writePerResponseHeaders(st: *SendTask, resp: *const response_mod.Response) void {
    var pos: usize = 0;

    const ka = "Connection: keep-alive\r\n";
    @memcpy(st.hdr[pos..][0..ka.len], ka);
    pos += ka.len;

    // User headers from the Response
    for (resp.headers[0..resp.header_count]) |h| {
        const needed = h.name.len + 2 + h.value.len + 2;
        if (pos + needed > st.hdr.len) break;
        @memcpy(st.hdr[pos..][0..h.name.len], h.name);
        pos += h.name.len;
        st.hdr[pos] = ':';
        st.hdr[pos + 1] = ' ';
        pos += 2;
        @memcpy(st.hdr[pos..][0..h.value.len], h.value);
        pos += h.value.len;
        st.hdr[pos] = '\r';
        st.hdr[pos + 1] = '\n';
        pos += 2;
    }

    // Content-Length
    const body_len = if (resp.body) |b| b.len else 0;
    {
        const cl = "Content-Length: ";
        @memcpy(st.hdr[pos..][0..cl.len], cl);
        pos += cl.len;
        const len_str = std.fmt.bufPrint(st.hdr[pos..], "{d}", .{body_len}) catch return;
        pos += len_str.len;
        st.hdr[pos] = '\r';
        st.hdr[pos + 1] = '\n';
        pos += 2;
    }

    // End of headers
    st.hdr[pos] = '\r';
    st.hdr[pos + 1] = '\n';
    pos += 2;

    st.hdr_len = pos;
}

// ── Tests ─────────────────────────────────────────────────────────

test "cached common headers" {
    refreshCommonHeaders();
    const hdr = commonHeaders();
    try std.testing.expect(hdr.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, hdr, "Server: snek\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, hdr, "Date:") != null);
    try std.testing.expect(std.mem.endsWith(u8, hdr, "GMT\r\n"));
}

test "cached headers stable within same second" {
    refreshCommonHeaders();
    const a = commonHeaders();
    refreshCommonHeaders();
    const b = commonHeaders();
    try std.testing.expectEqualStrings(a, b);
}

test "makeResponseSend 200 text" {
    refreshCommonHeaders();
    const resp = response_mod.Response.text("hello");
    const st = makeResponseSend(5, resp);
    try std.testing.expectEqual(@as(u16, 5), st.conn);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", st.status_line);
    try std.testing.expectEqualStrings("hello", st.body.?);
    // Per-response headers should contain Content-Type and Content-Length
    const hdr = st.hdr[0..st.hdr_len];
    try std.testing.expect(std.mem.indexOf(u8, hdr, "Content-Type: text/plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, hdr, "Content-Length: 5") != null);
    try std.testing.expect(std.mem.endsWith(u8, hdr, "\r\n\r\n"));
}

test "makeErrorSend" {
    const st = makeErrorSend(3, 400);
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request\r\n", st.status_line);
    try std.testing.expect(st.body == null);
    try std.testing.expect(std.mem.indexOf(u8, st.hdr[0..st.hdr_len], "Connection: close") != null);
}

test "HeadParser finds header end" {
    var p: std.http.HeadParser = .{};
    const data = "GET / HTTP/1.1\r\nHost: h\r\n\r\nbody";
    const consumed = p.feed(data);
    try std.testing.expectEqual(std.http.HeadParser.State.finished, p.state);
    try std.testing.expectEqualStrings("body", data[consumed..]);
}

test "HeadParser streaming" {
    var p: std.http.HeadParser = .{};
    _ = p.feed("GET / HTTP/1.1\r\nHost: h\r\n\r");
    try std.testing.expect(p.state != .finished);
    _ = p.feed("\nbody");
    try std.testing.expectEqual(std.http.HeadParser.State.finished, p.state);
}

test "simdScreenBytes classifies GET" {
    const input = "GGPGDGOH";
    var out: [8]bool = undefined;
    simdScreenBytes(input, 'G', &out);
    try std.testing.expect(out[0]); // G
    try std.testing.expect(out[1]); // G
    try std.testing.expect(!out[2]); // P
    try std.testing.expect(out[3]); // G
    try std.testing.expect(!out[4]); // D
    try std.testing.expect(out[5]); // G
    try std.testing.expect(!out[6]); // O
    try std.testing.expect(!out[7]); // H
}

test "quickContentLength GET" {
    try std.testing.expectEqual(@as(usize, 0), quickContentLength("GET / HTTP/1.1\r\nHost: h\r\n\r\n"));
}

test "quickContentLength HEAD" {
    try std.testing.expectEqual(@as(usize, 0), quickContentLength("HEAD / HTTP/1.1\r\n\r\n"));
}

test "quickContentLength POST with body" {
    try std.testing.expectEqual(@as(usize, 13), quickContentLength("POST /x HTTP/1.1\r\nContent-Length: 13\r\n\r\n"));
}

test "quickContentLength POST no body" {
    try std.testing.expectEqual(@as(usize, 0), quickContentLength("POST /x HTTP/1.1\r\nHost: h\r\n\r\n"));
}

test "Queue typed" {
    var q: Queue(HandleTask) = .{};
    q.push(.{ .conn = 1, .header_end = 100, .content_length = 0 });
    q.push(.{ .conn = 5, .header_end = 200, .content_length = 42 });
    try std.testing.expectEqual(@as(usize, 2), q.len);
    try std.testing.expectEqual(@as(u16, 1), q.slice()[0].conn);
}
