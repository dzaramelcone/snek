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
const stmt_cache_mod = @import("db/stmt_cache.zig");
const StmtCache = stmt_cache_mod.StmtCache;
const MAX_PG_STMTS = stmt_cache_mod.MAX_STMTS;
const Slab = @import("db/result_lease.zig").Slab;
const SlabPool = @import("db/result_lease.zig").SlabPool;
const snek_row = @import("python/snek_row.zig");
const perf = @import("observe/perf.zig");

const log = std.log.scoped(.@"snek/pipeline");

const MAX_BATCH = 1024;
const MAX_IOVECS = 4; // status | common | per-response | body
const TRANSPORT_SLAB_CACHE = 16;
const TRANSPORT_SLAB_MAX_LIVE = 64;
const RESULT_SLAB_CACHE = 128;
const RESULT_SLAB_MAX_LIVE = 1024;

// ── Cached response prefix ────────────────────────────────────────
// Recomputed once per second. Shared by all responses in the window.
//
//   Server: snek\r\n
//   Date: Thu, 28 Mar 2026 12:34:56 GMT\r\n
//
// ~50 bytes. Every response points to the same buffer.

const COMMON_HDR_CAP = 64;

threadlocal var cached_common_hdr: [COMMON_HDR_CAP]u8 = undefined;
threadlocal var cached_common_len: usize = 0;
threadlocal var cached_epoch: i64 = 0;

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

const RedisWaiter = struct {
    conn_idx: u16,
    py_coro: *ffi.PyObject,
};

const PgWaiter = struct {
    conn_idx: u16,
    py_coro: *ffi.PyObject,
    cmd: driver.PgCmd,
    stmt_idx: u16,
    model_cls: ?*ffi.PyObject,
};

const MAX_PG_CONNS = 8;
const PG_WAITER_CAP = MAX_BATCH;

pub const PgConn = struct {
    fd: posix.socket_t = undefined,
    send_task: Task = undefined,
    recv_task: Task = undefined,
    send_buf: [16384]u8 = undefined,
    send_len: usize = 0,
    send_state: enum { idle, sending } = .idle,
    send_offset: usize = 0,
    transport_buf: ?*Slab = null,
    recv_len: usize = 0,
    parse_pos: usize = 0,
    recv_state: enum { idle, receiving, parsing, err } = .idle,
    in_flight: usize = 0,
    prepared: [MAX_PG_STMTS]bool = .{false} ** MAX_PG_STMTS,
    waiters: [PG_WAITER_CAP]PgWaiter = undefined,
    waiter_head: usize = 0,
    waiter_tail: usize = 0,
    waiter_count: usize = 0,

    fn pushWaiter(self: *PgConn, conn_idx: u16, py_coro: *ffi.PyObject, cmd: driver.PgCmd, stmt_idx: u16, model_cls: ?*ffi.PyObject) !void {
        if (self.waiter_count >= PG_WAITER_CAP) return error.WaiterQueueFull;
        self.waiters[self.waiter_tail] = .{
            .conn_idx = conn_idx,
            .py_coro = py_coro,
            .cmd = cmd.normalize(),
            .stmt_idx = stmt_idx,
            .model_cls = model_cls,
        };
        self.waiter_tail = (self.waiter_tail + 1) % PG_WAITER_CAP;
        self.waiter_count += 1;
    }

    fn peekWaiter(self: *const PgConn) ?PgWaiter {
        if (self.waiter_count == 0) return null;
        return self.waiters[self.waiter_head];
    }

    fn peekWaiterAt(self: *const PgConn, offset: usize) ?PgWaiter {
        if (offset >= self.waiter_count) return null;
        return self.waiters[(self.waiter_head + offset) % PG_WAITER_CAP];
    }

    fn popWaiter(self: *PgConn) ?PgWaiter {
        if (self.waiter_count == 0) return null;
        const w = self.waiters[self.waiter_head];
        self.waiter_head = (self.waiter_head + 1) % PG_WAITER_CAP;
        self.waiter_count -= 1;
        return w;
    }

    fn ensureTransportBuffer(self: *PgConn, pool: *SlabPool) !void {
        if (self.transport_buf == null) self.transport_buf = try pool.acquire();
    }

    fn transportBytes(self: *PgConn) []u8 {
        return self.transport_buf.?.bytes();
    }

    fn transportBytesConst(self: *const PgConn) []const u8 {
        return self.transport_buf.?.constBytes();
    }

    fn rotateTransportBuffer(self: *PgConn, pool: *SlabPool) !void {
        try self.ensureTransportBuffer(pool);
        if (self.parse_pos == 0) return;

        const old = self.transport_buf.?;
        const remaining = self.recv_len - self.parse_pos;
        const next = try pool.acquire();
        if (remaining > 0) {
            @memcpy(next.bytes()[0..remaining], old.constBytes()[self.parse_pos..self.recv_len]);
        }
        self.transport_buf = next;
        self.recv_len = remaining;
        self.parse_pos = 0;
        old.release();
    }

    fn deinitTransportBuffer(self: *PgConn) void {
        if (self.transport_buf) |slab| {
            self.transport_buf = null;
            slab.release();
        }
    }
};

// ── Typed stage queues ────────────────────────────────────────────

