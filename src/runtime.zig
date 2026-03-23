//! Stackless async runtime — implements io.Runtime.
//!
//! Everything is a task driven by completions. No stack allocation.
//! Uses tardy's Async (kqueue/io_uring/epoll) for I/O submission and reaping.
//! call_soon uses a zero-delay timer so all tasks flow through one path.

const std = @import("std");
const io = @import("io.zig");
const aio_lib = @import("vendor/tardy/aio/lib.zig");
const Async = aio_lib.Async;

const Task = struct {
    ctx: *anyopaque = undefined,
    step: io.StepFn = undefined,
    active: bool = false,
};

pub const Stackless = struct {
    aio: Async,
    allocator: std.mem.Allocator,
    tasks: []Task,
    free_list: std.ArrayList(io.TaskId),
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, aio: Async, max_tasks: u32) !Stackless {
        const tasks = try allocator.alloc(Task, max_tasks);
        @memset(tasks, .{});

        var free_list: std.ArrayList(io.TaskId) = .{};
        try free_list.ensureTotalCapacity(allocator, max_tasks);
        var i: io.TaskId = max_tasks;
        while (i > 0) {
            i -= 1;
            free_list.appendAssumeCapacity(i);
        }

        return .{
            .aio = aio,
            .allocator = allocator,
            .tasks = tasks,
            .free_list = free_list,
        };
    }

    pub fn deinit(self: *Stackless) void {
        self.free_list.deinit(self.allocator);
        self.allocator.free(self.tasks);
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
        const id = s.free_list.popOrNull() orelse return error.TaskPoolExhausted;
        s.tasks[id] = .{ .ctx = ctx, .step = step_fn, .active = true };
        return id;
    }

    fn releaseImpl(ptr: *anyopaque, id: io.TaskId) void {
        const s = cast(ptr);
        s.tasks[id].active = false;
        s.free_list.append(s.allocator, id) catch {};
    }

    fn submitImpl(ptr: *anyopaque, id: io.TaskId, job: io.AsyncSubmission) !void {
        try cast(ptr).aio.queue_job(id, job);
    }

    fn callSoonImpl(ptr: *anyopaque, ctx: *anyopaque, step_fn: io.StepFn) !void {
        const s = cast(ptr);
        const id = s.free_list.popOrNull() orelse return error.TaskPoolExhausted;
        s.tasks[id] = .{ .ctx = ctx, .step = step_fn, .active = true };
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
                if (id >= s.tasks.len or !s.tasks[id].active) continue;

                const task = &s.tasks[id];
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
