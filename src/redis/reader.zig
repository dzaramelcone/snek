//! Pipelined Redis reader — one fd per thread, shared send buffer.
//!
//! Connections append RESP commands to the send buffer and park their Task
//! on an intrusive linked list. The reader sends batched commands, recvs
//! responses, parses RESP, resumes connections in FIFO order.
//!
//! Send: zero-copy from Python bytes memory (RESP-encoded by Python).
//! Recv: RESP frame header into scratch, bulk payload into PyBytes.

const std = @import("std");
const IoOp = @import("../aio/io_op.zig").IoOp;
const IoResult = @import("../aio/io_op.zig").IoResult;
const Task = @import("../task.zig").Task;
const Runtime = @import("../runtime.zig").Runtime;
const ZeroCopy = @import("../zero_copy.zig").ZeroCopy;
const ffi = @import("../python/ffi.zig");
const c = ffi.c;
const conn_mod = @import("../connection.zig");
const RedisCtx = @import("async.zig").RedisCtx;
const driver = @import("../python/driver.zig");
const response_mod = @import("../http/response.zig");
const subinterp = @import("../python/subinterp.zig");

const log = std.log.scoped(.@"snek/redis/reader");

pub const RedisReader = struct {
    fd: std.posix.socket_t,
    rt: *Runtime,
    py_ctx: *subinterp.WorkerPyContext,
    // Send buffer — connections append RESP here
    send_buf: ZeroCopy(u8),
    // Intrusive waiter queue (FIFO via Task.next)
    head: ?*Task = null,
    tail: ?*Task = null,
    waiter_count: usize = 0,
    // Reader task (owns the redis fd)
    task: Task = undefined,
    // Recv state
    recv_buf: [4096]u8 = undefined,
    recv_len: usize = 0,
    // RESP parse state — offset into recv_buf for current parse position
    parse_pos: usize = 0,
    // Whether the reader task is currently active (has a pending IoOp)
    active: bool = false,
    // How many bytes of send_buf were in the current batch (already sent to redis)
    batch_sent: usize = 0,
    // How many waiters are in the current batch (expecting responses)
    batch_waiters: usize = 0,

    pub fn connectTcp(host: []const u8, port: u16) !std.posix.socket_t {
        // Try IP first, fall back to DNS
        const addr = std.net.Address.resolveIp(host, port) catch blk: {
            const list = try std.net.getAddressList(std.heap.page_allocator, host, port);
            defer list.deinit();
            if (list.addrs.len == 0) return error.NameResolutionFailed;
            break :blk list.addrs[0];
        };
        const fd = try std.posix.socket(addr.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.TCP);
        errdefer std.posix.close(fd);
        std.posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => {}, // non-blocking connect in progress
            else => return err,
        };
        return fd;
    }

    pub fn init(allocator: std.mem.Allocator, fd: std.posix.socket_t, rt: *Runtime, py_ctx: *subinterp.WorkerPyContext) !RedisReader {
        return .{
            .fd = fd,
            .rt = rt,
            .py_ctx = py_ctx,
            .send_buf = try ZeroCopy(u8).init(allocator, 4096),
        };
        // NOTE: caller must call initTask() after struct is at final location
    }

    /// Must be called after the struct is at its final memory location
    /// (after assignment, NOT inside init which returns by value).
    pub fn initTask(self: *RedisReader) void {
        self.task = Task.init(RedisReader, self, onSendComplete);
    }

    /// Called by connections to enqueue a redis command.
    /// Appends RESP bytes to send buffer, parks the task on the waiter list.
    pub fn enqueue(self: *RedisReader, task: *Task, cmd_data: []const u8) void {
        // Append RESP command to send buffer
        const write_area = self.send_buf.get_write_area(cmd_data.len) catch return;
        @memcpy(write_area[0..cmd_data.len], cmd_data);
        self.send_buf.mark_written(cmd_data.len);

        // Append task to intrusive waiter list
        task.next = null;
        if (self.tail) |t| {
            t.next = task;
        } else {
            self.head = task;
        }
        self.tail = task;
        self.waiter_count += 1;

        log.debug("enqueued cmd ({d} bytes), {d} waiters", .{ cmd_data.len, self.waiter_count });

        // If the reader is idle, kick a send with current buffer contents
        if (!self.active) {
            self.active = true;
            self.batch_sent = self.send_buf.as_slice().len;
            self.batch_waiters = self.waiter_count;
            self.task.setStep(RedisReader, onSendComplete);
            self.rt.queue(&self.task, IoOp{ .send = .{
                .socket = self.fd,
                .buffer = self.send_buf.as_slice(),
            } }) catch {};
        }
    }

    // ── Step functions ──────────────────────────────────────────────

    fn onSendComplete(self: *RedisReader, task: *Task, res: IoResult) ?IoOp {
        if (res <= 0) {
            log.debug("redis send error: {d}", .{res});
            self.failAllWaiters();
            return null;
        }

        log.debug("redis sent {d} bytes, batch_waiters={d}", .{ res, self.batch_waiters });

        // Start receiving responses for this batch
        self.recv_len = 0;
        self.parse_pos = 0;
        task.setStep(RedisReader, onRecv);
        return IoOp{ .recv = .{ .socket = self.fd, .buffer = &self.recv_buf } };
    }

    fn onRecv(self: *RedisReader, task: *Task, res: IoResult) ?IoOp {
        if (res <= 0) {
            log.debug("redis recv error: {d}", .{res});
            self.failAllWaiters();
            return null;
        }
        self.recv_len += @intCast(res);
        log.debug("redis recv {d} bytes (total {d}), batch_waiters={d}", .{ res, self.recv_len, self.batch_waiters });

        // Parse responses for the current batch
        self.py_ctx.acquireGil();
        while (self.batch_waiters > 0 and self.head != null) {
            const parsed = self.parseAndResumeOne() catch break;
            if (!parsed) break;
            self.batch_waiters -= 1;
        }
        self.py_ctx.releaseGil();

        if (self.batch_waiters == 0) {
            // Current batch fully served — compact send_buf (remove sent bytes)
            self.compactSendBuf();

            // Check if new commands arrived while we were in this cycle
            const pending = self.send_buf.as_slice();
            if (pending.len > 0 and self.waiter_count > 0) {
                // New batch — send the remaining commands
                self.batch_sent = pending.len;
                self.batch_waiters = self.waiter_count;
                log.debug("new batch: {d} bytes, {d} waiters", .{ pending.len, self.waiter_count });
                task.setStep(RedisReader, onSendComplete);
                return IoOp{ .send = .{ .socket = self.fd, .buffer = pending } };
            }

            self.active = false;
            return null; // idle
        }

        // More responses expected for this batch — keep receiving
        self.compactRecvBuf();
        return IoOp{ .recv = .{ .socket = self.fd, .buffer = self.recv_buf[self.recv_len..] } };
    }

    fn compactRecvBuf(self: *RedisReader) void {
        if (self.parse_pos > 0) {
            const remaining = self.recv_len - self.parse_pos;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.recv_buf[0..remaining], self.recv_buf[self.parse_pos..self.recv_len]);
            }
            self.recv_len = remaining;
            self.parse_pos = 0;
        }
    }

    fn compactSendBuf(self: *RedisReader) void {
        if (self.batch_sent == 0) return;
        const total = self.send_buf.as_slice().len;
        if (self.batch_sent >= total) {
            self.send_buf.clear_retaining_capacity();
        } else {
            // New commands were appended after the batch — keep them
            const remaining = total - self.batch_sent;
            const slice = self.send_buf.as_slice();
            std.mem.copyForwards(u8, self.send_buf.ptr[0..remaining], slice[self.batch_sent..]);
            self.send_buf.len = remaining;
        }
        self.batch_sent = 0;
    }

    // ── RESP parsing + coroutine resumption ─────────────────────────

    /// Parse one RESP response from recv_buf and resume the head waiter.
    /// Returns true if a response was parsed, false if incomplete.
    fn parseAndResumeOne(self: *RedisReader) !bool {
        const data = self.recv_buf[self.parse_pos..self.recv_len];
        if (data.len == 0) return false;

        const crlf_pos = std.mem.indexOf(u8, data, "\r\n") orelse return false;
        const type_byte = data[0];
        const line = data[1..crlf_pos];

        const result: *ffi.PyObject = switch (type_byte) {
            '+' => blk: {
                self.parse_pos += crlf_pos + 2;
                var sentinel_buf: [256]u8 = undefined;
                if (line.len >= sentinel_buf.len) return error.FrameTooLarge;
                @memcpy(sentinel_buf[0..line.len], line);
                sentinel_buf[line.len] = 0;
                break :blk ffi.unicodeFromString(sentinel_buf[0..line.len :0]) catch return error.PythonError;
            },
            '-' => {
                self.parse_pos += crlf_pos + 2;
                var err_buf: [256]u8 = undefined;
                if (line.len >= err_buf.len) return error.FrameTooLarge;
                @memcpy(err_buf[0..line.len], line);
                err_buf[line.len] = 0;
                c.PyErr_SetString(c.PyExc_RuntimeError, err_buf[0..line.len :0]);
                // Resume with error — coroutine will see the exception
                self.resumeHeadWithError();
                return true;
            },
            ':' => blk: {
                self.parse_pos += crlf_pos + 2;
                const val = std.fmt.parseInt(i64, line, 10) catch return error.InvalidInteger;
                break :blk ffi.longFromLong(val) catch return error.PythonError;
            },
            '_' => blk: {
                self.parse_pos += crlf_pos + 2;
                break :blk ffi.getNone();
            },
            '$' => blk: {
                const len_val = std.fmt.parseInt(i64, line, 10) catch return error.InvalidLength;
                if (len_val < 0) {
                    self.parse_pos += crlf_pos + 2;
                    break :blk ffi.getNone();
                }
                const payload_len: usize = @intCast(len_val);
                const payload_start = crlf_pos + 2;
                const total_needed = payload_start + payload_len + 2; // +2 for trailing \r\n
                if (data.len < total_needed) return false; // incomplete

                // Allocate PyBytes, copy payload directly
                const py_bytes = c.PyBytes_FromStringAndSize(null, @intCast(payload_len)) orelse
                    return error.PythonError;
                const dest: [*]u8 = @ptrCast(c.PyBytes_AS_STRING(py_bytes));
                @memcpy(dest[0..payload_len], data[payload_start..][0..payload_len]);

                self.parse_pos += total_needed;
                break :blk py_bytes;
            },
            else => return error.UnknownRespType,
        };

        self.resumeHead(result);
        return true;
    }

    /// Pop head waiter, resume its Python coroutine with the result.
    /// GIL must be held.
    fn resumeHead(self: *RedisReader, result: *ffi.PyObject) void {
        const waiter = self.popHead() orelse return;
        const rctx: *RedisCtx = waiter.getCtx(RedisCtx);
        const conn = rctx.conn;
        const py_coro = rctx.py_coro;

        const send = ffi.iterSend(py_coro, result);
        switch (send.status) {
            .next => {
                const sentinel = send.result.?;
                defer ffi.decref(sentinel);
                if (driver.checkRedisSentinel(sentinel)) |cmd_info| {
                    // Re-enqueue: build RESP in send buffer from args
                    var resp_buf: [512]u8 = undefined;
                    const resp_len = writeRespLegacy(&resp_buf, cmd_info.args[0..cmd_info.arg_count]);
                    if (resp_len > 0) {
                        self.enqueue(waiter, resp_buf[0..resp_len]);
                        return;
                    }
                }
                self.resumeWithError(rctx, waiter);
            },
            .@"return" => {
                const py_result = send.result orelse ffi.getNone();
                defer ffi.decref(py_result);

                var py_body_buf: [4096]u8 = undefined;
                const resp = driver.convertPythonResponse(py_result, &py_body_buf) catch
                    response_mod.Response.init(500);
                var resp_mut = resp;
                conn.resp_len = resp_mut.serialize(&conn.resp_buf) catch blk: {
                    const err = "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    @memcpy(conn.resp_buf[0..err.len], err);
                    break :blk err.len;
                };

                ffi.decref(py_coro);
                rctx.release();
                waiter.setCtxAndStep(conn_mod.ConnCtx, conn, conn_mod.onSend);
                self.rt.queue(waiter, IoOp{ .send = .{
                    .socket = conn.fd,
                    .buffer = conn.resp_buf[0..conn.resp_len],
                } }) catch {};
            },
            .@"error" => {
                if (ffi.errOccurred()) ffi.errPrint();
                self.resumeWithError(rctx, waiter);
            },
        }
    }

    fn resumeHeadWithError(self: *RedisReader) void {
        const waiter = self.popHead() orelse return;
        const rctx: *RedisCtx = waiter.getCtx(RedisCtx);
        self.resumeWithError(rctx, waiter);
    }

    fn resumeWithError(self: *RedisReader, rctx: *RedisCtx, waiter: *Task) void {
        const conn = rctx.conn;
        ffi.decref(rctx.py_coro);
        rctx.release();

        const err = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        @memcpy(conn.resp_buf[0..err.len], err);
        conn.resp_len = err.len;
        waiter.setCtxAndStep(conn_mod.ConnCtx, conn, conn_mod.onSend);
        self.rt.queue(waiter, IoOp{ .send = .{
            .socket = conn.fd,
            .buffer = conn.resp_buf[0..conn.resp_len],
        } }) catch {};
    }

    fn failAllWaiters(self: *RedisReader) void {
        while (self.head) |waiter| {
            self.head = waiter.next;
            waiter.next = null;
            self.waiter_count -= 1;
            const rctx: *RedisCtx = waiter.getCtx(RedisCtx);
            self.resumeWithError(rctx, waiter);
        }
        self.tail = null;
    }

    fn popHead(self: *RedisReader) ?*Task {
        const h = self.head orelse return null;
        self.head = h.next;
        if (self.head == null) self.tail = null;
        h.next = null;
        self.waiter_count -= 1;
        return h;
    }
};

/// Build RESP protocol into a buffer from command args (legacy path).
fn writeRespLegacy(buf: []u8, args: []const []const u8) usize {
    var pos: usize = 0;
    if (pos >= buf.len) return 0;
    buf[pos] = '*';
    pos += 1;
    const n_str = std.fmt.bufPrint(buf[pos..], "{d}\r\n", .{args.len}) catch return 0;
    pos += n_str.len;
    for (args) |arg| {
        if (pos >= buf.len) return 0;
        buf[pos] = '$';
        pos += 1;
        const l_str = std.fmt.bufPrint(buf[pos..], "{d}\r\n", .{arg.len}) catch return 0;
        pos += l_str.len;
        if (pos + arg.len + 2 > buf.len) return 0;
        @memcpy(buf[pos..][0..arg.len], arg);
        pos += arg.len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
    }
    return pos;
}
