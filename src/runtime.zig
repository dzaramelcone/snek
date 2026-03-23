//! Stackless async runtime — implements io.Runtime.
//!
//! Everything is a task driven by completions. No stack allocation.
//! Uses tardy's Async for I/O and Pool for task management.

const std = @import("std");
const io = @import("io.zig");
const aio_lib = @import("vendor/tardy/aio/lib.zig");
const Async = aio_lib.Async;
const tardy = @import("vendor/tardy/lib.zig");
const Pool = tardy.Pool;

const Task = struct {
    ctx: *anyopaque = undefined,
    step: io.StepFn = undefined,
};

pub const Stackless = struct {
    aio: Async,
    allocator: std.mem.Allocator,
    tasks: Pool(Task),
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, aio: Async, initial_tasks: u32) !Stackless {
        return .{
            .aio = aio,
            .allocator = allocator,
            .tasks = try Pool(Task).init(allocator, initial_tasks, .grow),
        };
    }

    pub fn deinit(self: *Stackless) void {
        self.tasks.deinit();
    }

    pub fn runtime(self: *Stackless) io.Runtime {
        return .{
            .ptr = @ptrCast(self),
            .vtable = .{
                .register = &registerImpl,
                .release = &releaseImpl,
                .submit = &submitImpl,
                .call_soon = &callSoonImpl,
                .run = &runImpl,
                .stop = &stopImpl,
            },
        };
    }

    fn cast(ptr: *anyopaque) *Stackless {
        return @ptrCast(@alignCast(ptr));
    }

    fn registerImpl(ptr: *anyopaque, ctx: *anyopaque, step_fn: io.StepFn) !io.TaskId {
        const s = cast(ptr);
        const id = try s.tasks.borrow();
        const task = s.tasks.get_ptr(id);
        task.* = .{ .ctx = ctx, .step = step_fn };
        return @intCast(id);
    }

    fn releaseImpl(ptr: *anyopaque, id: io.TaskId) void {
        cast(ptr).tasks.release(id);
    }

    fn submitImpl(ptr: *anyopaque, id: io.TaskId, job: io.AsyncSubmission) !void {
        try cast(ptr).aio.queue_job(id, job);
    }

    fn callSoonImpl(ptr: *anyopaque, ctx: *anyopaque, step_fn: io.StepFn) !void {
        const s = cast(ptr);
        const id = try s.tasks.borrow();
        const task = s.tasks.get_ptr(id);
        task.* = .{ .ctx = ctx, .step = step_fn };
        try s.aio.queue_job(id, .{ .timer = .{ .seconds = 0, .nanos = 0 } });
    }

    fn runImpl(ptr: *anyopaque) !void {
        const s = cast(ptr);

        while (s.running) {
            try s.aio.submit();
            const completions = try s.aio.reap(true);

            for (completions) |c| {
                if (c.result == .wake) {
                    if (!s.running) return;
                    continue;
                }

                const id: io.TaskId = @intCast(c.task);
                if (!s.tasks.dirty.isSet(id)) continue;

                const task = s.tasks.get_ptr(id);
                if (task.step(task.ctx, id, c.result)) |next_job| {
                    try s.aio.queue_job(id, next_job);
                }
            }
        }
    }

    fn stopImpl(ptr: *anyopaque) void {
        const s = cast(ptr);
        s.running = false;
        s.aio.wake() catch {};
    }
};
