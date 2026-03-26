//! Simple Redis connection pool — array of pre-connected fds.
//!
//! Per-thread, no locking needed. Borrow/return by index.
//! Connects eagerly at init time.

const std = @import("std");

const log = std.log.scoped(.@"snek/redis/pool");

pub const RedisPool = struct {
    fds: [MAX_CONNS]std.posix.socket_t,
    in_use: [MAX_CONNS]bool,
    count: usize,

    const MAX_CONNS: usize = 16;

    pub fn init(host: []const u8, port: u16, count: usize) !RedisPool {
        var pool = RedisPool{
            .fds = .{-1} ** MAX_CONNS,
            .in_use = .{false} ** MAX_CONNS,
            .count = @min(count, MAX_CONNS),
        };
        for (0..pool.count) |i| {
            pool.fds[i] = try connectTcp(host, port);
            log.debug("connected redis fd={d} slot={d}", .{ pool.fds[i], i });
        }
        return pool;
    }

    pub fn deinit(self: *RedisPool) void {
        for (0..self.count) |i| {
            if (self.fds[i] >= 0) std.posix.close(self.fds[i]);
        }
    }

    pub fn borrow(self: *RedisPool) !struct { fd: std.posix.socket_t, index: usize } {
        for (0..self.count) |i| {
            if (!self.in_use[i]) {
                self.in_use[i] = true;
                return .{ .fd = self.fds[i], .index = i };
            }
        }
        return error.PoolExhausted;
    }

    pub fn release(self: *RedisPool, index: usize) void {
        self.in_use[index] = false;
    }

    fn connectTcp(host: []const u8, port: u16) !std.posix.socket_t {
        const addr = try std.net.Address.resolveIp(host, port);
        const fd = try std.posix.socket(addr.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        errdefer std.posix.close(fd);
        try std.posix.connect(fd, &addr.any, addr.getOsSockLen());
        return fd;
    }
};
