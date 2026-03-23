//! HTTP connection state machine.
//!
//! Each state transition is one I/O completion → step → return next submission.

const std = @import("std");
const io = @import("io.zig");
const Socket = @import("socket.zig").Socket;
const http1 = @import("net/http1.zig");
const router_mod = @import("http/router.zig");
const response_mod = @import("http/response.zig");
const driver = @import("python/driver.zig");
const subinterp = @import("python/subinterp.zig");

const State = enum { recv, send };

pub const Connection = struct {
    state: State = .recv,
    fd: std.posix.socket_t,
    read_buf: [4096]u8 = undefined,
    resp_buf: [8192]u8 = undefined,
    resp_len: usize = 0,

    pub fn step(ctx: *anyopaque, id: io.TaskId, result: io.Result) ?io.AsyncSubmission {
        const self: *Connection = @ptrCast(@alignCast(ctx));
        return switch (self.state) {
            .recv => self.onRecv(id, result),
            .send => self.onSend(id),
        };
    }

    fn onRecv(self: *Connection, id: io.TaskId, result: io.Result) ?io.AsyncSubmission {
        _ = id;
        const n = result.recv.unwrap() catch return self.close();
        if (n == 0) return self.close();

        const resp = processRequest(self.read_buf[0..n], &self.resp_buf) catch
            "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        self.resp_len = resp.len;
        // If processRequest returned a static string, copy it into resp_buf
        if (resp.ptr != &self.resp_buf) {
            @memcpy(self.resp_buf[0..resp.len], resp);
        }

        self.state = .send;
        return (Socket{ .handle = self.fd, .addr = undefined }).sendSubmission(self.resp_buf[0..self.resp_len]);
    }

    fn onSend(self: *Connection, id: io.TaskId) ?io.AsyncSubmission {
        _ = id;
        return self.close();
    }

    fn close(self: *Connection) ?io.AsyncSubmission {
        std.posix.close(self.fd);
        return null;
    }

    pub fn recvSubmission(self: *Connection) io.AsyncSubmission {
        return (Socket{ .handle = self.fd, .addr = undefined }).recvSubmission(&self.read_buf);
    }
};

fn processRequest(raw: []const u8, resp_buf: []u8) ![]const u8 {
    const req = try http1.Request.parse(raw);

    const method_str = if (req.method) |m| @tagName(m) else "GET";
    const method = router_mod.Method.fromString(method_str) orelse .GET;
    const path = req.uri orelse "/";

    // TODO: wire to router + python handlers
    _ = method;
    _ = path;

    const body = "{\"status\": \"ok\"}";
    var resp = response_mod.Response.json(body);
    _ = resp.setHeader("Connection", "close");
    return resp_buf[0..try resp.serialize(resp_buf)];
}
