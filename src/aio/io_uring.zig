//! io_uring backend — Task pointer in user_data, no job tracking.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const IoOp = @import("io_op.zig").IoOp;
const IoResult = @import("io_op.zig").IoResult;
const Task = @import("../task.zig").Task;
const snek_log = @import("../log.zig");

const log = std.log.scoped(.@"snek/aio/io_uring");

pub const IoUring = struct {
    ring: linux.IoUring,
    tasks_buf: []*Task,
    result_buf: []IoResult,
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, entries: u16) !IoUring {
        const flags: u32 = linux.IORING_SETUP_COOP_TASKRUN;
        const ring = try linux.IoUring.init(entries, flags);

        return .{
            .ring = ring,
            .tasks_buf = try allocator.alloc(*Task, entries),
            .result_buf = try allocator.alloc(IoResult, entries),
            .capacity = entries,
        };
    }

    pub fn deinit(self: *IoUring, allocator: std.mem.Allocator) void {
        self.ring.deinit();
        allocator.free(self.tasks_buf);
        allocator.free(self.result_buf);
    }

    pub fn queue(self: *IoUring, task: *Task, op: IoOp) !void {
        log.debug("sqe: {s}", .{@tagName(op)});
        const udata: u64 = task.toUserData();
        switch (op) {
            .accept => |inner| {
                _ = try self.ring.accept(udata, inner.socket, null, null, 0);
            },
            .recv => |inner| {
                _ = try self.ring.recv(udata, inner.socket, .{ .buffer = inner.buffer }, 0);
            },
            .send => |inner| {
                _ = try self.ring.send(udata, inner.socket, inner.buffer, 0);
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
        }
    }

    /// Submit + wait. Returns parallel slices of tasks and results.
    pub fn submitAndWait(self: *IoUring, wait_nr: u32) !struct { tasks: []*Task, results: []IoResult } {
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
            self.tasks_buf[i] = Task.fromUserData(cqe.user_data);
            self.result_buf[i] = cqe.res;
        }

        return .{
            .tasks = self.tasks_buf[0..count],
            .results = self.result_buf[0..count],
        };
    }
};