pub fn Queue(comptime T: type) type {
    return struct {
        items: [MAX_BATCH]T = undefined,
        len: usize = 0,

        pub fn push(self: *@This(), item: T) !void {
            if (self.len >= MAX_BATCH) return error.Overflow;
            self.items[self.len] = item;
            self.len += 1;
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
    close_q: Queue(u16) = .{},

    // iovecs storage — one set of MAX_IOVECS per send task, reused each cycle
    iovecs_buf: [MAX_BATCH][MAX_IOVECS]posix.iovec_const = undefined,

    // ── Redis state (full-duplex: independent send/recv) ───────
    redis_fd: ?posix.socket_t = null,
    redis_send_task: Task = undefined,
    redis_recv_task: Task = undefined,
    redis_send_buf: [8192]u8 = undefined,
    redis_send_len: usize = 0,
    redis_send_state: enum { idle, sending } = .idle,
    redis_send_offset: usize = 0,
    redis_recv_buf: [8192]u8 = undefined,
    redis_recv_len: usize = 0,
    redis_parse_pos: usize = 0,
    redis_recv_state: enum { idle, receiving, parsing, err } = .idle,
    redis_waiters: [MAX_BATCH]RedisWaiter = undefined,
    redis_waiter_head: usize = 0,
    redis_waiter_tail: usize = 0,
    redis_waiter_count: usize = 0,
    redis_in_flight: usize = 0, // commands sent, awaiting RESP response

    // ── Postgres connection pool (full-duplex, round-robin) ────
    pg_conns: [MAX_PG_CONNS]PgConn = undefined,
    pg_conn_count: u8 = 0,
    pg_next_conn: u8 = 0, // round-robin counter
    pg_last_conn: u8 = 0, // last connection selected by pgSendSlice
    pg_wire_ns: u64 = 0, // total pg parse+py time (set by stagePostgres)
    pg_stmt_cache: StmtCache = .{},
    pg_transport_pool: SlabPool,
    pg_result_pool: SlabPool,

    // Stage timing stats
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, conns: *Pool(Conn), entries: u16) !Pipeline {
        return .{
            .backend = try aio.Backend.init(allocator, entries),
            .conns = conns,
            .allocator = allocator,
            .pg_transport_pool = try SlabPool.init(allocator, TRANSPORT_SLAB_CACHE, TRANSPORT_SLAB_MAX_LIVE),
            .pg_result_pool = try SlabPool.init(allocator, RESULT_SLAB_CACHE, RESULT_SLAB_MAX_LIVE),
        };
    }

    pub fn deinit(self: *Pipeline, allocator: std.mem.Allocator) void {
        for (self.pg_conns[0..self.pg_conn_count]) |*pg| {
            pg.deinitTransportBuffer();
        }
        self.pg_transport_pool.deinit();
        self.pg_result_pool.deinit();
        self.backend.deinit(allocator);
    }

    pub fn start(self: *Pipeline, listen_fd: posix.socket_t) !void {
        self.listen_fd = listen_fd;
        // Dummy step fn — pipeline ignores it, just need pending_op storage
        self.accept_task = Task.init(Pipeline, self, dummyStep);
        self.accept_task.tag = .accept;
        try self.backend.queue(&self.accept_task, IoOp{ .accept = .{ .socket = listen_fd } });
    }

    fn dummyStep(_: *Pipeline, _: *Task, _: IoResult) ?IoOp {
        return null;
    }

    // ── Main loop ─────────────────────────────────────────────────

    pub fn run(self: *Pipeline) !void {
        refreshCommonHeaders();
        self.stats.initPmu();
        defer self.stats.deinitPmu();
        while (self.running) {
            _ = try self.cycle(1);
            while (try self.cycle(0)) {}
        }
    }

    fn cycle(self: *Pipeline, wait_nr: u32) !bool {
        const t0 = try std.time.Instant.now();
        const completions = try self.backend.submitAndWait(wait_nr);
        if (completions.tasks.len == 0) return false;
        const t_io = try std.time.Instant.now();

        // PMU — comptime-stripped when no backend; sample near dump boundaries
        const pmu_before = if (comptime Stats.has_pmu)
            (if (self.stats.pmu.backend != null and self.stats.cycles % 10000 >= 9990) self.stats.pmuRead() else null)
        else {};

        // Refresh cached date header (once per second)
        refreshCommonHeaders();

        // Reset queues
        self.parse_q.len = 0;
        self.handle_q.len = 0;
        self.send_q.len = 0;
        self.close_q.len = 0;

        // Classify
        for (completions.tasks, completions.results) |task, result| {
            switch (task.tag) {
                .accept => self.onAccept(result),
                .redis_send => try self.onRedisSendIO(result),
                .redis_recv => try self.onRedisRecvIO(result),
                .pg_send => try self.onPgSendIO(self.matchPgSendTask(task) orelse continue, result),
                .pg_recv => try self.onPgRecvIO(self.matchPgRecvTask(task) orelse continue, result),
                .conn => try self.onConnCompletion(task, result),
            }
        }
        const t_classify = try std.time.Instant.now();

        // DAG
        try self.stageParse();
        const t_parse = try std.time.Instant.now();

        // GIL held across handle + redis + postgres stages (one acquire for all Python work)
        const py_ctx = if (self.req_ctx) |ctx| ctx.py_ctx else null;
        const need_gil = py_ctx != null and (self.handle_q.len > 0 or self.redis_recv_state == .parsing or self.redis_recv_state == .err or self.anyPgNeedsGil());
        if (need_gil) py_ctx.?.py.acquireGil();
        defer if (need_gil) py_ctx.?.py.releaseGil();

        try self.stageHandle();
        const t_handle = try std.time.Instant.now();
        try self.stageRedis();
        const t_redis = try std.time.Instant.now();
        const pg_rows_before = self.totalPgWaiters();
        try self.stagePostgres();
        const t_pg = try std.time.Instant.now();

        try self.stageSerializeAndSend();
        const t_send = try std.time.Instant.now();
        self.stageClose();

        // PMU snapshot — end
        if (comptime Stats.has_pmu) {
            self.stats.pmuAccum(pmu_before, self.stats.pmuRead());
        }

        // Accumulate timing stats
        self.stats.cycles += 1;
        self.stats.completions += completions.tasks.len;
        self.stats.ns_io += t_io.since(t0);
        self.stats.ns_classify += t_classify.since(t_io);
        self.stats.ns_parse += t_parse.since(t_classify);
        self.stats.ns_handle += t_handle.since(t_parse);
        self.stats.ns_redis += t_redis.since(t_handle);
        self.stats.ns_pg_wire += self.pg_wire_ns;
        self.stats.ns_pg_flush += t_pg.since(t_redis) -| self.pg_wire_ns;
        self.stats.pg_rows += pg_rows_before -| self.totalPgWaiters();
        self.stats.ns_send += t_send.since(t_pg);

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
        ns_pg_wire: u64 = 0,
        ns_pg_flush: u64 = 0,
        pg_rows: u64 = 0,
        ns_send: u64 = 0,
        // PMU — comptime-stripped when no backend available
        pmu: if (has_pmu) PmuState else void = if (has_pmu) .{} else {},

        const has_pmu = perf.Backend != void;

        const PmuState = struct {
            backend: ?perf.Backend = null,
            cpu_cycles: u64 = 0,
            instructions: u64 = 0,
            branches: u64 = 0,
            branch_misses: u64 = 0,
            cache_misses: u64 = 0,
            tlb_misses: u64 = 0,
        };

        fn initPmu(self: *Stats) void {
            if (comptime !has_pmu) return;
            if (perf.Backend.init()) |pe| {
                self.pmu.backend = pe;
                log.info("PMU counters enabled", .{});
            } else |err| {
                log.info("PMU unavailable: {s}", .{@errorName(err)});
            }
        }

        fn deinitPmu(self: *Stats) void {
            if (comptime !has_pmu) return;
            if (self.pmu.backend) |*p| perf.deinit(p);
        }

        fn pmuRead(self: *Stats) if (has_pmu) ?perf.Counters else void {
            if (comptime !has_pmu) return {};
            if (self.pmu.backend) |*p| return perf.read(p);
            return null;
        }

        fn pmuAccum(self: *Stats, before: anytype, after: anytype) void {
            if (comptime !has_pmu) return;
            const b = before orelse return;
            const a = after orelse return;
            const d = perf.Counters.diff(a, b);
            self.pmu.cpu_cycles += d.cycles;
            self.pmu.instructions += d.instructions;
            self.pmu.branches += d.branches;
            self.pmu.branch_misses += d.missed_branches;
            self.pmu.cache_misses += d.cache_misses;
            self.pmu.tlb_misses += d.tlb_misses;
        }

        fn dump(self: *Stats) void {
            const total = self.ns_io + self.ns_classify + self.ns_parse + self.ns_handle + self.ns_redis + self.ns_pg_wire + self.ns_pg_flush + self.ns_send;
            const reqs = self.completions;
            const us = struct {
                fn f(ns: u64) u64 {
                    return ns / 1000;
                }
            }.f;
            log.info(
                "PROFILE  cycles={d}  reqs={d}  total={d}us  io={d}us  classify={d}us  parse={d}us  handle={d}us  redis={d}us  pg={d}us({d}rows)  pg_flush={d}us  send={d}us",
                .{ self.cycles, reqs, us(total), us(self.ns_io), us(self.ns_classify), us(self.ns_parse), us(self.ns_handle), us(self.ns_redis), us(self.ns_pg_wire), self.pg_rows, us(self.ns_pg_flush), us(self.ns_send) },
            );
            if (comptime has_pmu) {
                if (self.pmu.cpu_cycles > 0) {
                    log.info(
                        "PMU  cycles={d}  insn={d}  IPC={d}.{d:0>2}  branches={d}  mispredict={d}  L1miss={d}  TLBmiss={d}",
                        .{
                            self.pmu.cpu_cycles, self.pmu.instructions,
                            self.pmu.instructions / (self.pmu.cpu_cycles | 1),
                            (self.pmu.instructions * 100 / (self.pmu.cpu_cycles | 1)) % 100,
                            self.pmu.branches, self.pmu.branch_misses,
                            self.pmu.cache_misses, self.pmu.tlb_misses,
                        },
                    );
                }
                self.pmu = .{ .backend = self.pmu.backend };
            }
            self.completions = 0;
            self.ns_io = 0;
            self.ns_classify = 0;
            self.ns_parse = 0;
            self.ns_handle = 0;
            self.ns_redis = 0;
            self.ns_pg_wire = 0;
            self.ns_pg_flush = 0;
            self.pg_rows = 0;
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

    fn onConnCompletion(self: *Pipeline, task: *Task, result: IoResult) !void {
        const conn: *Conn = @fieldParentPtr("task", task);
        const index = conn.pool_index;

        switch (task.pending_op) {
            .recv => {
                if (result <= 0) {
                    try self.close_q.push(index);
                    return;
                }
                conn.zc.mark_written(@intCast(result));
                try self.parse_q.push(.{ .conn = index });
            },
            .send, .sendv => {
                if (result < 0) {
                    try self.close_q.push(index);
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

    fn stageParse(self: *Pipeline) !void {
        for (self.parse_q.slice()) |pt| {
            const conn = self.conns.get_ptr(pt.conn);
            const data = conn.zc.as_slice();

            const new_bytes = data[conn.head_fed..];
            const consumed = conn.head_parser.feed(new_bytes);
            conn.head_fed += consumed;

            if (conn.head_parser.state != .finished) {
                conn.recv_slice = conn.zc.get_write_area(4096) catch {
                    try self.close_q.push(pt.conn);
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
                        try self.close_q.push(pt.conn);
                        continue;
                    };
                    self.submitRecv(conn);
                    continue;
                }
            }

            try self.handle_q.push(.{
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

    fn stageHandle(self: *Pipeline) !void {
        const req_ctx = self.req_ctx orelse return;
        const batch = self.handle_q.slice();
        if (batch.len == 0) return;

        // ── SIMD screen: gather + classify ───────────────────────
        var first_bytes: [MAX_BATCH]u8 = undefined;
        for (batch, 0..) |ht, i| {
            const data = self.conns.get_ptr(ht.conn).zc.as_slice();
            first_bytes[i] = if (data.len > 0) data[0] else 0;
        }
        var is_get: [MAX_BATCH]bool = .{false} ** MAX_BATCH;
        simdScreenBytes(first_bytes[0..batch.len], 'G', is_get[0..batch.len]);

        const py_ctx = req_ctx.py_ctx;

        for (batch, 0..) |ht, i| {
            const conn = self.conns.get_ptr(ht.conn);
            const data = conn.zc.as_slice();

            // Fast path: SIMD told us byte[0]=='G'. Check "GET / " or "GET /x".
            if (is_get[i] and data.len >= 6 and std.mem.eql(u8, data[1..4], "ET ")) {
                const uri_start = 4;
                const uri_end = std.mem.indexOfScalarPos(u8, data, uri_start, ' ') orelse data.len;
                const uri = data[uri_start..uri_end];

                switch (req_ctx.router.match(.GET, uri)) {
                    .found => |found| {
                        if (req_ctx.py_handler_ids[found.handler_id]) |py_id| {
                            if (py_ctx) |py| {
                                const flags = module.getHandlerFlags(py.py.snek_module, py_id);
                                if (flags.no_args) {
                                    const result = try driver.invokePythonHandler(
                                        py.py.snek_module, py_id, &http1.Request{},
                                        &.{}, &conn.body_buf,
                                        self.redisSendSlice(), self.pgSendSlice(), self.pgStmtCache(), self.pgConnPrepared(),
                                    );
                                    try self.handleResult(ht.conn, result);
                                    continue;
                                }
                                const req = http1.Request.parse(data[0..ht.header_end]) catch {
                                    try self.send_q.push(makeErrorSend(ht.conn, 400));
                                    continue;
                                };
                                const result = driver.invokePythonHandler(
                                    py.py.snek_module, py_id, &req,
                                    found.params[0..found.param_count], &conn.body_buf,
                                    self.redisSendSlice(), self.pgSendSlice(), self.pgStmtCache(), self.pgConnPrepared(),
                                ) catch {
                                    try self.send_q.push(makeErrorSend(ht.conn, 500));
                                    continue;
                                };
                                try self.handleResult(ht.conn, result);
                                continue;
                            }
                            try self.send_q.push(makeErrorSend(ht.conn, 503));
                        } else if (req_ctx.handlers[found.handler_id]) |h| {
                            const req = http1.Request.parse(data[0..ht.header_end]) catch {
                                try self.send_q.push(makeErrorSend(ht.conn, 400));
                                continue;
                            };
                            try self.send_q.push(makeResponseSend(ht.conn, h(&req)));
                        } else {
                            try self.send_q.push(makeErrorSend(ht.conn, 500));
                        }
                        continue;
                    },
                    .not_found => {
                        try self.send_q.push(makeErrorSend(ht.conn, 404));
                        continue;
                    },
                    .method_not_allowed => {
                        var r = response_mod.Response.init(405);
                        r.body = "Method Not Allowed";
                        try self.send_q.push(makeResponseSend(ht.conn, r));
                        continue;
                    },
                }
            }

            // Slow path: non-GET or SIMD screen missed — full parse
            const req = http1.Request.parse(data[0..ht.header_end]) catch {
                try self.send_q.push(makeErrorSend(ht.conn, 400));
                continue;
            };
            const method_str = if (req.method) |m| @tagName(m) else "GET";
            const method = router_mod.Method.fromString(method_str) orelse .GET;

            switch (req_ctx.router.match(method, req.uri orelse "/")) {
                .found => |found| {
                    if (req_ctx.py_handler_ids[found.handler_id]) |py_id| {
                        if (py_ctx) |py| {
                            const result = try driver.invokePythonHandler(
                                py.py.snek_module, py_id, &req,
                                found.params[0..found.param_count], &conn.body_buf,
                                self.redisSendSlice(), self.pgSendSlice(), self.pgStmtCache(), self.pgConnPrepared(),
                            );
                            try self.handleResult(ht.conn, result);
                        } else {
                            try self.send_q.push(makeErrorSend(ht.conn, 503));
                        }
                    } else if (req_ctx.handlers[found.handler_id]) |h| {
                        try self.send_q.push(makeResponseSend(ht.conn, h(&req)));
                    } else {
                        try self.send_q.push(makeErrorSend(ht.conn, 500));
                    }
                },
                .not_found => try self.send_q.push(makeErrorSend(ht.conn, 404)),
                .method_not_allowed => {
                    var r = response_mod.Response.init(405);
                    r.body = "Method Not Allowed";
                    try self.send_q.push(makeResponseSend(ht.conn, r));
                },
            }
        }
    }

    /// Handle an InvokeResult: response goes to send_q, yields update send buffers + push waiters.
    fn handleResult(self: *Pipeline, conn: u16, result: driver.InvokeResult) !void {
        switch (result) {
            .response => |resp| try self.send_q.push(makeResponseSend(conn, resp)),
            .redis_yield => |ry| {
                self.redis_send_len += ry.bytes_written;
                try self.pushRedisWaiter(conn, ry.py_coro);
            },
            .pg_yield => |pg| {
                // The round-robin PgConn was selected by pgSendSlice before
                // classifySentinel wrote into its send buffer. pg_last_conn
                // tracks which connection was selected.
                const pg_conn = &self.pg_conns[self.pg_last_conn];
                pg_conn.send_len += pg.bytes_written;
                errdefer ffi.xdecref(pg.model_cls);
                try pg_conn.pushWaiter(conn, pg.py_coro, pg.cmd, pg.stmt_idx, pg.model_cls);
            },
        }
    }

    /// Remaining writable slice of the redis send buffer.
    fn redisSendSlice(self: *Pipeline) ?[]u8 {
        if (self.redis_fd == null) return null;
        if (self.redis_send_len >= self.redis_send_buf.len) return null;
        return self.redis_send_buf[self.redis_send_len..];
    }

    /// Pick the next PgConn round-robin and return its writable send slice.
    fn pgSendSlice(self: *Pipeline) ?[]u8 {
        if (self.pg_conn_count == 0) return null;
        const idx = self.pg_next_conn;
        self.pg_next_conn = (self.pg_next_conn + 1) % self.pg_conn_count;
        self.pg_last_conn = idx;
        const pg = &self.pg_conns[idx];
        if (pg.send_len >= pg.send_buf.len) return null;
        return pg.send_buf[pg.send_len..];
    }

    /// Statement cache for prepared statements.
    fn pgStmtCache(self: *Pipeline) ?*StmtCache {
        if (self.pg_conn_count == 0) return null;
        return &self.pg_stmt_cache;
    }

    /// Per-connection prepared statement bitset for the last selected connection.
    fn pgConnPrepared(self: *Pipeline) ?*[MAX_PG_STMTS]bool {
        if (self.pg_conn_count == 0) return null;
        return &self.pg_conns[self.pg_last_conn].prepared;
    }

    // ── Stage: Serialize + Send ───────────────────────────────────
    // Formats per-response headers, builds iovecs, submits sendv.
    //
    // Each response is scattered across up to 4 iovecs:
    //   [0] status line       — static string ("HTTP/1.1 200 OK\r\n")
    //   [1] common headers    — cached per-second ("Server: snek\r\nDate: ...\r\n")
    //   [2] per-response hdrs — "Connection: keep-alive\r\nContent-Type: ...\r\nContent-Length: N\r\n\r\n"
    //   [3] body              — from conn.body_buf or static string

    fn stageSerializeAndSend(self: *Pipeline) !void {
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
                try self.close_q.push(st.conn);
            };
        }
    }

    // ── Redis IO ──────────────────────────────────────────────────
    // Redis completions arrive during classify. The state machine drives
    // send → recv transitions. RESP parsing + coroutine resumption happens
    // here with GIL held, pushing completed responses to send_q.

    /// IO state machine only — no Python work. Defers RESP parsing to stageRedis.
    fn onRedisSendIO(self: *Pipeline, result: IoResult) !void {
        if (result <= 0) {
            self.redis_recv_state = .err;
            return;
        }
        const sent: usize = @intCast(result);
        self.redis_send_offset += sent;
        if (self.redis_send_offset < self.redis_send_len) {
            try self.submitRedisSend();
            return;
        }
        // Send complete — compact and go idle
        self.redis_send_len = 0;
        self.redis_send_offset = 0;
        self.redis_send_state = .idle;
    }

    fn onRedisRecvIO(self: *Pipeline, result: IoResult) !void {
        if (result <= 0) {
            self.redis_recv_state = .err;
            return;
        }
        self.redis_recv_len += @intCast(result);
        self.redis_recv_state = .parsing;
    }

    /// Process redis: parse RESP responses + flush pending sends.
    /// Full-duplex: send and receive operate independently.
    /// GIL is already held from stageHandle.
    fn stageRedis(self: *Pipeline) !void {
        if (self.redis_fd == null) return;

        // 1. Handle deferred errors
        if (self.redis_recv_state == .err) {
            try self.failRedisWaiters();
        }

        // 2. Parse RESP responses
        if (self.redis_recv_state == .parsing) {
            try self.parseRedisResponses();

            if (self.redis_in_flight > 0) {
                self.compactRedisRecv();
                self.redis_recv_state = .receiving;
                try self.submitRedisRecv();
            } else {
                self.redis_recv_state = .idle;
            }
        }

        // 3. Flush pending sends (independent of recv state)
        const new_queries = self.redis_waiter_count - self.redis_in_flight;
        if (new_queries > 0 and self.redis_send_state == .idle and self.redis_send_len > 0) {
            self.redis_in_flight += new_queries;
            self.redis_send_state = .sending;
            try self.submitRedisSend();
            // Arm recv if not already receiving
            if (self.redis_recv_state == .idle) {
                self.redis_recv_state = .receiving;
                try self.submitRedisRecv();
            }
        }
    }

    fn parseRedisResponses(self: *Pipeline) !void {
        while (self.redis_in_flight > 0 and self.redis_waiter_count > 0) {
            if (!try self.parseOneResp()) break; // incomplete
        }
    }

    /// Parse one RESP response and resume the head waiter's coroutine.
    fn parseOneResp(self: *Pipeline) !bool {
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
                try self.failHeadWaiter();
                self.redis_in_flight -= 1;
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
        try self.resumeRedisWaiter(py_result);
        self.redis_in_flight -= 1;
        return true;
    }

    /// Resume the head waiter's Python coroutine with a redis result.
    /// Uses PyIter_Send — no method lookup, no StopIteration exception overhead.
    fn resumeRedisWaiter(self: *Pipeline, result: *ffi.PyObject) !void {
        defer ffi.decref(result); // iterSend increfs internally; we own the creation ref
        const waiter = self.popRedisWaiter() orelse return;
        const conn = self.conns.get_ptr(waiter.conn_idx);

        const send = ffi.iterSend(waiter.py_coro, result);
        switch (send.status) {
            .next => {
                // Coroutine yielded again — classify sentinel
                const sentinel = send.result.?;
                defer ffi.decref(sentinel);
                const yield = driver.classifySentinel(
                    sentinel, waiter.py_coro,
                    self.redisSendSlice(), self.pgSendSlice(),
                    self.pgStmtCache(), self.pgConnPrepared(),
                ) catch {
                    ffi.coroutineClose(waiter.py_coro);
                    ffi.decref(waiter.py_coro);
                    try self.send_q.push(makeErrorSend(waiter.conn_idx, 500));
                    return;
                };
                switch (yield) {
                    .redis => |ry| {
                        self.redis_send_len += ry.bytes_written;
                        try self.pushRedisWaiter(waiter.conn_idx, ry.py_coro);
                        self.redis_in_flight += 1;
                    },
                    .pg => |pg_yield| {
                        const pg_conn = &self.pg_conns[self.pg_last_conn];
                        pg_conn.send_len += pg_yield.bytes_written;
                        errdefer ffi.xdecref(pg_yield.model_cls);
                        try pg_conn.pushWaiter(waiter.conn_idx, pg_yield.py_coro, pg_yield.cmd, pg_yield.stmt_idx, pg_yield.model_cls);
                    },
                }
            },
            .@"return" => {
                ffi.decref(waiter.py_coro);
                const py_res = send.result orelse {
                    try self.send_q.push(makeErrorSend(waiter.conn_idx, 500));
                    return;
                };
                defer ffi.decref(py_res);
                const resp = driver.convertPythonResponse(py_res, &conn.body_buf) catch
                    response_mod.Response.init(500);
                try self.send_q.push(makeResponseSend(waiter.conn_idx, resp));
            },
            .@"error" => {
                ffi.decref(waiter.py_coro);
                if (ffi.errOccurred()) ffi.errPrint();
                try self.send_q.push(makeErrorSend(waiter.conn_idx, 500));
            },
        }
    }

    fn failHeadWaiter(self: *Pipeline) !void {
        const waiter = self.popRedisWaiter() orelse return;
        ffi.coroutineClose(waiter.py_coro);
        ffi.decref(waiter.py_coro);
        try self.send_q.push(makeErrorSend(waiter.conn_idx, 500));
    }

    fn failRedisWaiters(self: *Pipeline) !void {
        while (self.redis_waiter_count > 0) {
            try self.failHeadWaiter();
        }
        self.redis_recv_state = .idle;
        self.redis_send_state = .idle;
        self.redis_in_flight = 0;
    }

    fn pushRedisWaiter(self: *Pipeline, conn_idx: u16, py_coro: *ffi.PyObject) !void {
        if (self.redis_waiter_count >= MAX_BATCH) return error.WaiterQueueFull;
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

    fn submitRedisSend(self: *Pipeline) !void {
        const fd = self.redis_fd orelse return;
        const op = IoOp{ .send = .{ .socket = fd, .buffer = self.redis_send_buf[self.redis_send_offset..self.redis_send_len] } };
        self.redis_send_task.pending_op = op;
        try self.backend.queue(&self.redis_send_task, op);
    }

    fn submitRedisRecv(self: *Pipeline) !void {
        const fd = self.redis_fd orelse return;
        const op = IoOp{ .recv = .{ .socket = fd, .buffer = self.redis_recv_buf[self.redis_recv_len..] } };
        self.redis_recv_task.pending_op = op;
        try self.backend.queue(&self.redis_recv_task, op);
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


    pub fn initRedis(self: *Pipeline, fd: posix.socket_t) void {
        self.redis_fd = fd;
        self.redis_send_task = Task.init(Pipeline, self, dummyStep);
        self.redis_send_task.tag = .redis_send;
        self.redis_recv_task = Task.init(Pipeline, self, dummyStep);
        self.redis_recv_task.tag = .redis_recv;
        log.info("redis connected fd={d}", .{fd});
    }

    // ── Postgres IO ──────────────────────────────────────────────
    // Mirrors redis: IO state machine (GIL-free), parsing + coroutine
    // resumption in stagePostgres (under GIL).

    fn onPgSendIO(_: *Pipeline, pg: *PgConn, result: IoResult) !void {
        if (result <= 0) {
            pg.recv_state = .err;
            return;
        }
        const sent: usize = @intCast(result);
        pg.send_offset += sent;
        if (pg.send_offset < pg.send_len) {
            return; // partial send — will be re-submitted by stagePostgres
        }
        pg.send_len = 0;
        pg.send_offset = 0;
        pg.send_state = .idle;
    }

    fn onPgRecvIO(_: *Pipeline, pg: *PgConn, result: IoResult) !void {
        if (result <= 0) {
            pg.recv_state = .err;
            return;
        }
        pg.recv_len += @intCast(result);
        pg.recv_state = .parsing;
    }

    /// Process postgres: parse responses + flush pending sends for all connections.
    /// GIL is already held from stageHandle.
    fn stagePostgres(self: *Pipeline) !void {
        self.pg_wire_ns = 0;
        if (self.pg_conn_count == 0) return;

        for (self.pg_conns[0..self.pg_conn_count]) |*pg| {
            // 1. Handle deferred errors
            if (pg.recv_state == .err) {
                try self.failPgConnWaiters(pg);
            }

            // 2. Parse responses
            if (pg.recv_state == .parsing) {
                const t0 = try std.time.Instant.now();
                try self.parsePgConnResponses(pg);
                self.pg_wire_ns += (try std.time.Instant.now()).since(t0);
                if (pg.parse_pos > 0) {
                    pg.rotateTransportBuffer(&self.pg_transport_pool) catch |err| switch (err) {
                        error.SlabPoolExhausted => {
                            try self.failPgConnForTransportPool(pg);
                            continue;
                        },
                        else => return err,
                    };
                }

                if (pg.in_flight > 0) {
                    pg.recv_state = .receiving;
                    self.submitPgRecvFor(pg) catch |err| switch (err) {
                        error.SlabPoolExhausted => {
                            try self.failPgConnForTransportPool(pg);
                            continue;
                        },
                        else => return err,
                    };
                } else {
                    pg.recv_state = .idle;
                }
            }

            // 3. Flush pending sends — append single Sync for entire batch
            const new_queries = pg.waiter_count - pg.in_flight;
            if (new_queries > 0 and pg.send_state == .idle and pg.send_len > 0) {
                const wire_mod = @import("db/wire.zig");
                const sync = wire_mod.encodeSync(pg.send_buf[pg.send_len..]);
                pg.send_len += sync.len;
                pg.in_flight += new_queries;
                pg.send_state = .sending;
                try self.submitPgSendFor(pg);
                if (pg.recv_state == .idle) {
                    pg.recv_state = .receiving;
                    self.submitPgRecvFor(pg) catch |err| switch (err) {
                        error.SlabPoolExhausted => {
                            try self.failPgConnForTransportPool(pg);
                            continue;
                        },
                        else => return err,
                    };
                }
            }

            // 4. Re-submit partial sends
            if (pg.send_state == .sending and pg.send_offset > 0 and pg.send_offset < pg.send_len) {
                try self.submitPgSendFor(pg);
            }
        }

    }

    /// Parse PG responses from a batched Sync. Queries complete on CommandComplete
    /// (not ReadyForQuery). Results are collected first, then all coroutines are
    /// resumed together after parsing to avoid cascading re-yields.
    ///
    /// With batched Sync: N × (BindComplete + DataRow* + CommandComplete) + ReadyForQuery.
    /// ReadyForQuery may arrive in a later recv — we don't wait for it.
    fn wrapPgRowResult(waiter: PgWaiter, result_obj: *ffi.PyObject) ffi.PythonError!*ffi.PyObject {
        if (waiter.model_cls) |model_cls| {
            if (snek_row.isSnekRow(result_obj)) {
                errdefer ffi.decref(result_obj);
                const model_obj = try ffi.callMethodOneArg(model_cls, "_snek_from_row", result_obj);
                ffi.decref(result_obj);
                return model_obj;
            }
        }
        return result_obj;
    }

    fn parsePgConnResponses(self: *Pipeline, pg: *PgConn) !void {
        const wire = @import("db/wire.zig");

        // Collected completed query results — resumed after parse loop
        const CompletedQuery = struct { waiter: PgWaiter, result: *ffi.PyObject };
        var completed: [PG_WAITER_CAP]CompletedQuery = undefined;
        var completed_count: usize = 0;

        // Per-query accumulation state
        var py_result: ?*ffi.PyObject = null;
        var py_list: ?*ffi.PyObject = null;
        var waiter_offset: usize = 0;
        var col_descs: [64]wire.ColumnDesc = undefined;
        // Save position at the start of current query (not entire batch)
        var query_save_pos: usize = pg.parse_pos;

        while (waiter_offset < pg.waiter_count) {
            const data = pg.transportBytesConst()[pg.parse_pos..pg.recv_len];
            if (data.len < 5) {
                // Incomplete mid-query — rollback current query only
                pg.parse_pos = query_save_pos;
                if (py_result) |r| ffi.decref(r);
                if (py_list) |l| ffi.decref(l);
                break;
            }

            const hdr = wire.readMessageHeader(data[0..5]) catch {
                pg.parse_pos = query_save_pos;
                if (py_result) |r| ffi.decref(r);
                if (py_list) |l| ffi.decref(l);
                break;
            };
            const msg_len: usize = @intCast(hdr.length);
            if (data.len < 1 + msg_len) {
                pg.parse_pos = query_save_pos;
                if (py_result) |r| ffi.decref(r);
                if (py_list) |l| ffi.decref(l);
                break;
            }

            const payload = data[5..][0 .. msg_len - 4];
            pg.parse_pos += 1 + msg_len;

            // ReadyForQuery is a batch-level message, not per-query
            if (hdr.tag == wire.BackendTag.ready_for_query) {
                continue; // consume it, don't break — there may be more batches
            }

            const waiter = pg.peekWaiterAt(waiter_offset) orelse break;
            const stmt_entry = self.pg_stmt_cache.get(waiter.stmt_idx);
            const col_count: u16 = if (stmt_entry.described) stmt_entry.col_count else 0;

            switch (hdr.tag) {
                wire.BackendTag.parse_complete, wire.BackendTag.bind_complete => continue,
                wire.BackendTag.no_data => {
                    if (!stmt_entry.described) {
                        stmt_entry.col_count = 0;
                        stmt_entry.described = true;
                    }
                    continue;
                },
                wire.BackendTag.row_description => {
                    const parsed_cols = wire.parseRowDescription(payload, &col_descs) catch 0;
                    if (!stmt_entry.described) {
                        stmt_entry.col_count = parsed_cols;
                        stmt_entry.described = true;
                        for (0..parsed_cols) |ki| {
                            stmt_entry.col_keys[ki] = ffi.unicodeFromSlice(col_descs[ki].name.ptr, col_descs[ki].name.len) catch null;
                            stmt_entry.col_strategies[ki] = snek_row.strategyForOid(col_descs[ki].type_oid);
                        }
                        stmt_entry.buildJsonKeys();
                    }
                },
                wire.BackendTag.data_row => {
                    var values: [64]?[]const u8 = undefined;
                    const field_count = wire.parseDataRow(payload, &values) catch 0;

                    const raw_result = if (snek_row.create(
                        &self.pg_stmt_cache,
                        waiter.stmt_idx,
                        @intCast(@min(col_count, field_count)),
                        values[0..@min(col_count, field_count)],
                        &self.pg_result_pool,
                    ) catch null) |row|
                        row
                    else blk: {
                        const dict = try ffi.dictNew();
                        for (0..@min(col_count, field_count)) |i| {
                            const name = stmt_entry.col_keys[i] orelse continue;
                            if (values[i]) |val| {
                                const val_obj = try ffi.unicodeFromSlice(val.ptr, val.len);
                                defer ffi.decref(val_obj);
                                try ffi.dictSetItem(dict, name, val_obj);
                            } else {
                                try ffi.dictSetItem(dict, name, ffi.none());
                            }
                        }
                        break :blk dict;
                    };
                    const result_obj = try wrapPgRowResult(waiter, raw_result);

                    const wait_cmd = waiter.cmd.normalize();
                    if (wait_cmd == .FETCH_ONE) {
                        if (py_result == null) py_result = result_obj else ffi.decref(result_obj);
                    } else if (wait_cmd == .FETCH_ALL) {
                        if (py_list == null) py_list = c.PyList_New(0) orelse return error.PythonError;
                        if (c.PyList_Append(py_list.?, result_obj) != 0) return error.PythonError;
                        ffi.decref(result_obj);
                    } else {
                        ffi.decref(result_obj);
                    }
                },
                wire.BackendTag.command_complete => {
                    if (waiter.cmd == .EXECUTE) {
                        const tag = wire.parseCommandComplete(payload);
                        var count: i64 = 0;
                        if (std.mem.lastIndexOfScalar(u8, tag, ' ')) |space| {
                            count = std.fmt.parseInt(i64, tag[space + 1 ..], 10) catch 0;
                        }
                        py_result = ffi.longFromLong(count) catch ffi.getNone();
                    }

                    const final_result = if (waiter.cmd == .FETCH_ALL)
                        py_list orelse (c.PyList_New(0) orelse return error.PythonError)
                    else
                        py_result orelse ffi.getNone();

                    completed[completed_count] = .{ .waiter = waiter, .result = final_result };
                    completed_count += 1;
                    py_result = null;
                    py_list = null;
                    waiter_offset += 1;
                    query_save_pos = pg.parse_pos; // this query is fully parsed
                },
                wire.BackendTag.error_response => {
                    if (py_list) |l| ffi.decref(l);
                    if (py_result) |r| ffi.decref(r);
                    py_list = null;
                    py_result = null;
                    // Error aborts remaining queries — fail them all
                    for (completed[0..completed_count]) |cq| {
                        ffi.decref(cq.result);
                        ffi.xdecref(cq.waiter.model_cls);
                        ffi.coroutineClose(cq.waiter.py_coro);
                        ffi.decref(cq.waiter.py_coro);
                        try self.send_q.push(makeErrorSend(cq.waiter.conn_idx, 500));
                    }
                    for (0..waiter_offset) |_| {
                        _ = pg.popWaiter();
                        pg.in_flight -= 1;
                    }
                    try self.failPgConnWaiters(pg);
                    return;
                },
                else => continue,
            }
        }

        // Pop completed waiters and resume coroutines (outside parse loop)
        for (0..completed_count) |_| {
            _ = pg.popWaiter();
            pg.in_flight -= 1;
        }
        for (completed[0..completed_count]) |cq| {
            try self.resumePgWaiter(cq.waiter, cq.result);
        }
    }

    fn resumePgWaiter(self: *Pipeline, waiter: PgWaiter, result: *ffi.PyObject) !void {
        defer ffi.decref(result); // iterSend increfs internally; we own the creation ref
        defer ffi.xdecref(waiter.model_cls);
        const conn = self.conns.get_ptr(waiter.conn_idx);
        const send = ffi.iterSend(waiter.py_coro, result);
        switch (send.status) {
            .next => {
                // Coroutine yielded again — classify sentinel
                const sentinel = send.result.?;
                defer ffi.decref(sentinel);
                const yield = driver.classifySentinel(
                    sentinel, waiter.py_coro,
                    self.redisSendSlice(), self.pgSendSlice(),
                    self.pgStmtCache(), self.pgConnPrepared(),
                ) catch {
                    ffi.coroutineClose(waiter.py_coro);
                    ffi.decref(waiter.py_coro);
                    try self.send_q.push(makeErrorSend(waiter.conn_idx, 500));
                    return;
                };
                switch (yield) {
                    .redis => |ry| {
                        self.redis_send_len += ry.bytes_written;
                        try self.pushRedisWaiter(waiter.conn_idx, ry.py_coro);
                    },
                    .pg => |pg_yield| {
                        const pg_conn = &self.pg_conns[self.pg_last_conn];
                        pg_conn.send_len += pg_yield.bytes_written;
                        errdefer ffi.xdecref(pg_yield.model_cls);
                        try pg_conn.pushWaiter(waiter.conn_idx, pg_yield.py_coro, pg_yield.cmd, pg_yield.stmt_idx, pg_yield.model_cls);
                    },
                }
            },
            .@"return" => {
                ffi.decref(waiter.py_coro);
                const py_res = send.result orelse return error.PythonError;
                defer ffi.decref(py_res);
                const resp = driver.convertPythonResponse(py_res, &conn.body_buf) catch
                    response_mod.Response.init(500);
                try self.send_q.push(makeResponseSend(waiter.conn_idx, resp));
            },
            .@"error" => {
                ffi.decref(waiter.py_coro);
                if (ffi.errOccurred()) ffi.errPrint();
                try self.send_q.push(makeErrorSend(waiter.conn_idx, 500));
            },
        }
    }

    fn failPgConnForTransportPool(self: *Pipeline, pg: *PgConn) !void {
        log.warn(
            "postgres transport pool exhausted: fd={d} waiters={d} live={d}/{d} free={d}",
            .{ pg.fd, pg.waiter_count, self.pg_transport_pool.liveSlabs(), self.pg_transport_pool.maxLiveSlabs(), self.pg_transport_pool.freeCount() },
        );
        try self.failPgConnWaitersWithStatus(pg, 503, "Postgres transport pool exhausted");
    }

    fn failPgConnWaiters(self: *Pipeline, pg: *PgConn) !void {
        try self.failPgConnWaitersWithStatus(pg, 500, null);
    }

    fn failPgConnWaitersWithStatus(self: *Pipeline, pg: *PgConn, status: u16, body: ?[]const u8) !void {
        while (pg.waiter_count > 0) {
            const waiter = pg.popWaiter() orelse break;
            ffi.xdecref(waiter.model_cls);
            ffi.coroutineClose(waiter.py_coro);
            ffi.decref(waiter.py_coro);
            if (body) |msg| {
                var resp = response_mod.Response.init(status);
                _ = resp.setContentType("text/plain");
                _ = resp.setBody(msg);
                try self.send_q.push(makeResponseSend(waiter.conn_idx, resp));
            } else {
                try self.send_q.push(makeErrorSend(waiter.conn_idx, status));
            }
        }
        pg.recv_state = .idle;
        pg.send_state = .idle;
        pg.in_flight = 0;
        pg.recv_len = 0;
        pg.parse_pos = 0;
    }

    fn submitPgSendFor(self: *Pipeline, pg: *PgConn) !void {
        const op = IoOp{ .send = .{ .socket = pg.fd, .buffer = pg.send_buf[pg.send_offset..pg.send_len] } };
        pg.send_task.pending_op = op;
        try self.backend.queue(&pg.send_task, op);
    }

    fn submitPgRecvFor(self: *Pipeline, pg: *PgConn) !void {
        try pg.ensureTransportBuffer(&self.pg_transport_pool);
        const op = IoOp{ .recv = .{ .socket = pg.fd, .buffer = pg.transportBytes()[pg.recv_len..] } };
        pg.recv_task.pending_op = op;
        try self.backend.queue(&pg.recv_task, op);
    }

    fn matchPgSendTask(self: *Pipeline, task: *Task) ?*PgConn {
        for (self.pg_conns[0..self.pg_conn_count]) |*pg| {
            if (task == &pg.send_task) return pg;
        }
        return null;
    }

    fn matchPgRecvTask(self: *Pipeline, task: *Task) ?*PgConn {
        for (self.pg_conns[0..self.pg_conn_count]) |*pg| {
            if (task == &pg.recv_task) return pg;
        }
        return null;
    }

    fn anyPgNeedsGil(self: *Pipeline) bool {
        for (self.pg_conns[0..self.pg_conn_count]) |pg| {
            if (pg.recv_state == .parsing or pg.recv_state == .err) return true;
        }
        return false;
    }

    fn totalPgWaiters(self: *Pipeline) usize {
        var total: usize = 0;
        for (self.pg_conns[0..self.pg_conn_count]) |pg| {
            total += pg.waiter_count;
        }
        return total;
    }

    pub fn addPgConn(self: *Pipeline, fd: posix.socket_t) !void {
        if (self.pg_conn_count >= MAX_PG_CONNS) return error.TooManyPgConns;
        const idx = self.pg_conn_count;
        self.pg_conns[idx] = .{};
        self.pg_conns[idx].fd = fd;
        self.pg_conns[idx].send_task = Task.init(Pipeline, self, dummyStep);
        self.pg_conns[idx].send_task.tag = .pg_send;
        self.pg_conns[idx].recv_task = Task.init(Pipeline, self, dummyStep);
        self.pg_conns[idx].recv_task.tag = .pg_recv;
        try self.pg_conns[idx].ensureTransportBuffer(&self.pg_transport_pool);
        self.pg_conn_count += 1;
        log.info("postgres pool: connection {d} fd={d}", .{ idx, fd });
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

    pub fn pushSendTask(self: *Pipeline, task: SendTask) !void {
        try self.send_q.push(task);
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
    try q.push(.{ .conn = 1, .header_end = 100, .content_length = 0 });
    try q.push(.{ .conn = 5, .header_end = 200, .content_length = 42 });
    try std.testing.expectEqual(@as(usize, 2), q.len);
    try std.testing.expectEqual(@as(u16, 1), q.slice()[0].conn);
}
