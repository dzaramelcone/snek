//! io_uring backend — backend-owned pending slots with decoded CQE metadata.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const snek_log = @import("../log.zig");

const log = std.log.scoped(.@"snek/aio/io_uring");

pub const Op = union(enum) {
    accept: struct {
        socket: std.posix.socket_t,
    },
    accept_multishot: struct {
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
    recv_fixed: struct {
        socket: std.posix.socket_t,
        buffer_id: u16,
        len: u32,
        offset: u32 = 0,
    },
    recv_multishot: struct {
        socket: std.posix.socket_t,
        buffer_group: u16,
        flags: u32 = 0,
    },
    send: struct {
        socket: std.posix.socket_t,
        buffer: []const u8,
    },
    send_zc: struct {
        socket: std.posix.socket_t,
        buffer: []const u8,
        send_flags: u32 = 0,
        zc_flags: u16 = 0,
    },
    sendv: struct {
        socket: std.posix.socket_t,
        iovecs: []const std.posix.iovec_const,
    },
    close: std.posix.socket_t,
    timer: struct {
        seconds: u63,
        nanos: u32,
    },
};

const OpTag = std.meta.Tag(Op);

pub const Completion = struct {
    op_tag: OpTag,
    result: i32,
    flags: u32 = 0,
    buffer_id: ?u16 = null,
    more: bool = false,
    notification: bool = false,
    buffer_more: bool = false,
};

pub const IoUring = struct {
    const PendingKind = enum(u8) {
        oneshot,
        multishot,
        send_zc,
    };

    const PendingSlot = struct {
        in_use: bool = false,
        token: *anyopaque = undefined,
        op_tag: OpTag = undefined,
        kind: PendingKind = .oneshot,
    };

    ring: linux.IoUring,
    pending: []PendingSlot,
    free_stack: []u16,
    free_len: usize,
    tokens_buf: []*anyopaque,
    completion_buf: []Completion,
    fixed_buffers: []const posix.iovec = &.{},

    pub fn init(allocator: std.mem.Allocator, entries: u16) !IoUring {
        const flags: u32 = 0;
        const ring = try linux.IoUring.init(entries, flags);
        const pending = try allocator.alloc(PendingSlot, entries);
        for (pending) |*slot| slot.* = .{};
        const free_stack = try allocator.alloc(u16, entries);
        for (free_stack, 0..) |*slot, idx| {
            slot.* = @intCast(entries - idx - 1);
        }

        return .{
            .ring = ring,
            .pending = pending,
            .free_stack = free_stack,
            .free_len = entries,
            .tokens_buf = try allocator.alloc(*anyopaque, entries),
            .completion_buf = try allocator.alloc(Completion, entries),
        };
    }

    pub fn deinit(self: *IoUring, allocator: std.mem.Allocator) void {
        self.ring.deinit();
        allocator.free(self.pending);
        allocator.free(self.free_stack);
        allocator.free(self.tokens_buf);
        allocator.free(self.completion_buf);
    }

    pub fn queue(self: *IoUring, token: *anyopaque, op: Op) !void {
        log.debug("sqe: {s}", .{@tagName(op)});
        const slot_idx = try self.allocPending(token, std.meta.activeTag(op), pendingKindFor(op));
        errdefer self.releasePending(slot_idx);
        const udata: u64 = slot_idx + 1;
        switch (op) {
            .accept => |inner| {
                _ = try self.ring.accept(udata, inner.socket, null, null, 0);
            },
            .accept_multishot => |inner| {
                _ = try self.ring.accept_multishot(udata, inner.socket, null, null, 0);
            },
            .recv => |inner| {
                _ = try self.ring.recv(udata, inner.socket, .{ .buffer = inner.buffer }, 0);
            },
            .recv_multishot => |inner| {
                const sqe = try self.ring.recv(
                    udata,
                    inner.socket,
                    .{ .buffer_selection = .{ .group_id = inner.buffer_group, .len = 0 } },
                    inner.flags,
                );
                sqe.ioprio |= linux.IORING_RECV_MULTISHOT;
            },
            .send => |inner| {
                _ = try self.ring.send(udata, inner.socket, inner.buffer, 0);
            },
            .send_zc => |inner| {
                _ = try self.ring.send_zc(udata, inner.socket, inner.buffer, inner.send_flags, inner.zc_flags);
            },
            .sendv => |inner| {
                _ = try self.ring.writev(udata, inner.socket, inner.iovecs, 0);
            },
            .connect => |inner| {
                var addr = inner.addr;
                _ = try self.ring.connect(udata, inner.socket, &addr.any, addr.getOsSockLen());
            },
            .close => |fd| {
                _ = try self.ring.close(udata, fd);
            },
            .timer => |inner| {
                const ts: linux.kernel_timespec = .{ .sec = inner.seconds, .nsec = inner.nanos };
                _ = try self.ring.timeout(udata, &ts, 0, 0);
            },
            .recv_fixed => |inner| {
                var iov = try self.fixedIovec(inner.buffer_id, inner.len, inner.offset);
                _ = try self.ring.read_fixed(udata, inner.socket, &iov, 0, inner.buffer_id);
            },
        }
    }

    /// Submit + wait. Returns parallel slices of tasks and results.
    pub fn submitAndWait(self: *IoUring, wait_nr: u32) !struct { tokens: []*anyopaque, completions: []Completion } {
        snek_log.bumpLoop();

        const submitted = while (true) {
            break self.ring.submit_and_wait(wait_nr) catch |e| switch (e) {
                error.SignalInterrupt => continue,
                else => return e,
            };
        };

        var cqes: [256]linux.io_uring_cqe = undefined;
        const count = while (true) {
            break self.ring.copy_cqes(&cqes, 0) catch |e| switch (e) {
                error.SignalInterrupt => continue,
                else => return e,
            };
        };

        log.debug("io_uring_enter: submitted={d} reaped={d}", .{ submitted, count });

        for (cqes[0..count], 0..) |cqe, i| {
            std.debug.assert(cqe.user_data != 0);
            const slot_idx: usize = @intCast(cqe.user_data - 1);
            std.debug.assert(slot_idx < self.pending.len);
            const slot = &self.pending[slot_idx];
            const completion = decodeCompletion(slot.op_tag, cqe);
            self.tokens_buf[i] = slot.token;
            self.completion_buf[i] = completion;
            if (shouldReleasePending(slot.kind, completion)) self.releasePending(slot_idx);
        }

        return .{
            .tokens = self.tokens_buf[0..count],
            .completions = self.completion_buf[0..count],
        };
    }

    fn allocPending(self: *IoUring, token: *anyopaque, op_tag: OpTag, kind: PendingKind) !usize {
        if (self.free_len == 0) return error.Overflow;
        self.free_len -= 1;
        const idx = self.free_stack[self.free_len];
        self.pending[idx] = .{
            .in_use = true,
            .token = token,
            .op_tag = op_tag,
            .kind = kind,
        };
        return idx;
    }

    fn releasePending(self: *IoUring, idx: usize) void {
        std.debug.assert(idx < self.pending.len);
        std.debug.assert(self.pending[idx].in_use);
        self.pending[idx] = .{};
        self.free_stack[self.free_len] = @intCast(idx);
        self.free_len += 1;
    }

    fn pendingKindFor(op: Op) PendingKind {
        return switch (op) {
            .accept_multishot, .recv_multishot => .multishot,
            .send_zc => .send_zc,
            else => .oneshot,
        };
    }

    fn decodeCompletion(op_tag: OpTag, cqe: linux.io_uring_cqe) Completion {
        const flags = cqe.flags;
        return .{
            .op_tag = op_tag,
            .result = cqe.res,
            .flags = flags,
            .buffer_id = if (flags & linux.IORING_CQE_F_BUFFER != 0) cqe.buffer_id() catch null else null,
            .more = flags & linux.IORING_CQE_F_MORE != 0,
            .notification = flags & linux.IORING_CQE_F_NOTIF != 0,
            .buffer_more = flags & linux.IORING_CQE_F_BUF_MORE != 0,
        };
    }

    fn shouldReleasePending(kind: PendingKind, completion: Completion) bool {
        return switch (kind) {
            .oneshot => true,
            .multishot => !completion.more,
            .send_zc => completion.notification or !completion.more,
        };
    }

    fn fixedIovec(self: *IoUring, buffer_id: u16, len: u32, offset: u32) !posix.iovec {
        if (buffer_id >= self.fixed_buffers.len) return error.BufferInvalid;
        const registered = self.fixed_buffers[buffer_id];
        const start: usize = offset;
        const want: usize = len;
        if (start > registered.len) return error.BufferInvalid;
        if (want > registered.len - start) return error.BufferInvalid;
        return .{
            .base = registered.base + start,
            .len = want,
        };
    }

    pub fn registerFixedBuffers(self: *IoUring, buffers: []const posix.iovec) !void {
        if (buffers.len == 0) return;
        if (self.fixed_buffers.len != 0) return error.FixedBuffersAlreadyRegistered;
        try self.ring.register_buffers(buffers);
        self.fixed_buffers = buffers;
    }

    pub fn unregisterFixedBuffers(self: *IoUring) !void {
        if (self.fixed_buffers.len == 0) return;
        try self.ring.unregister_buffers();
        self.fixed_buffers = &.{};
    }
};

test "decodeCompletion extracts io_uring CQE metadata" {
    const cqe = linux.io_uring_cqe{
        .user_data = 1,
        .res = 128,
        .flags = linux.IORING_CQE_F_BUFFER |
            linux.IORING_CQE_F_MORE |
            linux.IORING_CQE_F_NOTIF |
            linux.IORING_CQE_F_BUF_MORE |
            (@as(u32, 7) << linux.IORING_CQE_BUFFER_SHIFT),
    };

    const completion = IoUring.decodeCompletion(.recv_multishot, cqe);
    try std.testing.expectEqual(OpTag.recv_multishot, completion.op_tag);
    try std.testing.expectEqual(@as(i32, 128), completion.result);
    try std.testing.expectEqual(@as(?u16, 7), completion.buffer_id);
    try std.testing.expect(completion.more);
    try std.testing.expect(completion.notification);
    try std.testing.expect(completion.buffer_more);
}

test "shouldReleasePending honors multishot and zerocopy send lifetimes" {
    try std.testing.expect(!IoUring.shouldReleasePending(.multishot, .{
        .op_tag = .recv_multishot,
        .result = 64,
        .more = true,
    }));
    try std.testing.expect(IoUring.shouldReleasePending(.multishot, .{
        .op_tag = .recv_multishot,
        .result = -@as(i32, @intFromEnum(posix.E.NOBUFS)),
    }));

    try std.testing.expect(!IoUring.shouldReleasePending(.send_zc, .{
        .op_tag = .send_zc,
        .result = 64,
        .more = true,
    }));
    try std.testing.expect(IoUring.shouldReleasePending(.send_zc, .{
        .op_tag = .send_zc,
        .result = 0,
        .notification = true,
    }));
}
