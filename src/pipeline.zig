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
    py_coro: usize,
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
        const completions = try self.backend.submitAndWait(wait_nr);
        if (completions.tasks.len == 0) return false;

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
            } else {
                self.onConnCompletion(task, result);
            }
        }

        // DAG
        self.stageParse();
        self.stageHandle();
        self.stageSerializeAndSend();
        self.stageClose();

        return true;
    }

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
            const req = http1.Request.parse(data[0..header_end]) catch {
                self.send_q.push(makeErrorSend(pt.conn, 400));
                continue;
            };

            const content_length = req.content_length orelse 0;
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

    // ── Stage: Handle ─────────────────────────────────────────────

    fn stageHandle(self: *Pipeline) void {
        const req_ctx = self.req_ctx orelse return;

        for (self.handle_q.slice()) |ht| {
            const conn = self.conns.get_ptr(ht.conn);
            const data = conn.zc.as_slice();

            const req = http1.Request.parse(data[0..ht.header_end]) catch {
                self.send_q.push(makeErrorSend(ht.conn, 400));
                continue;
            };

            const raw = handler_mod.handleRequestRaw(&req, req_ctx, &conn.body_buf);
            switch (raw) {
                .response => |resp| {
                    self.send_q.push(makeResponseSend(ht.conn, resp));
                },
                .redis_yield => {
                    // TODO: wire redis pipeline
                    self.send_q.push(makeErrorSend(ht.conn, 503));
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

test "Queue typed" {
    var q: Queue(HandleTask) = .{};
    q.push(.{ .conn = 1, .header_end = 100, .content_length = 0 });
    q.push(.{ .conn = 5, .header_end = 200, .content_length = 42 });
    try std.testing.expectEqual(@as(usize, 2), q.len);
    try std.testing.expectEqual(@as(u16, 1), q.slice()[0].conn);
}
