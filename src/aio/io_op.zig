//! IoOp — what we ask the kernel to do.

const std = @import("std");

pub const IoOp = union(enum) {
    accept: struct {
        socket: std.posix.socket_t,
    },
    connect: struct {
        socket: std.posix.socket_t,
        addr: std.net.Address,
    },
    recv: struct {
        socket: std.posix.socket_t,
        buffer: []u8,
    },
    send: struct {
        socket: std.posix.socket_t,
        buffer: []const u8,
    },
    close: std.posix.socket_t,
    timer: struct {
        seconds: u63,
        nanos: u32,
    },
};

/// Raw kernel result. Positive = success value (bytes, fd). Negative = errno.
pub const IoResult = i32;
