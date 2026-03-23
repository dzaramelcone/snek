//! Stackless socket: a thin wrapper around an fd that produces AsyncSubmissions.
//!
//! Unlike tardy's Socket which calls rt.scheduler.io_await() (stackful),
//! this just returns the submission for the caller to queue with the runtime.

const std = @import("std");
const posix = std.posix;
const io = @import("io.zig");
const AsyncSubmission = io.AsyncSubmission;

pub const Socket = struct {
    handle: posix.socket_t,
    addr: std.net.Address,

    pub const Kind = enum { tcp, udp, unix };

    pub fn initTcp(host: []const u8, port: u16) !Socket {
        const addr = try std.net.Address.parseIp4(host, port);
        const flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
        const handle = try posix.socket(addr.any.family, flags, posix.IPPROTO.TCP);
        try posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        return .{ .handle = handle, .addr = addr };
    }

    pub fn bind(self: Socket) !void {
        try posix.bind(self.handle, &self.addr.any, self.addr.getOsSockLen());
    }

    pub fn listen(self: Socket, backlog: u31) !void {
        try posix.listen(self.handle, backlog);
    }

    pub fn close(self: Socket) void {
        posix.close(self.handle);
    }

    // -- Submission builders: return AsyncSubmissions for the runtime to queue --

    pub fn acceptSubmission(self: Socket) AsyncSubmission {
        return .{ .accept = .{ .socket = self.handle, .kind = .tcp } };
    }

    pub fn connectSubmission(self: Socket) AsyncSubmission {
        return .{ .connect = .{ .socket = self.handle, .addr = self.addr, .kind = .tcp } };
    }

    pub fn recvSubmission(self: Socket, buf: []u8) AsyncSubmission {
        return .{ .recv = .{ .socket = self.handle, .buffer = buf } };
    }

    pub fn sendSubmission(self: Socket, buf: []const u8) AsyncSubmission {
        return .{ .send = .{ .socket = self.handle, .buffer = buf } };
    }

    pub fn closeSubmission(self: Socket) AsyncSubmission {
        return .{ .close = self.handle };
    }
};
