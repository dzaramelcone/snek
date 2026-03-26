//! AIO — async I/O via comptime backend selection.

const builtin = @import("builtin");

pub const IoOp = @import("io_op.zig").IoOp;
pub const IoResult = @import("io_op.zig").IoResult;
pub const IoUring = @import("io_uring.zig").IoUring;
pub const Kqueue = @import("kqueue.zig").Kqueue;

pub const Backend = switch (builtin.os.tag) {
    .linux => IoUring,
    .macos, .ios, .freebsd, .openbsd, .netbsd, .dragonfly => Kqueue,
    else => @compileError("unsupported platform"),
};
