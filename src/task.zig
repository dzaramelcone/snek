//! Task — generic I/O continuation.
//!
//! A Task is a step function + an opaque context pointer. The event loop
//! round-trips *Task through the kernel (io_uring user_data / kqueue udata),
//! then calls task.step(task, result) on completion.
//!
//! Context is any struct that holds state for the current I/O phase.
//! Step functions are plain typed functions — comptime generics handle
//! type erasure so the runtime sees a uniform interface.
//!
//! Swap step to change behavior. Swap ctx+step to change phase entirely
//! (e.g. HTTP → Redis → HTTP).

const IoOp = @import("aio/io_op.zig").IoOp;
const IoResult = @import("aio/io_op.zig").IoResult;

pub const Task = struct {
    step: *const fn (*Task, IoResult) ?IoOp,
    ctx: *anyopaque,
    /// Pending IoOp for this task. Used by kqueue to know what syscall
    /// to perform when readiness is signaled. io_uring ignores this.
    /// One outstanding op per task at a time.
    pending_op: IoOp = undefined,
    /// Intrusive linked list for queues (e.g. redis pipelining waiters).
    next: ?*Task = null,

    /// Create a Task with a typed context and step function.
    pub fn init(comptime C: type, ctx: *C, comptime stepFn: fn (*C, *Task, IoResult) ?IoOp) Task {
        return .{
            .step = erase(C, stepFn),
            .ctx = ctx,
        };
    }

    /// Swap the step function, keeping the same context.
    pub fn setStep(self: *Task, comptime C: type, comptime stepFn: fn (*C, *Task, IoResult) ?IoOp) void {
        self.step = erase(C, stepFn);
    }

    /// Swap both context and step function (phase transition).
    pub fn setCtxAndStep(self: *Task, comptime C: type, ctx: *C, comptime stepFn: fn (*C, *Task, IoResult) ?IoOp) void {
        self.ctx = ctx;
        self.step = erase(C, stepFn);
    }

    pub fn getCtx(self: *Task, comptime C: type) *C {
        return @ptrCast(@alignCast(self.ctx));
    }

    pub fn toUserData(self: *Task) u64 {
        return @intFromPtr(self);
    }

    pub fn fromUserData(udata: u64) *Task {
        return @ptrFromInt(udata);
    }

    /// Comptime: generate a type-erased wrapper for a typed step function.
    fn erase(comptime C: type, comptime stepFn: fn (*C, *Task, IoResult) ?IoOp) *const fn (*Task, IoResult) ?IoOp {
        const S = struct {
            fn erased(task: *Task, res: IoResult) ?IoOp {
                return stepFn(@ptrCast(@alignCast(task.ctx)), task, res);
            }
        };
        return &S.erased;
    }
};
