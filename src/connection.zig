//! HTTP connection context + step functions.
//!
//! ConnCtx is plain state — fd, pool indices, ZeroCopy recv buffer.
//! Step functions are free functions that operate on ConnCtx via the generic Task.

const std = @import("std");
const IoOp = @import("aio/io_op.zig").IoOp;
const IoResult = @import("aio/io_op.zig").IoResult;
const Task = @import("task.zig").Task;
const http1 = @import("net/http1.zig");
const handler_mod = @import("handler.zig");
const Pool = @import("pool.zig").Pool;
const ZeroCopy = @import("zero_copy.zig").ZeroCopy;
const RedisCtx = @import("redis/async.zig").RedisCtx;

const log = std.log.scoped(.@"snek/connection");

pub const ConnCtx = struct {
    fd: std.posix.socket_t = undefined,
    pool_index: usize = 0,
    task_index: usize = 0,
    connections: *Pool(ConnCtx) = undefined,
    tasks: *Pool(Task) = undefined,
    initialized: bool = false,
    // HTTP recv — heap-allocated via ZeroCopy
    zc: ZeroCopy(u8) = undefined,
    recv_slice: []u8 = &.{},
    // HTTP response
    resp_buf: [8192]u8 = undefined,
    resp_len: usize = 0,
    // Request parsing
    content_length: usize = 0,
    body_received: usize = 0,

    pub fn ensureInit(self: *ConnCtx, allocator: std.mem.Allocator) !void {
        if (!self.initialized) {
            self.zc = try ZeroCopy(u8).init(allocator, 4096);
            self.initialized = true;
        }
    }

    pub fn reset(self: *ConnCtx) void {
        self.zc.clear_retaining_capacity();
        self.resp_len = 0;
        self.content_length = 0;
        self.body_received = 0;
        self.recv_slice = self.zc.get_write_area(4096) catch &.{};
    }
};

// ── Step functions ──────────────────────────────────────────────────

pub fn onRecv(conn: *ConnCtx, task: *Task, res: IoResult) ?IoOp {
    if (res <= 0) {
        if (res == 0) {
            log.debug("client disconnected", .{});
        } else {
            log.debug("recv error: {d}", .{res});
        }
        return close(conn);
    }
    const n: usize = @intCast(res);
    conn.zc.mark_written(n);
    log.debug("recv {d} bytes (total {d})", .{ n, conn.zc.as_slice().len });

    const data = conn.zc.as_slice();
    const search_start = if (data.len > n + 4) data.len - n - 4 else 0;
    const header_end = std.mem.indexOf(u8, data[search_start..], "\r\n\r\n") orelse {
        log.debug("headers incomplete", .{});
        conn.recv_slice = conn.zc.get_write_area(4096) catch return close(conn);
        return IoOp{ .recv = .{ .socket = conn.fd, .buffer = conn.recv_slice } };
    };
    const real_end = search_start + header_end + 4;

    const req = http1.Request.parse(data[0..real_end]) catch {
        log.debug("parse error", .{});
        return sendError(conn, task, 400);
    };

    conn.content_length = req.content_length orelse 0;
    if (conn.content_length > 0) {
        conn.body_received = data.len - real_end;
        if (conn.body_received < conn.content_length) {
            log.debug("body incomplete {d}/{d}", .{ conn.body_received, conn.content_length });
            task.setStep(ConnCtx, onRecvBody);
            conn.recv_slice = conn.zc.get_write_area(conn.content_length - conn.body_received) catch return close(conn);
            return IoOp{ .recv = .{ .socket = conn.fd, .buffer = conn.recv_slice } };
        }
    }

    return processAndSend(conn, task, req);
}

fn onRecvBody(conn: *ConnCtx, task: *Task, res: IoResult) ?IoOp {
    if (res <= 0) return close(conn);
    const n: usize = @intCast(res);

    conn.zc.mark_written(n);
    conn.body_received += n;
    log.debug("body recv {d}/{d}", .{ conn.body_received, conn.content_length });

    if (conn.body_received < conn.content_length) {
        conn.recv_slice = conn.zc.get_write_area(conn.content_length - conn.body_received) catch return close(conn);
        return IoOp{ .recv = .{ .socket = conn.fd, .buffer = conn.recv_slice } };
    }

    const data = conn.zc.as_slice();
    const header_end = (std.mem.indexOf(u8, data, "\r\n\r\n") orelse return sendError(conn, task, 400)) + 4;
    const req = http1.Request.parse(data[0..header_end]) catch return sendError(conn, task, 400);
    var req_with_body = req;
    req_with_body.body = data[header_end..];

    return processAndSend(conn, task, req_with_body);
}

fn processAndSend(conn: *ConnCtx, task: *Task, req: http1.Request) ?IoOp {
    const server = @import("server.zig");
    const req_ctx = server.getRequestContext() orelse {
        log.warn("no request context", .{});
        return sendError(conn, task, 503);
    };

    log.debug("processAndSend", .{});
    const result = handler_mod.handleRequest(&req, req_ctx, &conn.resp_buf);

    switch (result) {
        .response => |bytes| {
            conn.resp_len = bytes.len;
            task.setStep(ConnCtx, onSend);
            return IoOp{ .send = .{ .socket = conn.fd, .buffer = conn.resp_buf[0..conn.resp_len] } };
        },
        .redis_yield => |ry| {
            const reader = server.getRedisReader() orelse {
                log.warn("no redis reader", .{});
                return sendError(conn, task, 503);
            };
            const rctx_pool = server.getRedisCtxPool() orelse {
                log.warn("no redis ctx pool", .{});
                return sendError(conn, task, 503);
            };
            const rctx_idx = rctx_pool.borrow() catch {
                log.warn("redis ctx pool exhausted", .{});
                return sendError(conn, task, 503);
            };
            const rctx = rctx_pool.get_ptr(rctx_idx);
            rctx.* = .{
                .py_coro = ry.py_coro,
                .conn = conn,
                .pool_index = rctx_idx,
                .pool = rctx_pool,
            };

            // Swap task ctx to RedisCtx, park on reader
            task.ctx = rctx;
            reader.enqueue(task, ry.cmd_data);
            log.debug("parked on redis reader, cmd_len={d}", .{ry.cmd_data.len});
            return null;
        },
    }
}

fn sendError(conn: *ConnCtx, task: *Task, status: u16) ?IoOp {
    log.debug("sending error {d}", .{status});
    const err_resp = switch (status) {
        400 => "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        413 => "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        431 => "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        503 => "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        else => "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    };
    @memcpy(conn.resp_buf[0..err_resp.len], err_resp);
    conn.resp_len = err_resp.len;
    task.setStep(ConnCtx, onSend);
    return IoOp{ .send = .{ .socket = conn.fd, .buffer = conn.resp_buf[0..conn.resp_len] } };
}

pub fn onSend(conn: *ConnCtx, task: *Task, res: IoResult) ?IoOp {
    if (res < 0) {
        log.debug("send error: {d}", .{res});
        return close(conn);
    }
    log.debug("response sent, keepalive", .{});
    conn.reset();
    task.setStep(ConnCtx, onRecv);
    return IoOp{ .recv = .{ .socket = conn.fd, .buffer = conn.recv_slice } };
}

fn close(conn: *ConnCtx) ?IoOp {
    log.debug("closing connection", .{});
    std.posix.close(conn.fd);
    conn.connections.release(conn.pool_index);
    conn.tasks.release(conn.task_index);
    return null;
}
