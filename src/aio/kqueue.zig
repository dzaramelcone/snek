//! kqueue backend — Task pointer in udata, op stored in Task.
//!
//! kqueue only notifies readiness. The IoOp is stored in task.pending_op
//! so we know what syscall to perform when the event fires.
//! Each Task has at most one outstanding op (ONESHOT kevents).

const std = @import("std");
const posix = std.posix;
const system = posix.system;
const IoOp = @import("io_op.zig").IoOp;
const IoResult = @import("io_op.zig").IoResult;
const Task = @import("../task.zig").Task;
const snek_log = @import("../log.zig");

const log = std.log.scoped(.@"snek/aio/kqueue");

pub const Kqueue = struct {
    kqueue_fd: posix.fd_t,
    changes: []posix.Kevent,
    events: []posix.Kevent,
    tasks_buf: []*Task,
    result_buf: []IoResult,
    change_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_events: u16) !Kqueue {
        return .{
            .kqueue_fd = try posix.kqueue(),
            .changes = try allocator.alloc(posix.Kevent, max_events),
            .events = try allocator.alloc(posix.Kevent, max_events),
            .tasks_buf = try allocator.alloc(*Task, max_events),
            .result_buf = try allocator.alloc(IoResult, max_events),
        };
    }

    pub fn deinit(self: *Kqueue, allocator: std.mem.Allocator) void {
        posix.close(self.kqueue_fd);
        allocator.free(self.changes);
        allocator.free(self.events);
        allocator.free(self.tasks_buf);
        allocator.free(self.result_buf);
    }

    pub fn queue(self: *Kqueue, task: *Task, op: IoOp) !void {
        log.debug("queue: {s}", .{@tagName(op)});

        if (self.change_count >= self.changes.len) return error.Overflow;

        // Store op in the task — survives across event loop cycles
        task.pending_op = op;

        switch (op) {
            .accept => |inner| {
                self.changes[self.change_count] = .{
                    .ident = @intCast(inner.socket),
                    .filter = system.EVFILT.READ,
                    .flags = system.EV.ADD | system.EV.ONESHOT,
                    .fflags = 0, .data = 0,
                    .udata = @intFromPtr(task),
                };
                self.change_count += 1;
            },
            .recv => |inner| {
                self.changes[self.change_count] = .{
                    .ident = @intCast(inner.socket),
                    .filter = system.EVFILT.READ,
                    .flags = system.EV.ADD | system.EV.ONESHOT,
                    .fflags = 0, .data = 0,
                    .udata = @intFromPtr(task),
                };
                self.change_count += 1;
            },
            .send => |inner| {
                self.changes[self.change_count] = .{
                    .ident = @intCast(inner.socket),
                    .filter = system.EVFILT.WRITE,
                    .flags = system.EV.ADD | system.EV.ONESHOT,
                    .fflags = 0, .data = 0,
                    .udata = @intFromPtr(task),
                };
                self.change_count += 1;
            },
            .sendv => |inner| {
                self.changes[self.change_count] = .{
                    .ident = @intCast(inner.socket),
                    .filter = system.EVFILT.WRITE,
                    .flags = system.EV.ADD | system.EV.ONESHOT,
                    .fflags = 0, .data = 0,
                    .udata = @intFromPtr(task),
                };
                self.change_count += 1;
            },
            .connect => |inner| {
                self.changes[self.change_count] = .{
                    .ident = @intCast(inner.socket),
                    .filter = system.EVFILT.WRITE,
                    .flags = system.EV.ADD | system.EV.ONESHOT,
                    .fflags = 0, .data = 0,
                    .udata = @intFromPtr(task),
                };
                self.change_count += 1;
            },
            .close => |fd| {
                posix.close(fd);
            },
            .timer => {},
        }
    }

    pub fn submitAndWait(self: *Kqueue, wait_nr: u32) !struct { tasks: []*Task, results: []IoResult } {
        snek_log.bumpLoop();

        // Single kevent call: submit pending changes AND wait for events
        const timeout_spec: posix.timespec = .{ .sec = 0, .nsec = 0 };
        const timeout: ?*const posix.timespec = if (wait_nr == 0) &timeout_spec else null;

        const changes = self.changes[0..self.change_count];
        if (self.change_count > 0)
            log.debug("kevent: submitting {d} changes", .{self.change_count});

        const event_count = try posix.kevent(self.kqueue_fd, changes, self.events, timeout);
        self.change_count = 0;
        log.debug("kevent: reaped {d} events", .{event_count});

        var result_count: usize = 0;
        for (self.events[0..event_count]) |event| {
            const task: *Task = @ptrFromInt(event.udata);

            self.tasks_buf[result_count] = task;
            self.result_buf[result_count] = performIo(task.pending_op);
            result_count += 1;
        }

        return .{
            .tasks = self.tasks_buf[0..result_count],
            .results = self.result_buf[0..result_count],
        };
    }

    /// Perform the syscall that kqueue said is ready.
    fn performIo(op: IoOp) IoResult {
        switch (op) {
            .accept => |inner| {
                var addr: posix.sockaddr = undefined;
                var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
                const rc = system.accept(inner.socket, &addr, @ptrCast(&addr_len));
                return @intCast(rc);
            },
            .recv => |inner| {
                const rc = system.recvfrom(inner.socket, inner.buffer.ptr, inner.buffer.len, 0, null, null);
                return @intCast(rc);
            },
            .send => |inner| {
                const rc = system.sendto(inner.socket, inner.buffer.ptr, inner.buffer.len, 0, null, 0);
                return @intCast(rc);
            },
            .sendv => |inner| {
                const rc = system.writev(inner.socket, inner.iovecs.ptr, @intCast(inner.iovecs.len));
                return @intCast(rc);
            },
            .connect => return 0,
            .close => return 0,
            .timer => return 0,
        }
    }
};
