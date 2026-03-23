//! I/O interface — the contract between the server and its async runtime.
//!
//! Both stackful (tardy fibers) and stackless (state machines) implement this.
//! The server, HTTP connections, redis client, and Python event loop all code
//! against this interface.

const std = @import("std");
const aio = @import("vendor/tardy/aio/lib.zig");
const completion = @import("vendor/tardy/aio/completion.zig");

pub const AsyncSubmission = aio.AsyncSubmission;
pub const Completion = completion.Completion;
pub const Result = completion.Result;
pub const AcceptResult = completion.AcceptResult;
pub const RecvResult = completion.RecvResult;
pub const SendResult = completion.SendResult;
pub const ConnectResult = completion.ConnectResult;

pub const TaskId = u32;

/// Callback for I/O completion. Receives the task context, task id, and I/O result.
/// Returns the next I/O submission to queue, or null if the task is idle/done.
pub const StepFn = *const fn (ctx: *anyopaque, id: TaskId, result: Result) ?AsyncSubmission;

/// The runtime interface. Both stackful and stackless backends provide this.
pub const Runtime = struct {
    ptr: *anyopaque,
    vtable: VTable,

    const VTable = struct {
        /// Register a task with a step function. Returns a task id.
        register: *const fn (ptr: *anyopaque, ctx: *anyopaque, step: StepFn) anyerror!TaskId,
        /// Release a task id back to the pool.
        release: *const fn (ptr: *anyopaque, id: TaskId) void,
        /// Submit an I/O job for a task.
        submit: *const fn (ptr: *anyopaque, id: TaskId, job: AsyncSubmission) anyerror!void,
        /// Schedule a task to run immediately (no I/O, just step with .none result).
        call_soon: *const fn (ptr: *anyopaque, ctx: *anyopaque, step: StepFn) anyerror!void,
        /// Run the event loop until stopped.
        run: *const fn (ptr: *anyopaque) anyerror!void,
        /// Stop the event loop.
        stop: *const fn (ptr: *anyopaque) void,
    };

    pub fn register(self: Runtime, ctx: *anyopaque, step: StepFn) !TaskId {
        return try self.vtable.register(self.ptr, ctx, step);
    }

    pub fn release(self: Runtime, id: TaskId) void {
        self.vtable.release(self.ptr, id);
    }

    pub fn submit(self: Runtime, id: TaskId, job: AsyncSubmission) !void {
        return try self.vtable.submit(self.ptr, id, job);
    }

    pub fn callSoon(self: Runtime, ctx: *anyopaque, step: StepFn) !void {
        return try self.vtable.call_soon(self.ptr, ctx, step);
    }

    pub fn run(self: Runtime) !void {
        return try self.vtable.run(self.ptr);
    }

    pub fn stop(self: Runtime) void {
        self.vtable.stop(self.ptr);
    }
};
