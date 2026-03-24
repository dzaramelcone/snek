//! HTTP connection state machine with ZeroCopy recv buffer.
//!
//! Each connection borrows a Provision from the pool. The provision has a
//! ZeroCopy buffer that recv writes into directly. The parser slices into it.
//! On disconnect, the provision is returned — buffer stays allocated for reuse.

const std = @import("std");
const io = @import("io.zig");
const Socket = @import("socket.zig").Socket;
const http1 = @import("net/http1.zig");
const router_mod = @import("http/router.zig");
const response_mod = @import("http/response.zig");
const driver = @import("python/driver.zig");
const tardy = @import("vendor/tardy/lib.zig");
const ZeroCopy = tardy.ZeroCopy;
const Pool = tardy.Pool;

const State = enum { recv_headers, recv_body, process, send };

pub const Provision = struct {
    initialized: bool = false,
    zc: ZeroCopy(u8) = undefined,
    state: State = .recv_headers,
    fd: std.posix.socket_t = undefined,
    task_id: io.TaskId = 0,
    pool_index: usize = 0,
    rt: io.Runtime = undefined,
    provisions: *Pool(Provision) = undefined,
    recv_slice: []u8 = &.{},
    resp_buf: [8192]u8 = undefined,
    resp_len: usize = 0,
    content_length: usize = 0,
    body_received: usize = 0,

    pub fn ensureInit(self: *Provision, allocator: std.mem.Allocator) !void {
        if (!self.initialized) {
            self.zc = try ZeroCopy(u8).init(allocator, 4096);
            self.initialized = true;
        }
    }

    pub fn reset(self: *Provision) !void {
        self.zc.clear_retaining_capacity();
        self.state = .recv_headers;
        self.content_length = 0;
        self.body_received = 0;
        self.resp_len = 0;
        self.recv_slice = try self.zc.get_write_area(4096);
    }

    pub fn step(ctx: *anyopaque, id: io.TaskId, result: io.Result) ?io.AsyncSubmission {
        const self: *Provision = @ptrCast(@alignCast(ctx));
        self.task_id = id;
        return switch (self.state) {
            .recv_headers => self.onRecvHeaders(result),
            .recv_body => self.onRecvBody(result),
            .process => null, // shouldn't happen — process is synchronous
            .send => self.onSend(),
        };
    }

    fn onRecvHeaders(self: *Provision, result: io.Result) ?io.AsyncSubmission {
        const n = result.recv.unwrap() catch return self.close();
        if (n == 0) return self.close();

        self.zc.mark_written(n);

        // Scan for end of headers
        const data = self.zc.as_slice();
        const search_start = if (data.len > n + 4) data.len - n - 4 else 0;
        const header_end = std.mem.indexOf(u8, data[search_start..], "\r\n\r\n") orelse {
            // Need more data
            self.recv_slice = self.zc.get_write_area(4096) catch return self.close();
            return (Socket{ .handle = self.fd, .addr = undefined }).recvSubmission(self.recv_slice);
        };
        const real_end = search_start + header_end + 4;

        // Parse headers from the ZeroCopy buffer — slices point into it
        const req = http1.Request.parse(data[0..real_end]) catch return self.sendError(400);

        // Check for body
        self.content_length = req.content_length orelse 0;
        if (self.content_length > 0) {
            self.body_received = data.len - real_end;
            if (self.body_received < self.content_length) {
                self.state = .recv_body;
                self.recv_slice = self.zc.get_write_area(self.content_length - self.body_received) catch return self.close();
                return (Socket{ .handle = self.fd, .addr = undefined }).recvSubmission(self.recv_slice);
            }
        }

        return self.processAndSend(req);
    }

    fn onRecvBody(self: *Provision, result: io.Result) ?io.AsyncSubmission {
        const n = result.recv.unwrap() catch return self.close();
        if (n == 0) return self.close();

        self.zc.mark_written(n);
        self.body_received += n;

        if (self.body_received < self.content_length) {
            self.recv_slice = self.zc.get_write_area(self.content_length - self.body_received) catch return self.close();
            return (Socket{ .handle = self.fd, .addr = undefined }).recvSubmission(self.recv_slice);
        }

        // Re-parse now that we have the full body
        const data = self.zc.as_slice();
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n").? + 4;
        const req = http1.Request.parse(data[0..header_end]) catch return self.sendError(400);
        // Attach body
        var req_with_body = req;
        req_with_body.body = data[header_end..];

        return self.processAndSend(req_with_body);
    }

    fn processAndSend(self: *Provision, req: http1.Request) ?io.AsyncSubmission {
        _ = req; // TODO: route + invoke python handler

        const body = "{\"status\": \"ok\"}";
        var resp = response_mod.Response.json(body);
        _ = resp.setHeader("Connection", "close");
        self.resp_len = resp.serialize(&self.resp_buf) catch return self.sendError(500);

        self.state = .send;
        return (Socket{ .handle = self.fd, .addr = undefined }).sendSubmission(self.resp_buf[0..self.resp_len]);
    }

    fn sendError(self: *Provision, status: u16) ?io.AsyncSubmission {
        const err_resp = switch (status) {
            400 => "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            else => "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        };
        @memcpy(self.resp_buf[0..err_resp.len], err_resp);
        self.resp_len = err_resp.len;
        self.state = .send;
        return (Socket{ .handle = self.fd, .addr = undefined }).sendSubmission(self.resp_buf[0..self.resp_len]);
    }

    fn onSend(self: *Provision) ?io.AsyncSubmission {
        return self.close();
    }

    fn close(self: *Provision) ?io.AsyncSubmission {
        std.posix.close(self.fd);
        self.rt.release(self.task_id);
        self.provisions.release(self.pool_index);
        return null;
    }
};
