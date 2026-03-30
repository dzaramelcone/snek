const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;
const PyObject = ffi.PyObject;

extern fn PyEval_SaveThread() ?*anyopaque;
extern fn PyEval_RestoreThread(tstate: ?*anyopaque) void;

pub const MAX_LOOPS: usize = 32;
pub const MAX_READY: usize = 8192;
pub const MAX_SCHEDULED: usize = 256;
pub const MAX_HANDLES: usize = MAX_READY + MAX_SCHEDULED;
pub const MAX_FUTURES: usize = 2048;
pub const MAX_TASKS: usize = 1024;
pub const MAX_HOST_YIELDS: usize = MAX_TASKS;
pub const MAX_FUTURE_CALLBACKS: usize = 8192;
pub const MAX_GATHERS: usize = 1024;
pub const MAX_GATHER_LINKS: usize = 8192;
const HandleId = u16;
pub const HandleToken = u64;
const FutureId = u16;
pub const FutureToken = u64;
const TaskId = u16;
pub const TaskToken = u64;
const CallbackId = u16;
const GatherId = u16;
const GatherLinkId = u16;
const invalid_handle_id = std.math.maxInt(HandleId);
const invalid_future_id = std.math.maxInt(FutureId);
const invalid_task_id = std.math.maxInt(TaskId);
const invalid_callback_id = std.math.maxInt(CallbackId);
const invalid_gather_id = std.math.maxInt(GatherId);
const invalid_gather_link_id = std.math.maxInt(GatherLinkId);
const RequestConnId = u16;
const invalid_request_conn_id = std.math.maxInt(RequestConnId);
const loop_capsule_name: [*:0]const u8 = "snek.loop_slot";
const vectorcall_offset: usize = @as(usize, c.PY_VECTORCALL_ARGUMENTS_OFFSET);
const type_flags: c_ulong = c.Py_TPFLAGS_DEFAULT | c.Py_TPFLAGS_BASETYPE;
const gc_type_flags: c_ulong = type_flags | c.Py_TPFLAGS_HAVE_GC;

pub const LoopError = ffi.PythonError || error{
    InvalidLoopHandle,
    TooManyLoops,
    HandlePoolFull,
    ReadyQueueFull,
    ScheduledQueueFull,
    LoopClosed,
    LoopRunning,
    EventLoopAlreadyRunning,
    AnotherLoopRunning,
    EventLoopStoppedBeforeFutureCompleted,
    OutOfMemory,
    FuturePoolFull,
    TaskPoolFull,
    FutureCallbackPoolFull,
    GatherPoolFull,
    GatherLinkPoolFull,
    HostYieldQueueFull,
    InvalidState,
};

pub const DriveResult = struct {
    ran: usize,
    ready_remaining: usize,
    next_timer_ns: ?u64,
};

pub const HostYieldKind = enum(u8) {
    redis,
    pg,
};

pub const HostYieldRequest = struct {
    kind: HostYieldKind,
    task_token: TaskToken,
    conn_idx: u16,
    sentinel: *PyObject,
};

pub const TypeState = extern struct {
    future_type: ?*PyObject = null,
    task_type: ?*PyObject = null,
    future_iter_type: ?*PyObject = null,
    register_task: ?*PyObject = null,
    unregister_task: ?*PyObject = null,
    iscoroutine: ?*PyObject = null,
    next_task_name: u64 = 1,
};

const ReadyToken = u16;
const invalid_ready_token = std.math.maxInt(ReadyToken);
const task_ready_base: ReadyToken = MAX_HANDLES;
const callback_ready_base: ReadyToken = task_ready_base + MAX_TASKS;

const FutureState = enum(u8) {
    pending = 0,
    cancelled = 1,
    finished = 2,
};

pub const NativeHandleSlot = extern struct {
    used: bool = false,
    running: bool = false,
    cancelled: bool = false,
    is_timer: bool = false,
    has_inline_arg: bool = false,
    generation: u32 = 0,
    when: f64 = 0,
    callback: ?*PyObject = null,
    args: ?*PyObject = null,
    inline_arg: ?*PyObject = null,
    context: ?*PyObject = null,
    loop_obj: ?*PyObject = null,
    wrapper: ?*PyObject = null,
};

pub const FutureCallbackSlot = extern struct {
    used: bool = false,
    ready: bool = false,
    next: CallbackId = invalid_callback_id,
    callback: ?*PyObject = null,
    context: ?*PyObject = null,
    arg: ?*PyObject = null,
    loop_obj: ?*PyObject = null,
};

pub const FutureCore = extern struct {
    state: FutureState = .pending,
    loop_obj: ?*PyObject = null,
    wrapper: ?*PyObject = null,
    result: ?*PyObject = null,
    exception: ?*PyObject = null,
    exception_tb: ?*PyObject = null,
    cancel_message: ?*PyObject = null,
    callbacks_head: CallbackId = invalid_callback_id,
    callbacks_tail: CallbackId = invalid_callback_id,
    gather_links_head: GatherLinkId = invalid_gather_link_id,
};

pub const NativeFutureSlot = extern struct {
    used: bool = false,
    generation: u32 = 0,
    core: FutureCore = .{},
};

pub const NativeTaskSlot = extern struct {
    used: bool = false,
    generation: u32 = 0,
    core: FutureCore = .{},
    coro: ?*PyObject = null,
    context: ?*PyObject = null,
    name: ?*PyObject = null,
    fut_waiter: ?*PyObject = null,
    step_exc: ?*PyObject = null,
    step_value: ?*PyObject = null,
    wakeup_cb: ?*PyObject = null,
    must_cancel: bool = false,
    scheduled: bool = false,
    num_cancels_requested: u32 = 0,
    request_conn_idx: RequestConnId = invalid_request_conn_id,
};

pub const NativeGatherSlot = extern struct {
    used: bool = false,
    generation: u32 = 0,
    outer_obj: ?*PyObject = null,
    outer_core: ?*FutureCore = null,
    children_obj: ?*PyObject = null,
    results_obj: ?*PyObject = null,
    links_head: GatherLinkId = invalid_gather_link_id,
    child_count: u32 = 0,
    finished_count: u32 = 0,
    return_exceptions: bool = false,
};

pub const GatherLinkSlot = extern struct {
    used: bool = false,
    next_in_child: GatherLinkId = invalid_gather_link_id,
    next_in_gather: GatherLinkId = invalid_gather_link_id,
    gather_id: GatherId = invalid_gather_id,
    child_index: u32 = 0,
};

pub const HostYieldSlot = extern struct {
    kind: HostYieldKind = .redis,
    task_token: TaskToken = 0,
    conn_idx: u16 = invalid_request_conn_id,
    sentinel: ?*PyObject = null,
};

pub const ScheduledEntry = extern struct {
    when: f64 = 0,
    seq: u64 = 0,
    handle_id: HandleId = invalid_handle_id,
};

const LoopHandleState = extern struct {
    slot: *LoopSlot,
    generation: u32 = 0,
};

pub const LoopSlot = extern struct {
    used: bool = false,
    closed: bool = false,
    running: bool = false,
    stopping: bool = false,
    debug: bool = false,
    generation: u32 = 0,
    ready_head: usize = 0,
    ready_len: usize = 0,
    scheduled_len: usize = 0,
    free_handle_len: usize = 0,
    free_future_len: usize = 0,
    free_task_len: usize = 0,
    free_callback_len: usize = 0,
    free_gather_len: usize = 0,
    free_gather_link_len: usize = 0,
    host_yield_head: usize = 0,
    host_yield_count: usize = 0,
    sequence: u64 = 0,
    start_ns: i64 = 0,
    type_state: ?*TypeState = null,
    current_task: ?*PyObject = null,
    ready: [MAX_READY]ReadyToken = .{invalid_ready_token} ** MAX_READY,
    scheduled: [MAX_SCHEDULED]ScheduledEntry = .{ScheduledEntry{}} ** MAX_SCHEDULED,
    handles: [MAX_HANDLES]NativeHandleSlot = .{NativeHandleSlot{}} ** MAX_HANDLES,
    free_handles: [MAX_HANDLES]HandleId = .{invalid_handle_id} ** MAX_HANDLES,
    futures: [MAX_FUTURES]NativeFutureSlot = .{NativeFutureSlot{}} ** MAX_FUTURES,
    free_futures: [MAX_FUTURES]FutureId = .{invalid_future_id} ** MAX_FUTURES,
    tasks: [MAX_TASKS]NativeTaskSlot = .{NativeTaskSlot{}} ** MAX_TASKS,
    free_tasks: [MAX_TASKS]TaskId = .{invalid_task_id} ** MAX_TASKS,
    future_callbacks: [MAX_FUTURE_CALLBACKS]FutureCallbackSlot = .{FutureCallbackSlot{}} ** MAX_FUTURE_CALLBACKS,
    free_future_callbacks: [MAX_FUTURE_CALLBACKS]CallbackId = .{invalid_callback_id} ** MAX_FUTURE_CALLBACKS,
    gathers: [MAX_GATHERS]NativeGatherSlot = .{NativeGatherSlot{}} ** MAX_GATHERS,
    free_gathers: [MAX_GATHERS]GatherId = .{invalid_gather_id} ** MAX_GATHERS,
    gather_links: [MAX_GATHER_LINKS]GatherLinkSlot = .{GatherLinkSlot{}} ** MAX_GATHER_LINKS,
    free_gather_links: [MAX_GATHER_LINKS]GatherLinkId = .{invalid_gather_link_id} ** MAX_GATHER_LINKS,
    host_yields: [MAX_HOST_YIELDS]HostYieldSlot = .{HostYieldSlot{}} ** MAX_HOST_YIELDS,
};

const FutureObject = extern struct {
    ob_base: c.PyObject,
    type_state: ?*TypeState = null,
    loop_handle: ?*PyObject = null,
    loop_obj: ?*PyObject = null,
    weakreflist: ?*PyObject = null,
    source_traceback: ?*PyObject = null,
    cancelled_exc: ?*PyObject = null,
    future_token: FutureToken = 0,
    native_kind: NativeObjectKind = .future,
    asyncio_future_blocking: bool = false,
    log_destroy_pending: bool = false,
    log_traceback: bool = false,
    shadow_valid: bool = false,
    shadow_state: FutureState = .pending,
    shadow_result: ?*PyObject = null,
    shadow_exception: ?*PyObject = null,
    shadow_exception_tb: ?*PyObject = null,
    shadow_cancel_message: ?*PyObject = null,
};

const TaskObject = extern struct {
    future: FutureObject,
    task_token: TaskToken = 0,
    coro: ?*PyObject = null,
    context: ?*PyObject = null,
    name: ?*PyObject = null,
    auto_name_seq: u64 = 0,
};

const FutureIterObject = extern struct {
    ob_base: c.PyObject,
    future: ?*PyObject = null,
    yielded: bool = false,
};

const NativeObjectKind = enum(u8) {
    future = 0,
    task = 1,
};

const SavedPyError = struct {
    typ: ?*PyObject = null,
    val: ?*PyObject = null,
    tb: ?*PyObject = null,
};

const IterSendResult = struct {
    result: ?*PyObject = null,
    status: ffi.SendResult,
};

var stop_done_callback_def = c.PyMethodDef{
    .ml_name = "snek_loop_stop_done",
    .ml_meth = @ptrCast(&stopDoneCallback),
    .ml_flags = c.METH_O,
    .ml_doc = null,
};

var task_wakeup_callback_def = c.PyMethodDef{
    .ml_name = "snek_task_wakeup",
    .ml_meth = @ptrCast(&taskWakeupCallback),
    .ml_flags = c.METH_O,
    .ml_doc = null,
};

var future_methods = [_]c.PyMethodDef{
    .{ .ml_name = "__class_getitem__", .ml_meth = @ptrCast(&genericAliasMethod), .ml_flags = c.METH_O | c.METH_CLASS, .ml_doc = null },
    .{ .ml_name = "get_loop", .ml_meth = @ptrCast(&futureGetLoopMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "cancel", .ml_meth = @ptrCast(&futureCancelMethod), .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS, .ml_doc = null },
    .{ .ml_name = "cancelled", .ml_meth = @ptrCast(&futureCancelledMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "done", .ml_meth = @ptrCast(&futureDoneMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "result", .ml_meth = @ptrCast(&futureResultMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "exception", .ml_meth = @ptrCast(&futureExceptionMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "_make_cancelled_error", .ml_meth = @ptrCast(&futureMakeCancelledErrorMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "add_done_callback", .ml_meth = @ptrCast(&futureAddDoneCallbackMethod), .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS, .ml_doc = null },
    .{ .ml_name = "remove_done_callback", .ml_meth = @ptrCast(&futureRemoveDoneCallbackMethod), .ml_flags = c.METH_O, .ml_doc = null },
    .{ .ml_name = "set_result", .ml_meth = @ptrCast(&futureSetResultMethod), .ml_flags = c.METH_O, .ml_doc = null },
    .{ .ml_name = "set_exception", .ml_meth = @ptrCast(&futureSetExceptionMethod), .ml_flags = c.METH_O, .ml_doc = null },
    std.mem.zeroes(c.PyMethodDef),
};

var task_methods = [_]c.PyMethodDef{
    .{ .ml_name = "__class_getitem__", .ml_meth = @ptrCast(&genericAliasMethod), .ml_flags = c.METH_O | c.METH_CLASS, .ml_doc = null },
    .{ .ml_name = "get_coro", .ml_meth = @ptrCast(&taskGetCoroMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "get_context", .ml_meth = @ptrCast(&taskGetContextMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "get_name", .ml_meth = @ptrCast(&taskGetNameMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "set_name", .ml_meth = @ptrCast(&taskSetNameMethod), .ml_flags = c.METH_O, .ml_doc = null },
    .{ .ml_name = "set_result", .ml_meth = @ptrCast(&taskSetResultMethod), .ml_flags = c.METH_O, .ml_doc = null },
    .{ .ml_name = "set_exception", .ml_meth = @ptrCast(&taskSetExceptionMethod), .ml_flags = c.METH_O, .ml_doc = null },
    .{ .ml_name = "cancel", .ml_meth = @ptrCast(&taskCancelMethod), .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS, .ml_doc = null },
    .{ .ml_name = "cancelling", .ml_meth = @ptrCast(&taskCancellingMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "uncancel", .ml_meth = @ptrCast(&taskUncancelMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "get_stack", .ml_meth = @ptrCast(&taskGetStackMethod), .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS, .ml_doc = null },
    .{ .ml_name = "print_stack", .ml_meth = @ptrCast(&taskPrintStackMethod), .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS, .ml_doc = null },
    std.mem.zeroes(c.PyMethodDef),
};

var future_iter_methods = [_]c.PyMethodDef{
    .{ .ml_name = "send", .ml_meth = @ptrCast(&futureIterSendMethod), .ml_flags = c.METH_O, .ml_doc = null },
    .{ .ml_name = "throw", .ml_meth = @ptrCast(&futureIterThrowMethod), .ml_flags = c.METH_VARARGS, .ml_doc = null },
    std.mem.zeroes(c.PyMethodDef),
};

var future_getset = [_]c.PyGetSetDef{
    .{ .name = "_asyncio_future_blocking", .get = futureBlockingGet, .set = futureBlockingSet, .doc = null, .closure = null },
    .{ .name = "_loop", .get = futureLoopAttrGet, .set = null, .doc = null, .closure = null },
    .{ .name = "_state", .get = futureStateGet, .set = null, .doc = null, .closure = null },
    .{ .name = "_result", .get = futureResultAttrGet, .set = null, .doc = null, .closure = null },
    .{ .name = "_exception", .get = futureExceptionAttrGet, .set = null, .doc = null, .closure = null },
    .{ .name = "_callbacks", .get = futureCallbacksGet, .set = null, .doc = null, .closure = null },
    .{ .name = "_source_traceback", .get = futureSourceTracebackGet, .set = null, .doc = null, .closure = null },
    .{ .name = "_log_destroy_pending", .get = futureLogDestroyPendingGet, .set = futureLogDestroyPendingSet, .doc = null, .closure = null },
    .{ .name = "_log_traceback", .get = futureLogTracebackGet, .set = futureLogTracebackSet, .doc = null, .closure = null },
    .{ .name = "_cancel_message", .get = futureCancelMessageGet, .set = futureCancelMessageSet, .doc = null, .closure = null },
    std.mem.zeroes(c.PyGetSetDef),
};

var task_getset = [_]c.PyGetSetDef{
    .{ .name = "_coro", .get = taskCoroGet, .set = null, .doc = null, .closure = null },
    .{ .name = "_context", .get = taskContextGet, .set = null, .doc = null, .closure = null },
    .{ .name = "_name", .get = taskNameGet, .set = taskNameSet, .doc = null, .closure = null },
    .{ .name = "_must_cancel", .get = taskMustCancelGet, .set = null, .doc = null, .closure = null },
    .{ .name = "_fut_waiter", .get = taskFutWaiterGet, .set = null, .doc = null, .closure = null },
    .{ .name = "_num_cancels_requested", .get = taskNumCancelsRequestedGet, .set = null, .doc = null, .closure = null },
    .{ .name = "_cancel_message", .get = taskCancelMessageGet, .set = taskCancelMessageSet, .doc = null, .closure = null },
    std.mem.zeroes(c.PyGetSetDef),
};

var future_type_slots = [_]c.PyType_Slot{
    .{ .slot = c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&futureDealloc)) },
    .{ .slot = c.Py_tp_traverse, .pfunc = @ptrCast(@constCast(&futureTraverse)) },
    .{ .slot = c.Py_tp_clear, .pfunc = @ptrCast(@constCast(&futureClear)) },
    .{ .slot = c.Py_tp_finalize, .pfunc = @ptrCast(@constCast(&futureFinalize)) },
    .{ .slot = c.Py_tp_repr, .pfunc = @ptrCast(@constCast(&futureRepr)) },
    .{ .slot = c.Py_tp_methods, .pfunc = &future_methods },
    .{ .slot = c.Py_tp_getset, .pfunc = &future_getset },
    .{ .slot = c.Py_tp_new, .pfunc = @ptrCast(@constCast(&futureTypeNew)) },
    .{ .slot = c.Py_tp_init, .pfunc = @ptrCast(@constCast(&futureTypeInit)) },
    .{ .slot = c.Py_am_await, .pfunc = @ptrCast(@constCast(&futureAwait)) },
    .{ .slot = c.Py_tp_iter, .pfunc = @ptrCast(@constCast(&futureAwait)) },
    .{ .slot = c.Py_tp_doc, .pfunc = @constCast("native snek future") },
    .{ .slot = 0, .pfunc = null },
};

var task_type_slots = [_]c.PyType_Slot{
    .{ .slot = c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&taskDealloc)) },
    .{ .slot = c.Py_tp_traverse, .pfunc = @ptrCast(@constCast(&taskTraverse)) },
    .{ .slot = c.Py_tp_clear, .pfunc = @ptrCast(@constCast(&taskClear)) },
    .{ .slot = c.Py_tp_finalize, .pfunc = @ptrCast(@constCast(&taskFinalize)) },
    .{ .slot = c.Py_tp_repr, .pfunc = @ptrCast(@constCast(&taskRepr)) },
    .{ .slot = c.Py_tp_methods, .pfunc = &task_methods },
    .{ .slot = c.Py_tp_getset, .pfunc = &task_getset },
    .{ .slot = c.Py_tp_new, .pfunc = @ptrCast(@constCast(&taskTypeNew)) },
    .{ .slot = c.Py_tp_init, .pfunc = @ptrCast(@constCast(&taskTypeInit)) },
    .{ .slot = c.Py_tp_doc, .pfunc = @constCast("native snek task") },
    .{ .slot = 0, .pfunc = null },
};

var future_iter_type_slots = [_]c.PyType_Slot{
    .{ .slot = c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&futureIterDealloc)) },
    .{ .slot = c.Py_tp_methods, .pfunc = &future_iter_methods },
    .{ .slot = c.Py_tp_iter, .pfunc = @ptrCast(@constCast(&futureIterSelf)) },
    .{ .slot = c.Py_tp_iternext, .pfunc = @ptrCast(@constCast(&futureIterNext)) },
    .{ .slot = c.Py_tp_new, .pfunc = @ptrCast(@constCast(&futureIterTypeNew)) },
    .{ .slot = c.Py_tp_doc, .pfunc = @constCast("native snek future iterator") },
    .{ .slot = 0, .pfunc = null },
};

var future_type_spec = c.PyType_Spec{
    .name = "snek._snek.Future",
    .basicsize = @sizeOf(FutureObject),
    .itemsize = 0,
    .flags = gc_type_flags,
    .slots = &future_type_slots,
};

var task_type_spec = c.PyType_Spec{
    .name = "snek._snek.Task",
    .basicsize = @sizeOf(TaskObject),
    .itemsize = 0,
    .flags = gc_type_flags,
    .slots = &task_type_slots,
};

var future_iter_type_spec = c.PyType_Spec{
    .name = "snek._snek._FutureIter",
    .basicsize = @sizeOf(FutureIterObject),
    .itemsize = 0,
    .flags = c.Py_TPFLAGS_DEFAULT,
    .slots = &future_iter_type_slots,
};

fn stopDoneCallback(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const capsule = self_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "missing loop handle");
        return null;
    };
    const slot = slotFromCapsule(capsule) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    slot.stopping = true;
    return ffi.getNone();
}

fn destroyLoopCapsule(capsule: ?*PyObject) callconv(.c) void {
    const obj = capsule orelse return;
    const raw = c.PyCapsule_GetPointer(obj, loop_capsule_name);
    if (raw == null) {
        if (ffi.errOccurred()) ffi.errClear();
        return;
    }
    const handle_state: *LoopHandleState = @ptrCast(@alignCast(raw));
    std.heap.c_allocator.destroy(handle_state);
}

fn taskWakeupCallback(self_obj: ?*PyObject, future_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const self_tuple = self_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "missing task callback state");
        return null;
    };
    const handle_obj = ffi.tupleGetItem(self_tuple, 0) orelse return null;
    const token_obj = ffi.tupleGetItem(self_tuple, 1) orelse return null;
    const token_long = ffi.longAsLong(token_obj) catch return null;
    taskWakeup(handle_obj, @intCast(token_long), future_obj orelse return null) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    return ffi.getNone();
}

pub fn initTypes(mod: *PyObject, type_state: *TypeState) LoopError!void {
    clearTypes(type_state);

    const future_iter_type = c.PyType_FromModuleAndSpec(mod, &future_iter_type_spec, null) orelse
        return error.PythonError;
    errdefer ffi.decref(future_iter_type);

    const future_type = c.PyType_FromModuleAndSpec(mod, &future_type_spec, null) orelse
        return error.PythonError;
    errdefer ffi.decref(future_type);
    const future_tp: *c.PyTypeObject = @ptrCast(@alignCast(future_type));
    future_tp.tp_weaklistoffset = @offsetOf(FutureObject, "weakreflist");

    const task_bases = try ffi.tupleNew(1);
    defer ffi.decref(task_bases);
    try ffi.tupleSetItemTake(task_bases, 0, ffi.OwnedPy.increfBorrowed(future_type));
    const task_type = c.PyType_FromModuleAndSpec(mod, &task_type_spec, task_bases) orelse
        return error.PythonError;
    errdefer ffi.decref(task_type);
    const task_tp: *c.PyTypeObject = @ptrCast(@alignCast(task_type));
    task_tp.tp_weaklistoffset = @offsetOf(FutureObject, "weakreflist");

    try setAttrRaw(mod, "Future", future_type);
    try setAttrRaw(mod, "Task", task_type);

    const tasks_mod = try importModuleRaw("asyncio.tasks");
    defer ffi.decref(tasks_mod);
    const register_task = try getAttrRaw(tasks_mod, "_py_register_task");
    errdefer ffi.decref(register_task);
    const unregister_task = try getAttrRaw(tasks_mod, "_py_unregister_task");
    errdefer ffi.decref(unregister_task);
    const coroutines_mod = try importModuleRaw("asyncio.coroutines");
    defer ffi.decref(coroutines_mod);
    const iscoroutine = try getAttrRaw(coroutines_mod, "iscoroutine");
    errdefer ffi.decref(iscoroutine);

    type_state.future_iter_type = future_iter_type;
    type_state.future_type = future_type;
    type_state.task_type = task_type;
    type_state.register_task = register_task;
    type_state.unregister_task = unregister_task;
    type_state.iscoroutine = iscoroutine;
}

pub fn clearTypes(type_state: *TypeState) void {
    if (type_state.future_iter_type) |obj| ffi.decref(obj);
    if (type_state.future_type) |obj| ffi.decref(obj);
    if (type_state.task_type) |obj| ffi.decref(obj);
    if (type_state.register_task) |obj| ffi.decref(obj);
    if (type_state.unregister_task) |obj| ffi.decref(obj);
    if (type_state.iscoroutine) |obj| ffi.decref(obj);
    type_state.* = .{};
}

pub fn createFutureObject(type_state: *TypeState, handle_obj: *PyObject, loop_obj: *PyObject) LoopError!*PyObject {
    const type_obj = type_state.future_type orelse return error.InvalidState;
    return createFutureObjectWithType(type_state, type_obj, handle_obj, loop_obj);
}

fn createFutureObjectWithType(
    type_state: *TypeState,
    type_obj: *PyObject,
    handle_obj: *PyObject,
    loop_obj: *PyObject,
) LoopError!*PyObject {
    const self = try allocHeapObject(FutureObject, type_obj);
    errdefer destroyFutureObject(self);
    try bindFutureObject(self, type_state, handle_obj, loop_obj);
    return futurePy(self);
}

pub fn createTaskObject(
    type_state: *TypeState,
    handle_obj: *PyObject,
    loop_obj: *PyObject,
    coro: *PyObject,
    context: ?*PyObject,
    name: ?*PyObject,
    eager_start: bool,
) LoopError!*PyObject {
    const type_obj = type_state.task_type orelse return error.InvalidState;
    return createTaskObjectWithType(type_state, type_obj, handle_obj, loop_obj, coro, context, name, eager_start);
}

pub fn adoptStartedTaskObject(
    type_state: *TypeState,
    handle_obj: *PyObject,
    loop_obj: *PyObject,
    coro: *PyObject,
    yielded: *PyObject,
    context: ?*PyObject,
    name: ?*PyObject,
) LoopError!*PyObject {
    const type_obj = type_state.task_type orelse return error.InvalidState;
    return adoptStartedTaskObjectWithType(type_state, type_obj, handle_obj, loop_obj, coro, yielded, context, name);
}

fn createTaskObjectWithType(
    type_state: *TypeState,
    type_obj: *PyObject,
    handle_obj: *PyObject,
    loop_obj: *PyObject,
    coro: *PyObject,
    context: ?*PyObject,
    name: ?*PyObject,
    eager_start: bool,
) LoopError!*PyObject {
    if (!(try isCoroutineObject(type_state, coro))) {
        _ = c.PyErr_Format(c.PyExc_TypeError, "a coroutine was expected, got %R", coro);
        return error.PythonError;
    }
    const self = try allocHeapObject(TaskObject, type_obj);
    errdefer destroyTaskObject(self);
    initFutureObject(&self.future, type_state, handle_obj, loop_obj);
    self.future.native_kind = .task;
    self.future.log_destroy_pending = true;
    try maybeInitTaskSourceTraceback(&self.future, handle_obj);

    const resolved_context = if (context) |ctx|
        if (!isNone(ctx)) blk: {
            ffi.incref(ctx);
            break :blk ctx;
        } else try currentContext()
    else
        try currentContext();
    defer ffi.decref(resolved_context);
    try initTaskName(self, type_state, name);

    self.task_token = try newTask(handle_obj, loop_obj, taskPy(self), coro, resolved_context, self.name, eager_start);
    if (self.name) |task_name| {
        ffi.decref(task_name);
        self.name = null;
    }
    return taskPy(self);
}

fn adoptStartedTaskObjectWithType(
    type_state: *TypeState,
    type_obj: *PyObject,
    handle_obj: *PyObject,
    loop_obj: *PyObject,
    coro: *PyObject,
    yielded: *PyObject,
    context: ?*PyObject,
    name: ?*PyObject,
) LoopError!*PyObject {
    if (!(try isCoroutineObject(type_state, coro))) {
        _ = c.PyErr_Format(c.PyExc_TypeError, "a coroutine was expected, got %R", coro);
        return error.PythonError;
    }

    const self = try allocHeapObject(TaskObject, type_obj);
    errdefer destroyTaskObject(self);
    initFutureObject(&self.future, type_state, handle_obj, loop_obj);
    self.future.native_kind = .task;
    self.future.log_destroy_pending = true;
    try maybeInitTaskSourceTraceback(&self.future, handle_obj);

    const resolved_context = if (context) |ctx|
        if (!isNone(ctx)) blk: {
            ffi.incref(ctx);
            break :blk ctx;
        } else try currentContext()
    else
        try currentContext();
    defer ffi.decref(resolved_context);
    try initTaskName(self, type_state, name);

    const slot = try slotFromCapsule(handle_obj);
    const task_id = try allocTask(handle_obj, slot, loop_obj, taskPy(self), coro, resolved_context, self.name, null);
    errdefer releaseTask(slot, task_id);
    self.task_token = tokenForTask(slot, task_id);

    try handleTaskYielded(slot, task_id, yielded);

    if (self.name) |task_name| {
        ffi.decref(task_name);
        self.name = null;
    }
    return taskPy(self);
}

fn allocHeapObject(comptime T: type, type_obj: *PyObject) LoopError!*T {
    const tp: *c.PyTypeObject = @ptrCast(@alignCast(type_obj));
    const raw = tp.tp_alloc.?(tp, 0) orelse return error.PythonError;
    return @ptrCast(@alignCast(raw));
}

fn initFutureObject(self: *FutureObject, type_state: *TypeState, handle_obj: *PyObject, loop_obj: *PyObject) void {
    self.type_state = type_state;
    self.loop_handle = handle_obj;
    self.loop_obj = loop_obj;
    self.weakreflist = null;
    self.source_traceback = null;
    self.cancelled_exc = null;
    self.future_token = 0;
    self.native_kind = .future;
    self.asyncio_future_blocking = false;
    self.log_destroy_pending = false;
    self.log_traceback = false;
    self.shadow_valid = false;
    self.shadow_state = .pending;
    self.shadow_result = null;
    self.shadow_exception = null;
    self.shadow_exception_tb = null;
    self.shadow_cancel_message = null;
    ffi.incref(handle_obj);
    ffi.incref(loop_obj);
}

fn maybeInitSourceTracebackDepth(self: *FutureObject, handle_obj: *PyObject, depth_value: c_long) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    if (!slot.debug) return;

    const sys_mod = try importModuleRaw("sys");
    defer ffi.decref(sys_mod);
    const getframe_fn = try getAttrRaw(sys_mod, "_getframe");
    defer ffi.decref(getframe_fn);
    const depth = try ffi.longFromLong(depth_value);
    defer ffi.decref(depth);
    const frame = try callCallableOneArg(getframe_fn, depth);
    defer ffi.decref(frame);

    const helpers_mod = try importModuleRaw("asyncio.format_helpers");
    defer ffi.decref(helpers_mod);
    const extract_stack_fn = try getAttrRaw(helpers_mod, "extract_stack");
    defer ffi.decref(extract_stack_fn);
    self.source_traceback = try callCallableOneArg(extract_stack_fn, frame);
}

fn maybeInitSourceTraceback(self: *FutureObject, handle_obj: *PyObject) LoopError!void {
    // Native Future constructors don't add a Python frame of their own, so
    // depth 0 is the visible Python caller.
    try maybeInitSourceTracebackDepth(self, handle_obj, 0);
}

fn maybeInitTaskSourceTraceback(self: *FutureObject, handle_obj: *PyObject) LoopError!void {
    // _snek.task_new is called from EventLoop.create_task(), and CPython omits
    // that helper frame from Task._source_traceback.
    try maybeInitSourceTracebackDepth(self, handle_obj, 1);
}

fn raiseAsyncioInvalidStateError(message: [*:0]const u8) LoopError {
    const excs = try importModuleRaw("asyncio.exceptions");
    defer ffi.decref(excs);
    const invalid = try getAttrRaw(excs, "InvalidStateError");
    defer ffi.decref(invalid);
    c.PyErr_SetString(invalid, message);
    return error.PythonError;
}

fn normalizeFutureException(exc: *PyObject) LoopError!*PyObject {
    if (c.PyErr_GivenExceptionMatches(exc, c.PyExc_StopIteration) == 0) {
        ffi.incref(exc);
        return exc;
    }

    const message = try ffi.unicodeFromString(
        "StopIteration interacts badly with generators and cannot be raised into a Future",
    );
    defer ffi.decref(message);

    const wrapped = try callCallableOneArg(c.PyExc_RuntimeError, message);
    ffi.incref(exc);
    c.PyException_SetCause(wrapped, exc);
    ffi.incref(exc);
    c.PyException_SetContext(wrapped, exc);
    return wrapped;
}

fn bindFutureObject(self: *FutureObject, type_state: *TypeState, handle_obj: *PyObject, loop_obj: *PyObject) LoopError!void {
    initFutureObject(self, type_state, handle_obj, loop_obj);
    errdefer clearFutureRefs(self);
    try maybeInitSourceTraceback(self, handle_obj);
    self.future_token = try newFuture(handle_obj, loop_obj, futurePy(self));
}

fn futurePy(self: *FutureObject) *PyObject {
    return @ptrCast(self);
}

fn taskPy(self: *TaskObject) *PyObject {
    return @ptrCast(self);
}

fn futureObjectFromPy(self_obj: *PyObject) *FutureObject {
    return @ptrCast(@alignCast(self_obj));
}

fn taskObjectFromPy(self_obj: *PyObject) *TaskObject {
    return @ptrCast(@alignCast(self_obj));
}

fn taskObjectFromFuture(self: *FutureObject) *TaskObject {
    return @fieldParentPtr("future", self);
}

fn ensureFutureTypeState(self: *FutureObject) LoopError!*TypeState {
    if (self.type_state) |state| return state;
    if (self.loop_handle) |handle| {
        const slot = try slotFromCapsule(handle);
        if (slot.type_state) |state| {
            self.type_state = state;
            return state;
        }
    }
    return error.InvalidState;
}

fn activeFutureCore(self: *FutureObject) LoopError!?*FutureCore {
    if (self.loop_handle == null or !futureHasBacking(self)) return null;
    return futureCore(self) catch |err| switch (err) {
        error.InvalidLoopHandle, error.InvalidState => null,
        else => return err,
    };
}

fn futureResultShadow(self: *FutureObject) LoopError!*PyObject {
    switch (self.shadow_state) {
        .pending => {
            const excs = try importModuleRaw("asyncio.exceptions");
            defer ffi.decref(excs);
            const invalid = try getAttrRaw(excs, "InvalidStateError");
            defer ffi.decref(invalid);
            c.PyErr_SetString(invalid, "Result is not set.");
            return error.PythonError;
        },
        .cancelled => {
            const cancelled = try makeCancelledError(self.shadow_cancel_message);
            return raiseStoredException(cancelled, null);
        },
        .finished => {
            if (self.shadow_exception) |exc| {
                ffi.incref(exc);
                return raiseStoredException(exc, self.shadow_exception_tb);
            }
            const result = self.shadow_result orelse return ffi.getNone();
            ffi.incref(result);
            return result;
        },
    }
}

fn futureExceptionShadow(self: *FutureObject) LoopError!*PyObject {
    switch (self.shadow_state) {
        .pending => {
            const excs = try importModuleRaw("asyncio.exceptions");
            defer ffi.decref(excs);
            const invalid = try getAttrRaw(excs, "InvalidStateError");
            defer ffi.decref(invalid);
            c.PyErr_SetString(invalid, "Exception is not set.");
            return error.PythonError;
        },
        .cancelled => {
            const cancelled = try makeCancelledError(self.shadow_cancel_message);
            return raiseStoredException(cancelled, null);
        },
        .finished => {
            if (self.shadow_exception) |exc| {
                ffi.incref(exc);
                return exc;
            }
            return ffi.getNone();
        },
    }
}

fn destroyFutureObject(self: *FutureObject) void {
    if (self.source_traceback) |obj| ffi.decref(obj);
    if (self.cancelled_exc) |obj| ffi.decref(obj);
    if (self.loop_obj) |obj| ffi.decref(obj);
    if (self.loop_handle) |obj| ffi.decref(obj);
    const tp: *c.PyTypeObject = @ptrCast(self.ob_base.ob_type);
    tp.tp_free.?(@ptrCast(self));
}

fn destroyTaskObject(self: *TaskObject) void {
    if (self.coro) |obj| ffi.decref(obj);
    if (self.context) |obj| ffi.decref(obj);
    if (self.name) |obj| ffi.decref(obj);
    destroyFutureObject(&self.future);
}

fn isFinalizing() bool {
    return c.Py_IsFinalizing() != 0;
}

fn futureLoopHandle(self: *FutureObject) LoopError!*PyObject {
    return self.loop_handle orelse error.InvalidState;
}

fn futureLoopObj(self: *FutureObject) LoopError!*PyObject {
    return self.loop_obj orelse error.InvalidState;
}

fn futureNative(self: *FutureObject) LoopError!*NativeFutureSlot {
    if (self.native_kind == .task) return error.InvalidState;
    const handle = try futureLoopHandle(self);
    return futureFromToken(handle, self.future_token);
}

fn taskNative(self: *TaskObject) LoopError!*NativeTaskSlot {
    const handle = try futureLoopHandle(&self.future);
    return taskFromToken(handle, self.task_token);
}

fn futureCore(self: *FutureObject) LoopError!*FutureCore {
    return switch (self.native_kind) {
        .future => &((try futureNative(self)).core),
        .task => &((try taskNative(taskObjectFromFuture(self))).core),
    };
}

fn futureHasBacking(self: *FutureObject) bool {
    return switch (self.native_kind) {
        .future => self.future_token != 0,
        .task => taskObjectFromFuture(self).task_token != 0,
    };
}

fn currentContext() LoopError!*PyObject {
    return ffi.contextCopyCurrent();
}

fn getCurrentEventLoop() LoopError!*PyObject {
    var events_mod = ffi.OwnedPy.init(try importModuleRaw("asyncio.events"));
    defer events_mod.deinit();
    var func = ffi.OwnedPy.init(try getAttrRaw(events_mod.get(), "get_event_loop"));
    defer func.deinit();
    return callObjectRaw(func.get(), null);
}

fn getLoopHandleObject(loop_obj: *PyObject) LoopError!*PyObject {
    const handle_obj = try getAttrRaw(loop_obj, "_handle");
    if (isNone(handle_obj)) {
        ffi.decref(handle_obj);
        return error.InvalidLoopHandle;
    }
    return handle_obj;
}

fn loopObjectClosed(loop_obj: *PyObject) LoopError!bool {
    const closed_obj = try callMethodNoArgs(loop_obj, "is_closed");
    defer ffi.decref(closed_obj);
    const truth = c.PyObject_IsTrue(closed_obj);
    if (truth < 0) return error.PythonError;
    return truth == 1;
}

fn resolveCtorLoop(loop_arg: ?*PyObject) LoopError!struct { loop_obj: *PyObject, handle_obj: ?*PyObject } {
    const loop_obj = if (loop_arg) |obj|
        if (!isNone(obj)) blk: {
            ffi.incref(obj);
            break :blk obj;
        } else try getCurrentEventLoop()
    else
        try getCurrentEventLoop();
    errdefer ffi.decref(loop_obj);
    const handle_obj = getLoopHandleObject(loop_obj) catch |err| switch (err) {
        error.InvalidLoopHandle => blk: {
            if (try loopObjectClosed(loop_obj)) break :blk null;
            return err;
        },
        else => return err,
    };
    return .{ .loop_obj = loop_obj, .handle_obj = handle_obj };
}

fn isCoroutineObject(type_state: *TypeState, obj: *PyObject) LoopError!bool {
    if (c.PyCoro_CheckExact(obj) != 0) return true;
    const iscoroutine_fn = type_state.iscoroutine orelse return error.InvalidState;
    const res = try callCallableOneArg(iscoroutine_fn, obj);
    defer ffi.decref(res);
    const truth = c.PyObject_IsTrue(res);
    if (truth < 0) return error.PythonError;
    return truth == 1;
}

fn nextAutoTaskNameSeq(type_state: *TypeState) u64 {
    if (type_state.next_task_name == 0) type_state.next_task_name = 1;
    const seq = type_state.next_task_name;
    type_state.next_task_name +%= 1;
    return seq;
}

fn autoTaskName(seq: u64) LoopError!*PyObject {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "Task-{d}", .{seq}) catch return error.OutOfMemory;
    return ffi.unicodeFromSlice(text.ptr, text.len);
}

fn clearFutureRefs(self: *FutureObject) void {
    if (self.source_traceback) |obj| {
        ffi.decref(obj);
        self.source_traceback = null;
    }
    if (self.cancelled_exc) |obj| {
        ffi.decref(obj);
        self.cancelled_exc = null;
    }
    if (self.loop_obj) |obj| {
        ffi.decref(obj);
        self.loop_obj = null;
    }
    if (self.loop_handle) |obj| {
        ffi.decref(obj);
        self.loop_handle = null;
    }
    if (self.shadow_result) |obj| {
        ffi.decref(obj);
        self.shadow_result = null;
    }
    if (self.shadow_exception) |obj| {
        ffi.decref(obj);
        self.shadow_exception = null;
    }
    if (self.shadow_exception_tb) |obj| {
        ffi.decref(obj);
        self.shadow_exception_tb = null;
    }
    if (self.shadow_cancel_message) |obj| {
        ffi.decref(obj);
        self.shadow_cancel_message = null;
    }
    self.shadow_valid = false;
    self.shadow_state = .pending;
    self.type_state = null;
}

fn clearTaskRefs(self: *TaskObject) void {
    if (self.coro) |obj| {
        ffi.decref(obj);
        self.coro = null;
    }
    if (self.context) |obj| {
        ffi.decref(obj);
        self.context = null;
    }
    if (self.name) |obj| {
        ffi.decref(obj);
        self.name = null;
    }
}

fn replaceCancelledError(self: *FutureObject, exc: *PyObject) void {
    if (self.cancelled_exc) |obj| ffi.decref(obj);
    self.cancelled_exc = exc;
}

fn moveCancelledErrorToCore(core: *FutureCore, saved: *SavedPyError) void {
    const wrapper = core.wrapper orelse return;
    const exc = saved.val orelse return;
    const future_obj = futureObjectFromPy(wrapper);
    replaceCancelledError(future_obj, exc);
    saved.val = null;
}

fn freeFutureBacking(self: *FutureObject) void {
    if (self.native_kind == .task) {
        self.future_token = 0;
        return;
    }
    if (self.future_token == 0 or isFinalizing()) {
        self.future_token = 0;
        return;
    }
    if (self.loop_handle) |handle| {
        freeFuture(handle, self.future_token) catch {
            if (ffi.errOccurred()) ffi.errClear();
        };
    }
    self.future_token = 0;
}

fn freeTaskBacking(self: *TaskObject) void {
    if (self.task_token == 0 or isFinalizing()) {
        self.task_token = 0;
        return;
    }
    if (self.future.loop_handle) |handle| {
        freeTask(handle, self.task_token) catch {
            if (ffi.errOccurred()) ffi.errClear();
        };
    }
    self.task_token = 0;
}

fn logFutureExceptionUnretrieved(self: *FutureObject, obj: *PyObject) void {
    if (!self.log_traceback) return;
    self.log_traceback = false;

    const exception_obj, const tb_obj = blk: {
        if (activeFutureCore(self) catch null) |core| {
            break :blk .{ core.exception, core.exception_tb };
        }
        if (self.shadow_valid) {
            break :blk .{ self.shadow_exception, self.shadow_exception_tb };
        }
        break :blk .{ null, null };
    };

    const exc = exception_obj orelse return;
    const loop_obj = self.loop_obj orelse return;

    const had_err = ffi.errOccurred();
    const saved_err = if (had_err) fetchPyError() else SavedPyError{};
    defer if (had_err) restorePyError(saved_err);

    const ctx = ffi.dictNew() catch {
        if (ffi.errOccurred()) ffi.errClear();
        return;
    };
    defer ffi.decref(ctx);

    const tp: *c.PyTypeObject = @ptrCast(@alignCast(self.ob_base.ob_type));
    const tp_name = std.mem.span(tp.tp_name);
    const short_name = if (std.mem.lastIndexOfScalar(u8, tp_name, '.')) |idx| tp_name[idx + 1 ..] else tp_name;
    var message_buf: [256:0]u8 = undefined;
    const message_z = std.fmt.bufPrintZ(&message_buf, "{s} exception was never retrieved", .{short_name}) catch return;
    const message = ffi.unicodeFromString(message_z.ptr) catch {
        if (ffi.errOccurred()) ffi.errClear();
        return;
    };
    defer ffi.decref(message);

    _ = c.PyDict_SetItemString(ctx, "message", message);
    _ = c.PyDict_SetItemString(ctx, "exception", exc);
    _ = c.PyDict_SetItemString(ctx, "future", obj);
    if (self.source_traceback) |traceback_obj| {
        _ = c.PyDict_SetItemString(ctx, "source_traceback", traceback_obj);
    }

    const res = callMethodOneArg(loop_obj, "call_exception_handler", ctx) catch {
        if (ffi.errOccurred()) ffi.errPrint();
        return;
    };
    ffi.decref(res);
    _ = tb_obj;
}

fn futureDealloc(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const self = futureObjectFromPy(obj);
    if (c.PyObject_CallFinalizerFromDealloc(obj) < 0) return;
    c.PyObject_GC_UnTrack(obj);
    c.PyObject_ClearWeakRefs(obj);
    freeFutureBacking(self);
    clearFutureRefs(self);
    const tp: *c.PyTypeObject = @ptrCast(self.ob_base.ob_type);
    tp.tp_free.?(@ptrCast(self));
}

fn futureFinalize(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const self = futureObjectFromPy(obj);
    logFutureExceptionUnretrieved(self, obj);
}

fn taskDealloc(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const self = taskObjectFromPy(obj);
    if (c.PyObject_CallFinalizerFromDealloc(obj) < 0) return;
    c.PyObject_GC_UnTrack(obj);
    c.PyObject_ClearWeakRefs(obj);
    freeTaskBacking(self);
    clearTaskRefs(self);
    clearFutureRefs(&self.future);
    const tp: *c.PyTypeObject = @ptrCast(self.future.ob_base.ob_type);
    tp.tp_free.?(@ptrCast(self));
}

fn taskFinalize(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const self = taskObjectFromPy(obj);
    if (!self.future.log_destroy_pending) return;

    const core = futureCore(&self.future) catch return;
    if (core.state != .pending) return;

    const loop_obj = self.future.loop_obj orelse return;
    const had_err = ffi.errOccurred();
    const saved_err = if (had_err) fetchPyError() else SavedPyError{};
    defer if (had_err) restorePyError(saved_err);

    const ctx = ffi.dictNew() catch {
        if (ffi.errOccurred()) ffi.errClear();
        return;
    };
    defer ffi.decref(ctx);

    const msg = ffi.unicodeFromString("Task was destroyed but it is pending!") catch {
        if (ffi.errOccurred()) ffi.errClear();
        return;
    };
    defer ffi.decref(msg);
    _ = c.PyDict_SetItemString(ctx, "message", msg);
    _ = c.PyDict_SetItemString(ctx, "task", obj);
    const tb_obj = self.future.source_traceback orelse ffi.getNone();
    _ = c.PyDict_SetItemString(ctx, "source_traceback", tb_obj);

    const res = callMethodOneArg(loop_obj, "call_exception_handler", ctx) catch {
        if (ffi.errOccurred()) ffi.errPrint();
        return;
    };
    ffi.decref(res);
}

fn visitPyObj(visit: c.visitproc, arg: ?*anyopaque, obj: ?*PyObject) c_int {
    if (obj) |value| return visit.?(value, arg);
    return 0;
}

fn futureTraverse(self_obj: ?*PyObject, visit: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    const self = futureObjectFromPy(self_obj orelse return 0);
    if (visitPyObj(visit, arg, self.loop_handle) != 0) return -1;
    if (visitPyObj(visit, arg, self.loop_obj) != 0) return -1;
    if (visitPyObj(visit, arg, self.source_traceback) != 0) return -1;
    if (visitPyObj(visit, arg, self.cancelled_exc) != 0) return -1;
    if (visitPyObj(visit, arg, self.shadow_result) != 0) return -1;
    if (visitPyObj(visit, arg, self.shadow_exception) != 0) return -1;
    if (visitPyObj(visit, arg, self.shadow_exception_tb) != 0) return -1;
    if (visitPyObj(visit, arg, self.shadow_cancel_message) != 0) return -1;

    const slot = if (self.loop_handle) |handle| slotFromCapsule(handle) catch return 0 else return 0;
    const core = futureCore(self) catch return 0;
    if (visitPyObj(visit, arg, core.wrapper) != 0) return -1;
    if (visitPyObj(visit, arg, core.result) != 0) return -1;
    if (visitPyObj(visit, arg, core.exception) != 0) return -1;
    if (visitPyObj(visit, arg, core.exception_tb) != 0) return -1;
    if (visitPyObj(visit, arg, core.cancel_message) != 0) return -1;
    var cb_id = core.callbacks_head;
    while (cb_id != invalid_callback_id) {
        const entry = &slot.future_callbacks[cb_id];
        if (visitPyObj(visit, arg, entry.callback) != 0) return -1;
        if (visitPyObj(visit, arg, entry.context) != 0) return -1;
        cb_id = entry.next;
    }
    return 0;
}

fn taskTraverse(self_obj: ?*PyObject, visit: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    if (futureTraverse(self_obj, visit, arg) != 0) return -1;
    const self = taskObjectFromPy(self_obj orelse return 0);
    if (visitPyObj(visit, arg, self.coro) != 0) return -1;
    if (visitPyObj(visit, arg, self.context) != 0) return -1;
    if (visitPyObj(visit, arg, self.name) != 0) return -1;

    const task = taskNative(self) catch return 0;
    if (visitPyObj(visit, arg, task.coro) != 0) return -1;
    if (visitPyObj(visit, arg, task.context) != 0) return -1;
    if (visitPyObj(visit, arg, task.name) != 0) return -1;
    if (visitPyObj(visit, arg, task.fut_waiter) != 0) return -1;
    if (visitPyObj(visit, arg, task.step_exc) != 0) return -1;
    if (visitPyObj(visit, arg, task.step_value) != 0) return -1;
    if (visitPyObj(visit, arg, task.wakeup_cb) != 0) return -1;
    return 0;
}

fn futureClear(self_obj: ?*PyObject) callconv(.c) c_int {
    const self = futureObjectFromPy(self_obj orelse return 0);
    freeFutureBacking(self);
    clearFutureRefs(self);
    return 0;
}

fn taskClear(self_obj: ?*PyObject) callconv(.c) c_int {
    const self = taskObjectFromPy(self_obj orelse return 0);
    freeTaskBacking(self);
    clearTaskRefs(self);
    clearFutureRefs(&self.future);
    return 0;
}

fn futureTypeNew(tp_obj: ?*c.PyTypeObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) ?*PyObject {
    const tp = tp_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "future type is null");
        return null;
    };
    _ = args;
    _ = kwargs;
    const self = allocHeapObject(FutureObject, @ptrCast(tp)) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    return futurePy(self);
}

fn futureTypeInit(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) c_int {
    const self = futureObjectFromPy(self_obj orelse return -1);
    if (args != null and (!ffi.isTuple(args.?) or ffi.tupleSize(args.?) != 0)) {
        c.PyErr_SetString(c.PyExc_TypeError, "Future() takes no positional arguments");
        return -1;
    }
    if (kwargs != null and !ffi.isDict(kwargs.?)) {
        c.PyErr_SetString(c.PyExc_TypeError, "kwargs must be a dict");
        return -1;
    }

    _ = futureClear(self_obj);

    const loop_arg = if (kwargs) |kw| blk: {
        const kw_loop = ffi.dictGetItemString(kw, "loop");
        const allowed: isize = if (kw_loop != null) 1 else 0;
        if (ffi.dictSize(kw) != allowed) {
            c.PyErr_SetString(c.PyExc_TypeError, "unexpected keyword argument");
            return -1;
        }
        break :blk kw_loop;
    } else null;

    const loop = resolveCtorLoop(loop_arg) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return -1;
    };
    defer ffi.decref(loop.loop_obj);
    defer if (loop.handle_obj) |obj| ffi.decref(obj);
    if (loop.handle_obj) |handle_obj| {
        const type_state = blk: {
            const slot = slotFromCapsule(handle_obj) catch |err| {
                if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
                return -1;
            };
            break :blk slot.type_state orelse {
                c.PyErr_SetString(c.PyExc_RuntimeError, "future type state is not initialized");
                return -1;
            };
        };

        bindFutureObject(self, type_state, handle_obj, loop.loop_obj) catch |err| {
            if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
            return -1;
        };
    } else {
        self.type_state = null;
        self.loop_handle = null;
        self.loop_obj = loop.loop_obj;
        self.weakreflist = null;
        self.source_traceback = null;
        self.cancelled_exc = null;
        self.future_token = 0;
        self.asyncio_future_blocking = false;
        self.log_destroy_pending = false;
        self.log_traceback = false;
        ffi.incref(loop.loop_obj);
    }
    return 0;
}

fn taskTypeNew(tp_obj: ?*c.PyTypeObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) ?*PyObject {
    const tp = tp_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "task type is null");
        return null;
    };
    _ = args;
    _ = kwargs;
    const self = allocHeapObject(TaskObject, @ptrCast(tp)) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    return taskPy(self);
}

fn taskTypeInit(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) c_int {
    const self = taskObjectFromPy(self_obj orelse return -1);
    const tuple = args orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "Task() missing coroutine");
        return -1;
    };
    if (!ffi.isTuple(tuple)) {
        c.PyErr_SetString(c.PyExc_TypeError, "Task() arguments must be a tuple");
        return -1;
    }
    if (ffi.tupleSize(tuple) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "Task() takes exactly one positional argument");
        return -1;
    }
    const coro = ffi.tupleGetItem(tuple, 0) orelse return -1;
    if (kwargs != null and !ffi.isDict(kwargs.?)) {
        c.PyErr_SetString(c.PyExc_TypeError, "kwargs must be a dict");
        return -1;
    }

    _ = taskClear(self_obj);

    var loop_arg: ?*PyObject = null;
    var name_arg: ?*PyObject = null;
    var context_arg: ?*PyObject = null;
    var eager_start = false;
    if (kwargs) |kw| {
        const kw_loop = ffi.dictGetItemString(kw, "loop");
        const kw_name = ffi.dictGetItemString(kw, "name");
        const kw_context = ffi.dictGetItemString(kw, "context");
        const kw_eager = ffi.dictGetItemString(kw, "eager_start");
        var allowed: isize = 0;
        if (kw_loop != null) allowed += 1;
        if (kw_name != null) allowed += 1;
        if (kw_context != null) allowed += 1;
        if (kw_eager != null) allowed += 1;
        if (ffi.dictSize(kw) != allowed) {
            c.PyErr_SetString(c.PyExc_TypeError, "unexpected keyword argument");
            return -1;
        }
        loop_arg = kw_loop;
        name_arg = kw_name;
        context_arg = kw_context;
        if (kw_eager) |obj| {
            const truth = c.PyObject_IsTrue(obj);
            if (truth < 0) return -1;
            eager_start = truth == 1;
        }
    }

    const loop = resolveCtorLoop(loop_arg) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return -1;
    };
    defer ffi.decref(loop.loop_obj);
    defer if (loop.handle_obj) |obj| ffi.decref(obj);
    const handle_obj = loop.handle_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "LoopClosed");
        return -1;
    };
    const type_state = blk: {
        const slot = slotFromCapsule(handle_obj) catch |err| {
            if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
            return -1;
        };
        break :blk slot.type_state orelse {
            c.PyErr_SetString(c.PyExc_RuntimeError, "task type state is not initialized");
            return -1;
        };
    };

    if (!(isCoroutineObject(type_state, coro) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return -1;
    })) {
        _ = c.PyErr_Format(c.PyExc_TypeError, "a coroutine was expected, got %R", coro);
        return -1;
    }

    initFutureObject(&self.future, type_state, handle_obj, loop.loop_obj);
    self.future.native_kind = .task;
    self.future.log_destroy_pending = true;
    maybeInitSourceTraceback(&self.future, handle_obj) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return -1;
    };
    errdefer {
        _ = taskClear(self_obj);
    }

    const resolved_context = if (context_arg) |ctx|
        if (!isNone(ctx)) blk: {
            ffi.incref(ctx);
            break :blk ctx;
        } else currentContext() catch return -1
    else
        currentContext() catch return -1;
    defer ffi.decref(resolved_context);

    initTaskName(self, type_state, name_arg) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return -1;
    };

    self.task_token = newTask(handle_obj, loop.loop_obj, self_obj.?, coro, resolved_context, self.name, eager_start) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return -1;
    };
    if (self.name) |task_name| {
        ffi.decref(task_name);
        self.name = null;
    }
    return 0;
}

fn futureIterTypeNew(_: ?*c.PyTypeObject, _: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    c.PyErr_SetString(c.PyExc_TypeError, "future iterators are created internally");
    return null;
}

fn genericAliasMethod(self_obj: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
    return c.Py_GenericAlias(self_obj orelse return null, arg orelse return null);
}

fn futureAwait(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "missing future");
        return null;
    };
    const self = futureObjectFromPy(obj);
    const type_state = ensureFutureTypeState(self) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    const type_obj = type_state.future_iter_type orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "future iterator type is not initialized");
        return null;
    };
    const iter = allocHeapObject(FutureIterObject, type_obj) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    iter.future = obj;
    iter.yielded = false;
    ffi.incref(obj);
    return @ptrCast(iter);
}

fn futureIterSelf(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    ffi.incref(obj);
    return obj;
}

fn futureIterDealloc(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const self: *FutureIterObject = @ptrCast(@alignCast(obj));
    if (self.future) |future_obj| {
        ffi.decref(future_obj);
        self.future = null;
    }
    const tp: *c.PyTypeObject = @ptrCast(self.ob_base.ob_type);
    tp.tp_free.?(@ptrCast(self));
}

fn futureIterAdvance(self: *FutureIterObject, sent_value: ?*PyObject) ?*PyObject {
    const future_obj = self.future orelse return null;
    const future = futureObjectFromPy(future_obj);
    const core = futureCore(future) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    const done = core.state != .pending;
    if (!self.yielded and !done) {
        if (sent_value) |value| {
            if (!isNone(value)) {
                c.PyErr_SetString(c.PyExc_TypeError, "can't send non-None value to a just-started future iterator");
                return null;
            }
        }
        future.asyncio_future_blocking = true;
        self.yielded = true;
        ffi.incref(future_obj);
        return future_obj;
    }
    if (!done) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "await wasn't used with future");
        return null;
    }

    future.log_traceback = false;
    const result = if (core.state == .cancelled)
        raiseCancelledFromFuture(future)
    else
        futureResultObject(core) catch null;
    if (result == null) return null;
    const stop_exc = callCallableOneArg(c.PyExc_StopIteration, result.?) catch {
        ffi.decref(result.?);
        return null;
    };
    ffi.decref(result.?);
    c.PyErr_SetRaisedException(stop_exc);
    return null;
}

fn futureIterNext(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    const self: *FutureIterObject = @ptrCast(@alignCast(obj));
    return futureIterAdvance(self, ffi.getNone());
}

fn futureIterSendMethod(self_obj: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    const self: *FutureIterObject = @ptrCast(@alignCast(obj));
    return futureIterAdvance(self, arg orelse ffi.getNone());
}

fn futureIterThrowMethod(self_obj: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    _ = self_obj;
    const tuple = args orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "throw expected at least 1 argument, got 0");
        return null;
    };
    if (!ffi.isTuple(tuple)) {
        c.PyErr_SetString(c.PyExc_TypeError, "throw arguments must be a tuple");
        return null;
    }

    const nargs = ffi.tupleSize(tuple);
    if (nargs < 1 or nargs > 3) {
        c.PyErr_SetString(c.PyExc_TypeError, "throw expected 1 to 3 arguments");
        return null;
    }

    const typ = ffi.tupleGetItem(tuple, 0) orelse return null;
    const val = if (nargs >= 2) ffi.tupleGetItem(tuple, 1) else null;
    const tb = if (nargs >= 3) ffi.tupleGetItem(tuple, 2) else null;

    if (nargs == 3) {
        if (c.PyErr_WarnEx(c.PyExc_DeprecationWarning, "the (type, exc, tb) signature of throw() is deprecated", 1) < 0) {
            return null;
        }
    }
    if (tb) |traceback| {
        if (!isNone(traceback) and c.PyTraceBack_Check(traceback) == 0) {
            c.PyErr_SetString(c.PyExc_TypeError, "throw() third argument must be a traceback object");
            return null;
        }
    }

    var raise_obj: ?*PyObject = null;
    if (c.PyExceptionInstance_Check(typ) != 0) {
        if (nargs != 1) {
            c.PyErr_SetString(c.PyExc_TypeError, "instance exception may not have a separate value");
            return null;
        }
        ffi.incref(typ);
        raise_obj = typ;
    } else if (c.PyExceptionClass_Check(typ)) {
        if (val) |exc_val| {
            if (isNone(exc_val)) {
                raise_obj = callCallableNoArgs(typ) catch return null;
            } else if (c.PyExceptionInstance_Check(exc_val) != 0) {
                ffi.incref(exc_val);
                raise_obj = exc_val;
            } else {
                raise_obj = callCallableOneArg(typ, exc_val) catch return null;
            }
        } else {
            raise_obj = callCallableNoArgs(typ) catch return null;
        }
    } else {
        c.PyErr_SetString(c.PyExc_TypeError, "exceptions must be classes or instances deriving from BaseException");
        return null;
    }
    const exc = raise_obj orelse return null;
    return raiseStoredException(exc, if (tb) |traceback| if (!isNone(traceback)) traceback else null else null) catch null;
}

fn tryFutureHandle(self: *FutureObject) *PyObject {
    return self.loop_handle orelse @panic("future loop handle missing");
}

fn futureRepr(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    _ = futureObjectFromPy(obj);
    const base_futures = importModuleRaw("asyncio.base_futures") catch return null;
    defer ffi.decref(base_futures);
    const repr_fn = getAttrRaw(base_futures, "_future_repr") catch return null;
    defer ffi.decref(repr_fn);
    return callCallableOneArg(repr_fn, obj) catch null;
}

fn taskRepr(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    _ = taskObjectFromPy(obj);
    const base_tasks = importModuleRaw("asyncio.base_tasks") catch return null;
    defer ffi.decref(base_tasks);
    const repr_fn = getAttrRaw(base_tasks, "_task_repr") catch return null;
    defer ffi.decref(repr_fn);
    return callCallableOneArg(repr_fn, obj) catch null;
}

fn futureGetLoopMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    const loop_obj = self.loop_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "Future object is not initialized.");
        return null;
    };
    ffi.incref(loop_obj);
    return loop_obj;
}

fn futureCancelMethod(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    self.log_traceback = false;
    if (self.loop_handle == null or !futureHasBacking(self)) {
        if (self.shadow_valid) return ffi.boolFromBool(false);
        c.PyErr_SetString(c.PyExc_RuntimeError, "Future object is not initialized.");
        return null;
    }
    const msg = parseOptionalMessageArg(args, kwargs) catch return null;
    const cancelled = switch (self.native_kind) {
        .task => taskCancel(tryFutureHandle(self), taskObjectFromFuture(self).task_token, msg),
        .future => futureCancel(tryFutureHandle(self), self.future_token, msg),
    } catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    return ffi.boolFromBool(cancelled);
}

fn futureMakeCancelledErrorMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    return takeCancelledError(self) catch null;
}

fn futureCancelledMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    const core = activeFutureCore(self) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    if (core) |active| return ffi.boolFromBool(active.state == .cancelled);
    if (self.shadow_valid) return ffi.boolFromBool(self.shadow_state == .cancelled);
    return ffi.boolFromBool(false);
}

fn futureDoneMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    const core = activeFutureCore(self) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    if (core) |active| return ffi.boolFromBool(active.state != .pending);
    if (self.shadow_valid) return ffi.boolFromBool(self.shadow_state != .pending);
    return ffi.boolFromBool(false);
}

fn futureResultMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    self.log_traceback = false;
    const core = activeFutureCore(self) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    if (core) |active| {
        if (active.state == .cancelled) return raiseCancelledFromFuture(self);
        return futureResultObject(active) catch null;
    }
    if (self.shadow_valid) return futureResultShadow(self) catch null;
    {
        const excs = importModuleRaw("asyncio.exceptions") catch return null;
        defer ffi.decref(excs);
        const invalid = getAttrRaw(excs, "InvalidStateError") catch return null;
        defer ffi.decref(invalid);
        c.PyErr_SetString(invalid, "Result is not set.");
        return null;
    }
}

fn futureExceptionMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    self.log_traceback = false;
    const core = activeFutureCore(self) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    if (core) |active| {
        if (active.state == .cancelled) return raiseCancelledFromFuture(self);
        return futureExceptionObject(active) catch null;
    }
    if (self.shadow_valid) return futureExceptionShadow(self) catch null;
    {
        const excs = importModuleRaw("asyncio.exceptions") catch return null;
        defer ffi.decref(excs);
        const invalid = getAttrRaw(excs, "InvalidStateError") catch return null;
        defer ffi.decref(invalid);
        c.PyErr_SetString(invalid, "Exception is not set.");
        return null;
    }
}

fn futureAddDoneCallbackMethod(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    const self = futureObjectFromPy(obj);
    if (self.loop_handle == null or !futureHasBacking(self)) {
        if (self.shadow_valid) return ffi.getNone();
        c.PyErr_SetString(c.PyExc_RuntimeError, "Future object is not initialized.");
        return null;
    }
    const tuple = args orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "add_done_callback() missing callback");
        return null;
    };
    if (!ffi.isTuple(tuple)) {
        c.PyErr_SetString(c.PyExc_TypeError, "add_done_callback() arguments must be a tuple");
        return null;
    }
    const nargs = ffi.tupleSize(tuple);
    if (nargs < 1 or nargs > 2) {
        c.PyErr_SetString(c.PyExc_TypeError, "add_done_callback() expects callback and optional context");
        return null;
    }
    const callback = ffi.tupleGetItem(tuple, 0) orelse return null;

    var context: ?*PyObject = if (nargs == 2) ffi.tupleGetItem(tuple, 1) else null;
    if (kwargs) |kw| {
        if (!ffi.isDict(kw)) {
            c.PyErr_SetString(c.PyExc_TypeError, "kwargs must be a dict");
            return null;
        }
        const kw_context = ffi.dictGetItemString(kw, "context");
        const allowed: isize = if (kw_context != null) 1 else 0;
        if (ffi.dictSize(kw) != allowed) {
            c.PyErr_SetString(c.PyExc_TypeError, "unexpected keyword argument");
            return null;
        }
        if (kw_context != null) {
            if (context != null) {
                c.PyErr_SetString(c.PyExc_TypeError, "context specified twice");
                return null;
            }
            context = kw_context;
        }
    }

    const resolved_context = if (context) |ctx|
        if (!isNone(ctx)) blk: {
            ffi.incref(ctx);
            break :blk ctx;
        } else currentContext() catch return null
    else
        currentContext() catch return null;
    defer ffi.decref(resolved_context);

    const slot = slotFromCapsule(tryFutureHandle(self)) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    const core = futureCore(self) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    addFutureDoneCallbackCore(slot, core, obj, callback, resolved_context) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    return ffi.getNone();
}

fn futureRemoveDoneCallbackMethod(self_obj: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    if (self.loop_handle == null or !futureHasBacking(self)) {
        if (self.shadow_valid) return ffi.longFromLong(0) catch null;
        c.PyErr_SetString(c.PyExc_RuntimeError, "Future object is not initialized.");
        return null;
    }
    const callback = arg orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "remove_done_callback() missing callback");
        return null;
    };
    const slot = slotFromCapsule(tryFutureHandle(self)) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    const core = futureCore(self) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    const removed = removeFutureDoneCallbackCore(slot, core, callback) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    return ffi.longFromLong(@intCast(removed)) catch null;
}

fn futureSetResultMethod(self_obj: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    const result = arg orelse return ffi.getNone();
    if (self.loop_handle == null or !futureHasBacking(self)) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "Future object is not initialized.");
        return null;
    }
    switch (self.native_kind) {
        .future => futureSetResult(tryFutureHandle(self), self.future_token, result) catch |err| {
            if (!ffi.errOccurred()) switch (err) {
                error.InvalidState => _ = raiseAsyncioInvalidStateError("invalid state") catch {},
                else => c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err)),
            };
            return null;
        },
        .task => {
            const slot = slotFromCapsule(tryFutureHandle(self)) catch |err| {
                if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
                return null;
            };
            const task = taskNative(taskObjectFromFuture(self)) catch |err| {
                if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
                return null;
            };
            setFutureResultCore(slot, &task.core, result) catch |err| {
                if (!ffi.errOccurred()) switch (err) {
                    error.InvalidState => _ = raiseAsyncioInvalidStateError("invalid state") catch {},
                    else => c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err)),
                };
                return null;
            };
        },
    }
    return ffi.getNone();
}

fn futureSetExceptionMethod(self_obj: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    var exc = arg orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "set_exception() missing exception");
        return null;
    };
    if (self.loop_handle == null or !futureHasBacking(self)) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "Future object is not initialized.");
        return null;
    }
    var owned_exc: ?*PyObject = null;
    defer if (owned_exc) |obj| ffi.decref(obj);
    if (c.PyType_Check(exc) != 0) {
        owned_exc = callCallableNoArgs(exc) catch return null;
        exc = owned_exc.?;
    }
    switch (self.native_kind) {
        .future => futureSetException(tryFutureHandle(self), self.future_token, exc) catch |err| {
            if (!ffi.errOccurred()) switch (err) {
                error.InvalidState => _ = raiseAsyncioInvalidStateError("invalid state") catch {},
                else => c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err)),
            };
            return null;
        },
        .task => {
            const slot = slotFromCapsule(tryFutureHandle(self)) catch |err| {
                if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
                return null;
            };
            const task = taskNative(taskObjectFromFuture(self)) catch |err| {
                if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
                return null;
            };
            setFutureExceptionCore(slot, &task.core, exc, null) catch |err| {
                if (!ffi.errOccurred()) switch (err) {
                    error.InvalidState => _ = raiseAsyncioInvalidStateError("invalid state") catch {},
                    else => c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err)),
                };
                return null;
            };
        },
    }
    return ffi.getNone();
}

fn taskGetCoroMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    return taskCoroGet(self_obj, null);
}

fn taskGetContextMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    return taskContextGet(self_obj, null);
}

fn taskGetNameMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    return taskNameGet(self_obj, null);
}

fn taskSetNameMethod(self_obj: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
    if (taskNameSet(self_obj, arg, null) != 0) return null;
    return ffi.getNone();
}

fn taskSetResultMethod(_: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    c.PyErr_SetString(c.PyExc_RuntimeError, "Task does not support set_result operation");
    return null;
}

fn taskSetExceptionMethod(_: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    c.PyErr_SetString(c.PyExc_RuntimeError, "Task does not support set_exception operation");
    return null;
}

fn taskCancelMethod(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) ?*PyObject {
    const self = taskObjectFromPy(self_obj orelse return null);
    const msg = parseOptionalMessageArg(args, kwargs) catch return null;
    if ((activeFutureCore(&self.future) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    }) == null) {
        return ffi.boolFromBool(false);
    }
    const cancelled = taskCancel(tryFutureHandle(&self.future), self.task_token, msg) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    return ffi.boolFromBool(cancelled);
}

fn taskCancellingMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self = taskObjectFromPy(self_obj orelse return null);
    if ((activeFutureCore(&self.future) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    }) == null) {
        return ffi.longFromLong(0) catch null;
    }
    const count = taskCancelling(tryFutureHandle(&self.future), self.task_token) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    return ffi.longFromLong(@intCast(count)) catch null;
}

fn taskUncancelMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self = taskObjectFromPy(self_obj orelse return null);
    if ((activeFutureCore(&self.future) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    }) == null) {
        return ffi.longFromLong(0) catch null;
    }
    const count = taskUncancel(tryFutureHandle(&self.future), self.task_token) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return null;
    };
    return ffi.longFromLong(@intCast(count)) catch null;
}

fn taskGetStackMethod(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) ?*PyObject {
    _ = taskObjectFromPy(self_obj orelse return null);
    const limit = parseLimit(args, kwargs) catch return null;
    const base_tasks = importModuleRaw("asyncio.base_tasks") catch return null;
    defer ffi.decref(base_tasks);
    const get_stack_fn = getAttrRaw(base_tasks, "_task_get_stack") catch return null;
    defer ffi.decref(get_stack_fn);

    const call_args = ffi.tupleNew(2) catch return null;
    errdefer ffi.decref(call_args);
    ffi.tupleSetItemTake(call_args, 0, ffi.OwnedPy.increfBorrowed(self_obj.?)) catch return null;
    const limit_owned = if (limit) |n|
        ffi.OwnedPy.init(ffi.longFromLong(n) catch return null)
    else
        ffi.OwnedPy.init(ffi.getNone());
    ffi.tupleSetItemTake(call_args, 1, limit_owned) catch return null;

    const result = callObjectRaw(get_stack_fn, call_args) catch return null;
    ffi.decref(call_args);
    return result;
}

fn taskPrintStackMethod(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) ?*PyObject {
    _ = taskObjectFromPy(self_obj orelse return null);
    var file_obj: ?*PyObject = null;
    const limit = parseLimitAndFile(args, kwargs, &file_obj) catch return null;
    const base_tasks = importModuleRaw("asyncio.base_tasks") catch return null;
    defer ffi.decref(base_tasks);
    const print_stack_fn = getAttrRaw(base_tasks, "_task_print_stack") catch return null;
    defer ffi.decref(print_stack_fn);

    const call_args = ffi.tupleNew(3) catch return null;
    errdefer ffi.decref(call_args);
    ffi.tupleSetItemTake(call_args, 0, ffi.OwnedPy.increfBorrowed(self_obj.?)) catch return null;
    const limit_owned = if (limit) |n|
        ffi.OwnedPy.init(ffi.longFromLong(n) catch return null)
    else
        ffi.OwnedPy.init(ffi.getNone());
    ffi.tupleSetItemTake(call_args, 1, limit_owned) catch return null;
    const file_owned = if (file_obj) |obj|
        ffi.OwnedPy.increfBorrowed(obj)
    else
        ffi.OwnedPy.init(ffi.getNone());
    ffi.tupleSetItemTake(call_args, 2, file_owned) catch return null;

    const result = callObjectRaw(print_stack_fn, call_args) catch return null;
    ffi.decref(call_args);
    ffi.decref(result);
    return ffi.getNone();
}

fn parseOptionalMessageArg(args: ?*PyObject, kwargs: ?*PyObject) LoopError!?*PyObject {
    var msg: ?*PyObject = null;
    if (args) |tuple| {
        if (!ffi.isTuple(tuple)) {
            c.PyErr_SetString(c.PyExc_TypeError, "cancel() expects at most one argument");
            return error.PythonError;
        }
        const nargs = ffi.tupleSize(tuple);
        if (nargs > 1) {
            c.PyErr_SetString(c.PyExc_TypeError, "cancel() expects at most one argument");
            return error.PythonError;
        }
        if (nargs == 1) msg = ffi.tupleGetItem(tuple, 0);
    }
    if (kwargs) |kw| {
        if (!ffi.isDict(kw)) {
            c.PyErr_SetString(c.PyExc_TypeError, "kwargs must be a dict");
            return error.PythonError;
        }
        const kw_msg = ffi.dictGetItemString(kw, "msg");
        const allowed: isize = if (kw_msg != null) 1 else 0;
        if (ffi.dictSize(kw) != allowed) {
            c.PyErr_SetString(c.PyExc_TypeError, "unexpected keyword argument");
            return error.PythonError;
        }
        if (kw_msg != null) {
            if (msg != null) {
                c.PyErr_SetString(c.PyExc_TypeError, "msg specified twice");
                return error.PythonError;
            }
            msg = kw_msg;
        }
    }
    return msg;
}

fn takeCancelledError(self: *FutureObject) LoopError!*PyObject {
    if (self.cancelled_exc) |exc| {
        self.cancelled_exc = null;
        return exc;
    }
    if (try activeFutureCore(self)) |core| {
        return makeCancelledError(core.cancel_message);
    }
    if (self.shadow_valid and self.shadow_state == .cancelled) {
        return makeCancelledError(self.shadow_cancel_message);
    }
    return makeCancelledError(null);
}

fn getExceptionTraceback(exc: *PyObject) ?*PyObject {
    const tb = getAttrRaw(exc, "__traceback__") catch {
        if (ffi.errOccurred()) ffi.errClear();
        return null;
    };
    if (isNone(tb)) {
        ffi.decref(tb);
        return null;
    }
    return tb;
}

fn raiseCancelledFromFuture(self: *FutureObject) ?*PyObject {
    if (self.cancelled_exc) |exc| {
        ffi.incref(exc);
        const tb = getExceptionTraceback(exc);
        defer if (tb) |obj| ffi.decref(obj);
        return raiseStoredException(exc, tb) catch null;
    }
    if (activeFutureCore(self) catch null) |core| {
        const cancelled = makeCancelledError(core.cancel_message) catch return null;
        return raiseStoredException(cancelled, null) catch null;
    }
    if (self.shadow_valid and self.shadow_state == .cancelled) {
        const cancelled = makeCancelledError(self.shadow_cancel_message) catch return null;
        return raiseStoredException(cancelled, null) catch null;
    }
    const cancelled = makeCancelledError(null) catch return null;
    return raiseStoredException(cancelled, null) catch null;
}

fn futureBlockingGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    return ffi.boolFromBool(self.asyncio_future_blocking);
}

fn futureBlockingSet(self_obj: ?*PyObject, value: ?*PyObject, _: ?*anyopaque) callconv(.c) c_int {
    const self = futureObjectFromPy(self_obj orelse return -1);
    const obj = value orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "cannot delete _asyncio_future_blocking");
        return -1;
    };
    const truth = c.PyObject_IsTrue(obj);
    if (truth < 0) return -1;
    self.asyncio_future_blocking = truth == 1;
    return 0;
}

fn futureLoopAttrGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    return futureGetLoopMethod(self_obj, null);
}

fn futureStateGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    const maybe_core = activeFutureCore(self) catch return ffi.unicodeFromString("PENDING") catch null;
    const state_value = if (maybe_core) |core| core.state else if (self.shadow_valid) self.shadow_state else .pending;
    const state: [*:0]const u8 = switch (state_value) {
        .pending => "PENDING",
        .cancelled => "CANCELLED",
        .finished => "FINISHED",
    };
    return ffi.unicodeFromString(state) catch null;
}

fn futureResultAttrGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    const maybe_core = activeFutureCore(self) catch return ffi.getNone();
    if (maybe_core) |core| {
        if (core.state != .finished or core.exception != null) return ffi.getNone();
        if (core.result) |obj| {
            ffi.incref(obj);
            return obj;
        }
        return ffi.getNone();
    }
    if (!self.shadow_valid or self.shadow_state != .finished or self.shadow_exception != null) return ffi.getNone();
    if (self.shadow_result) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return ffi.getNone();
}

fn futureExceptionAttrGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    const maybe_core = activeFutureCore(self) catch return ffi.getNone();
    if (maybe_core) |core| {
        if (core.exception) |obj| {
            ffi.incref(obj);
            return obj;
        }
        return ffi.getNone();
    }
    if (self.shadow_exception) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return ffi.getNone();
}

fn futureCallbacksGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    const core = futureCore(self) catch return ffi.listNew(0) catch null;
    const slot = slotFromCapsule(tryFutureHandle(self)) catch return ffi.listNew(0) catch null;
    const list = ffi.listNew(0) catch return null;
    errdefer ffi.decref(list);
    var cb_id = core.callbacks_head;
    while (cb_id != invalid_callback_id) {
        const entry = &slot.future_callbacks[cb_id];
        if (entry.callback) |callback| {
            const pair = ffi.tupleNew(2) catch return null;
            errdefer ffi.decref(pair);
            ffi.tupleSetItemTake(pair, 0, ffi.OwnedPy.increfBorrowed(callback)) catch return null;
            if (entry.context) |ctx| {
                ffi.tupleSetItemTake(pair, 1, ffi.OwnedPy.increfBorrowed(ctx)) catch return null;
            } else {
                ffi.tupleSetItemTake(pair, 1, ffi.OwnedPy.init(ffi.getNone())) catch return null;
            }
            ffi.listAppend(list, pair) catch return null;
            ffi.decref(pair);
        }
        cb_id = entry.next;
    }
    return list;
}

fn futureSourceTracebackGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    if (self.source_traceback) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return ffi.getNone();
}

fn futureLogDestroyPendingGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    return ffi.boolFromBool(self.log_destroy_pending);
}

fn futureLogDestroyPendingSet(self_obj: ?*PyObject, value: ?*PyObject, _: ?*anyopaque) callconv(.c) c_int {
    const self = futureObjectFromPy(self_obj orelse return -1);
    const obj = value orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "cannot delete _log_destroy_pending");
        return -1;
    };
    const truth = c.PyObject_IsTrue(obj);
    if (truth < 0) return -1;
    self.log_destroy_pending = truth == 1;
    return 0;
}

fn futureLogTracebackGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    return ffi.boolFromBool(self.log_traceback);
}

fn futureLogTracebackSet(self_obj: ?*PyObject, value: ?*PyObject, _: ?*anyopaque) callconv(.c) c_int {
    const self = futureObjectFromPy(self_obj orelse return -1);
    const obj = value orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "cannot delete _log_traceback");
        return -1;
    };
    const truth = c.PyObject_IsTrue(obj);
    if (truth < 0) return -1;
    if (truth == 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "_log_traceback can only be set to False");
        return -1;
    }
    self.log_traceback = false;
    return 0;
}

fn futureCancelMessageGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = futureObjectFromPy(self_obj orelse return null);
    if (activeFutureCore(self) catch null) |core| {
        if (core.cancel_message) |obj| {
            ffi.incref(obj);
            return obj;
        }
        return ffi.getNone();
    }
    if (self.shadow_cancel_message) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return ffi.getNone();
}

fn replaceOptionalPyRef(dst: *?*PyObject, value: ?*PyObject) void {
    if (dst.*) |old| ffi.decref(old);
    dst.* = null;
    if (value) |obj| {
        if (!isNone(obj)) {
            dst.* = obj;
            ffi.incref(obj);
        }
    }
}

fn futureCancelMessageSet(self_obj: ?*PyObject, value: ?*PyObject, _: ?*anyopaque) callconv(.c) c_int {
    const self = futureObjectFromPy(self_obj orelse return -1);
    const core = futureCore(self) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return -1;
    };
    replaceOptionalPyRef(&core.cancel_message, value);
    return 0;
}

fn taskCoroGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = taskObjectFromPy(self_obj orelse return null);
    if (self.coro) |obj| {
        ffi.incref(obj);
        return obj;
    }
    if (taskNative(self)) |task| {
        if (task.coro) |obj| {
            ffi.incref(obj);
            return obj;
        }
    } else |_| {}
    return ffi.getNone();
}

fn taskContextGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = taskObjectFromPy(self_obj orelse return null);
    if (self.context) |obj| {
        ffi.incref(obj);
        return obj;
    }
    if (taskNative(self)) |task| {
        if (task.context) |obj| {
            ffi.incref(obj);
            return obj;
        }
    } else |_| {}
    return ffi.getNone();
}

fn taskNameGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = taskObjectFromPy(self_obj orelse return null);
    if (self.name == null and self.auto_name_seq != 0) {
        const auto_name = autoTaskName(self.auto_name_seq) catch return null;
        defer ffi.decref(auto_name);
        setTaskName(self, auto_name) catch |err| {
            if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
            return null;
        };
    }
    if (self.name) |obj| {
        ffi.incref(obj);
        return obj;
    }
    if (taskNative(self)) |task| {
        if (task.name) |obj| {
            ffi.incref(obj);
            return obj;
        }
    } else |_| {}
    return ffi.getNone();
}

fn taskNameSet(self_obj: ?*PyObject, value: ?*PyObject, _: ?*anyopaque) callconv(.c) c_int {
    const self = taskObjectFromPy(self_obj orelse return -1);
    const obj = value orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "cannot delete _name");
        return -1;
    };
    setTaskName(self, obj) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return -1;
    };
    return 0;
}

fn taskMustCancelGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = taskObjectFromPy(self_obj orelse return null);
    const task = taskNative(self) catch return ffi.boolFromBool(false);
    return ffi.boolFromBool(task.must_cancel);
}

fn taskFutWaiterGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = taskObjectFromPy(self_obj orelse return null);
    const task = taskNative(self) catch return ffi.getNone();
    if (task.fut_waiter) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return ffi.getNone();
}

fn taskNumCancelsRequestedGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = taskObjectFromPy(self_obj orelse return null);
    const task = taskNative(self) catch return ffi.longFromLong(0) catch null;
    return ffi.longFromLong(@intCast(task.num_cancels_requested)) catch null;
}

fn taskCancelMessageGet(self_obj: ?*PyObject, _: ?*anyopaque) callconv(.c) ?*PyObject {
    const self = taskObjectFromPy(self_obj orelse return null);
    if (activeFutureCore(&self.future) catch null) |core| {
        if (core.cancel_message) |obj| {
            ffi.incref(obj);
            return obj;
        }
        return ffi.getNone();
    }
    if (self.future.shadow_cancel_message) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return ffi.getNone();
}

fn taskCancelMessageSet(self_obj: ?*PyObject, value: ?*PyObject, _: ?*anyopaque) callconv(.c) c_int {
    const self = taskObjectFromPy(self_obj orelse return -1);
    const core = futureCore(&self.future) catch |err| {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
        return -1;
    };
    replaceOptionalPyRef(&core.cancel_message, value);
    return 0;
}

fn initTaskName(self: *TaskObject, type_state: *TypeState, value: ?*PyObject) LoopError!void {
    if (value) |obj| {
        if (!isNone(obj)) {
            try setTaskName(self, obj);
            return;
        }
    }
    self.auto_name_seq = nextAutoTaskNameSeq(type_state);
}

fn setTaskName(self: *TaskObject, value: *PyObject) LoopError!void {
    const name = blk: {
        if (ffi.isString(value)) {
            ffi.incref(value);
            break :blk value;
        }
        break :blk try ffi.objectStr(value);
    };
    errdefer ffi.decref(name);
    self.auto_name_seq = 0;
    if (taskNative(self)) |task| {
        if (task.name) |old| ffi.decref(old);
        task.name = name;
        if (self.name) |old| {
            ffi.decref(old);
            self.name = null;
        }
    } else |err| switch (err) {
        error.InvalidState, error.InvalidLoopHandle => {
            if (self.name) |old| ffi.decref(old);
            self.name = name;
        },
        else => return err,
    }
}

fn taskFrame(self: *TaskObject) LoopError!?*PyObject {
    const coro = self.coro orelse blk: {
        if (taskNative(self)) |task| {
            if (task.coro) |obj| break :blk obj;
        } else |_| {}
        return null;
    };

    var frame = getAttrRaw(coro, "cr_frame") catch null;
    if (frame) |obj| {
        if (!isNone(obj)) return obj;
        ffi.decref(obj);
    } else if (ffi.errOccurred()) ffi.errClear();

    frame = getAttrRaw(coro, "gi_frame") catch null;
    if (frame) |obj| {
        if (!isNone(obj)) return obj;
        ffi.decref(obj);
    } else if (ffi.errOccurred()) ffi.errClear();
    return null;
}

fn parseLimit(args: ?*PyObject, kwargs: ?*PyObject) LoopError!?c_long {
    var limit_obj: ?*PyObject = null;
    if (args) |tuple| {
        if (!ffi.isTuple(tuple)) {
            c.PyErr_SetString(c.PyExc_TypeError, "arguments must be a tuple");
            return error.PythonError;
        }
        const nargs = ffi.tupleSize(tuple);
        if (nargs > 1) {
            c.PyErr_SetString(c.PyExc_TypeError, "expected at most one argument");
            return error.PythonError;
        }
        if (nargs == 1) limit_obj = ffi.tupleGetItem(tuple, 0);
    }
    if (kwargs) |kw| {
        const kw_limit = ffi.dictGetItemString(kw, "limit");
        const allowed: isize = if (kw_limit != null) 1 else 0;
        if (ffi.dictSize(kw) != allowed) {
            c.PyErr_SetString(c.PyExc_TypeError, "unexpected keyword argument");
            return error.PythonError;
        }
        if (kw_limit != null) {
            if (limit_obj != null) {
                c.PyErr_SetString(c.PyExc_TypeError, "limit specified twice");
                return error.PythonError;
            }
            limit_obj = kw_limit;
        }
    }
    if (limit_obj == null or isNone(limit_obj.?)) return null;
    return ffi.longAsLong(limit_obj.?) catch error.PythonError;
}

fn parseLimitAndFile(args: ?*PyObject, kwargs: ?*PyObject, file_obj: *?*PyObject) LoopError!?c_long {
    file_obj.* = null;
    var limit_obj: ?*PyObject = null;
    if (args) |tuple| {
        if (!ffi.isTuple(tuple)) {
            c.PyErr_SetString(c.PyExc_TypeError, "arguments must be a tuple");
            return error.PythonError;
        }
        const nargs = ffi.tupleSize(tuple);
        if (nargs > 2) {
            c.PyErr_SetString(c.PyExc_TypeError, "expected at most two arguments");
            return error.PythonError;
        }
        if (nargs >= 1) limit_obj = ffi.tupleGetItem(tuple, 0);
        if (nargs == 2) file_obj.* = ffi.tupleGetItem(tuple, 1);
    }
    if (kwargs) |kw| {
        const kw_limit = ffi.dictGetItemString(kw, "limit");
        const kw_file = ffi.dictGetItemString(kw, "file");
        var allowed: isize = 0;
        if (kw_limit != null) allowed += 1;
        if (kw_file != null) allowed += 1;
        if (ffi.dictSize(kw) != allowed) {
            c.PyErr_SetString(c.PyExc_TypeError, "unexpected keyword argument");
            return error.PythonError;
        }
        if (kw_limit != null) {
            if (limit_obj != null) {
                c.PyErr_SetString(c.PyExc_TypeError, "limit specified twice");
                return error.PythonError;
            }
            limit_obj = kw_limit;
        }
        if (kw_file != null) {
            if (file_obj.* != null) {
                c.PyErr_SetString(c.PyExc_TypeError, "file specified twice");
                return error.PythonError;
            }
            file_obj.* = kw_file;
        }
    }
    if (limit_obj == null or isNone(limit_obj.?)) return null;
    return ffi.longAsLong(limit_obj.?) catch error.PythonError;
}

pub fn initSlots(slots: *[MAX_LOOPS]LoopSlot) void {
    for (slots) |*slot| {
        slot.* = .{};
        initHandlePool(slot);
        initFuturePools(slot);
    }
}

pub fn clearAllSlots(slots: *[MAX_LOOPS]LoopSlot) void {
    for (slots) |*slot| clearSlot(slot, true);
}

pub fn traverseReadyCallbacks(slots: *[MAX_LOOPS]LoopSlot, visit: c.visitproc, arg: ?*anyopaque) c_int {
    for (slots) |*slot| {
        for (&slot.future_callbacks) |*entry| {
            if (!entry.used or !entry.ready) continue;
            if (visitPyObj(visit, arg, entry.callback) != 0) return -1;
            if (visitPyObj(visit, arg, entry.context) != 0) return -1;
            if (visitPyObj(visit, arg, entry.arg) != 0) return -1;
            if (visitPyObj(visit, arg, entry.loop_obj) != 0) return -1;
        }
        var n: usize = 0;
        while (n < slot.host_yield_count) : (n += 1) {
            const idx = (slot.host_yield_head + n) % MAX_HOST_YIELDS;
            if (visitPyObj(visit, arg, slot.host_yields[idx].sentinel) != 0) return -1;
        }
    }
    return 0;
}

pub fn newLoop(slots: *[MAX_LOOPS]LoopSlot, type_state: *TypeState) LoopError!*PyObject {
    for (slots) |*slot| {
        if (slot.used) continue;
        var generation = slot.generation;
        if (generation == 0) generation = 1;
        slot.* = .{};
        slot.generation = generation;
        slot.type_state = type_state;
        initHandlePool(slot);
        initFuturePools(slot);
        slot.used = true;
        slot.start_ns = @intCast(std.time.nanoTimestamp());
        const handle_state = std.heap.c_allocator.create(LoopHandleState) catch return error.OutOfMemory;
        errdefer std.heap.c_allocator.destroy(handle_state);
        handle_state.* = .{ .slot = slot, .generation = slot.generation };
        return c.PyCapsule_New(handle_state, loop_capsule_name, &destroyLoopCapsule) orelse error.PythonError;
    }
    return error.TooManyLoops;
}

pub fn freeLoop(handle_obj: *PyObject) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.running) return error.LoopRunning;
    var generation = slot.generation +% 1;
    if (generation == 0) generation = 1;
    slot.generation = generation;
    clearSlot(slot, true);
}

pub fn isClosed(handle_obj: *PyObject) LoopError!bool {
    return (try slotFromCapsule(handle_obj)).closed;
}

pub fn isRunning(handle_obj: *PyObject) LoopError!bool {
    return (try slotFromCapsule(handle_obj)).running;
}

pub fn currentTask(handle_obj: *PyObject) LoopError!?*PyObject {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.current_task) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return null;
}

pub fn taskSetRequestConn(self_obj: *PyObject, conn_idx: u16) LoopError!void {
    const self = taskObjectFromPy(self_obj);
    const task = try taskNative(self);
    task.request_conn_idx = conn_idx;
}

pub fn taskResumeValue(handle_obj: *PyObject, task_token: TaskToken, value: *PyObject) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    const task_id = try taskIdFromToken(slot, task_token);
    const task = &slot.tasks[task_id];
    if (task.step_value) |old| ffi.decref(old);
    task.step_value = value;
    ffi.incref(value);
    try scheduleTaskStep(slot, task_id, null);
}

pub fn taskResumeRuntimeError(handle_obj: *PyObject, task_token: TaskToken, msg: [*:0]const u8) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    const task_id = try taskIdFromToken(slot, task_token);
    const exc = try runtimeError(msg);
    defer ffi.decref(exc);
    try scheduleTaskStep(slot, task_id, exc);
}

pub fn peekHostYield(handle_obj: *PyObject) LoopError!?HostYieldRequest {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.host_yield_count == 0) return null;
    const host_yield = &slot.host_yields[slot.host_yield_head];
    return .{
        .kind = host_yield.kind,
        .task_token = host_yield.task_token,
        .conn_idx = host_yield.conn_idx,
        .sentinel = host_yield.sentinel orelse return error.InvalidState,
    };
}

pub fn dropHostYield(handle_obj: *PyObject) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.host_yield_count == 0) return;
    const idx = slot.host_yield_head;
    if (slot.host_yields[idx].sentinel) |sentinel| ffi.decref(sentinel);
    slot.host_yields[idx] = .{};
    slot.host_yield_head = (slot.host_yield_head + 1) % MAX_HOST_YIELDS;
    slot.host_yield_count -= 1;
}

pub fn driveNonblocking(handle_obj: *PyObject, loop_obj: *PyObject, budget: usize) LoopError!DriveResult {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.closed) return error.LoopClosed;
    if (slot.running) return error.EventLoopAlreadyRunning;

    const old_loop = try getRunningLoop();
    defer ffi.decref(old_loop);
    if (!isNone(old_loop) and old_loop != loop_obj) return error.AnotherLoopRunning;

    const old_depth = try getCoroutineOriginTrackingDepth();
    if (slot.debug and old_depth <= 0) {
        try setCoroutineOriginTrackingDepth(1);
    }

    slot.running = true;
    try setRunningLoop(loop_obj);
    defer {
        const had_err = ffi.errOccurred();
        const saved_err = if (had_err) fetchPyError() else SavedPyError{};
        defer if (had_err) restorePyError(saved_err);

        slot.running = false;
        setRunningLoop(old_loop) catch {
            if (ffi.errOccurred()) ffi.errClear();
        };
        if (slot.debug and old_depth <= 0) {
            setCoroutineOriginTrackingDepth(old_depth) catch {
                if (ffi.errOccurred()) ffi.errClear();
            };
        }
    }

    var ran: usize = 0;
    while (ran < budget) {
        _ = try drainScheduled(slot, slotTime(slot));
        if (slot.ready_len == 0) break;

        const idx = slot.ready_head;
        const token = slot.ready[idx];
        slot.ready[idx] = invalid_ready_token;
        slot.ready_head = (slot.ready_head + 1) % MAX_READY;
        slot.ready_len -= 1;
        try runReadyToken(slot, token);
        ran += 1;
    }

    if (slot.ready_len == 0) {
        slot.ready_head = 0;
    }

    const next_timer_ns = try nextScheduledDelayNs(slot, slotTime(slot));
    return .{
        .ran = ran,
        .ready_remaining = slot.ready_len,
        .next_timer_ns = next_timer_ns,
    };
}

pub fn allTasks(handle_obj: *PyObject) LoopError!*PyObject {
    const slot = try slotFromCapsule(handle_obj);
    const result = c.PySet_New(null) orelse return error.PythonError;
    errdefer ffi.decref(result);
    for (&slot.tasks) |*task| {
        if (!task.used) continue;
        if (task.core.state != .pending) continue;
        const wrapper = task.core.wrapper orelse continue;
        if (c.PySet_Add(result, wrapper) != 0) return error.PythonError;
    }
    return result;
}

pub fn closeLoop(handle_obj: *PyObject) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.closed) return;
    if (slot.running) return error.LoopRunning;
    clearLoopQueues(slot);
    clearFutureTaskPools(slot);
    slot.closed = true;
    slot.stopping = false;
}

pub fn stopLoop(handle_obj: *PyObject) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    slot.stopping = true;
}

pub fn loopTime(handle_obj: *PyObject) LoopError!f64 {
    const slot = try slotFromCapsule(handle_obj);
    return slotTime(slot);
}

pub fn setDebug(handle_obj: *PyObject, enabled: bool) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    slot.debug = enabled;
}

pub fn getDebug(handle_obj: *PyObject) LoopError!bool {
    return (try slotFromCapsule(handle_obj)).debug;
}

pub fn readyCount(handle_obj: *PyObject) LoopError!usize {
    return (try slotFromCapsule(handle_obj)).ready_len;
}

pub fn callSoon(
    handle_obj: *PyObject,
    loop_obj: *PyObject,
    wrapper_obj: *PyObject,
    callback: *PyObject,
    call_args: *PyObject,
    context: ?*PyObject,
) LoopError!HandleToken {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.closed) return error.LoopClosed;
    const handle_id = try allocHandle(slot, loop_obj, wrapper_obj, callback, call_args, context, 0, false);
    errdefer finishHandle(slot, handle_id, true);
    try pushReadyHandle(slot, handle_id);
    return tokenForHandle(slot, handle_id);
}

pub fn callAt(
    handle_obj: *PyObject,
    loop_obj: *PyObject,
    when: f64,
    wrapper_obj: *PyObject,
    callback: *PyObject,
    call_args: *PyObject,
    context: ?*PyObject,
) LoopError!HandleToken {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.closed) return error.LoopClosed;
    const handle_id = try allocHandle(slot, loop_obj, wrapper_obj, callback, call_args, context, when, true);
    errdefer finishHandle(slot, handle_id, true);
    try pushScheduledHandle(slot, when, handle_id);
    return tokenForHandle(slot, handle_id);
}

pub fn cancelHandle(handle_obj: *PyObject, handle_token: HandleToken) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    const decoded = decodeHandleToken(handle_token);
    const handle_id = decoded.id;
    if (@as(usize, handle_id) >= MAX_HANDLES) return;
    const native = &slot.handles[handle_id];
    if (!native.used) return;
    if (native.generation != decoded.generation) return;
    cancelNativeHandle(slot, handle_id);
}

pub fn handleRepr(handle_obj: *PyObject, handle_token: HandleToken, debug: bool) LoopError!*PyObject {
    const slot = try slotFromCapsule(handle_obj);
    const decoded = decodeHandleToken(handle_token);
    const handle_id = decoded.id;
    if (@as(usize, handle_id) >= MAX_HANDLES) return ffi.getNone();
    const native = &slot.handles[handle_id];
    if (!native.used) return ffi.getNone();
    if (native.generation != decoded.generation) return ffi.getNone();
    const callback = native.callback orelse return ffi.getNone();
    const args = native.args orelse return ffi.getNone();
    return formatCallbackSource(callback, args, debug);
}

pub fn newFuture(handle_obj: *PyObject, loop_obj: *PyObject, wrapper_obj: *PyObject) LoopError!FutureToken {
    const slot = try slotFromCapsule(handle_obj);
    const future_id = try allocFuture(slot, loop_obj, wrapper_obj);
    return tokenForFuture(slot, future_id);
}

pub fn freeFuture(handle_obj: *PyObject, future_token: FutureToken) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    const decoded = decodeFutureToken(future_token);
    if (@as(usize, decoded.id) >= MAX_FUTURES) return;
    const future = &slot.futures[decoded.id];
    if (!future.used or future.generation != decoded.generation) return;
    releaseFuture(slot, decoded.id);
}

pub fn futureDone(handle_obj: *PyObject, future_token: FutureToken) LoopError!bool {
    const future = try futureFromToken(handle_obj, future_token);
    return future.core.state != .pending;
}

pub fn futureDonePy(self_obj: *PyObject) LoopError!bool {
    const core = try futureCore(futureObjectFromPy(self_obj));
    return core.state != .pending;
}

pub fn futureResultPy(self_obj: *PyObject) LoopError!*PyObject {
    const core = try futureCore(futureObjectFromPy(self_obj));
    return futureResultObject(core);
}

pub fn futureCancelledNative(handle_obj: *PyObject, future_token: FutureToken) LoopError!bool {
    const future = try futureFromToken(handle_obj, future_token);
    return future.core.state == .cancelled;
}

pub fn futureCancel(handle_obj: *PyObject, future_token: FutureToken, message: ?*PyObject) LoopError!bool {
    const slot = try slotFromCapsule(handle_obj);
    const future_id = futureIdFromToken(slot, future_token) catch |err| switch (err) {
        error.InvalidState => return false,
        else => return err,
    };
    return cancelFutureCore(slot, &slot.futures[future_id].core, message);
}

pub fn futureResult(handle_obj: *PyObject, future_token: FutureToken) LoopError!*PyObject {
    const future = try futureFromToken(handle_obj, future_token);
    return futureResultObject(&future.core);
}

pub fn futureException(handle_obj: *PyObject, future_token: FutureToken) LoopError!*PyObject {
    const future = try futureFromToken(handle_obj, future_token);
    return futureExceptionObject(&future.core);
}

pub fn futureAddDoneCallback(
    handle_obj: *PyObject,
    future_token: FutureToken,
    wrapper_obj: *PyObject,
    callback: *PyObject,
    context: ?*PyObject,
) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    const future_id = try futureIdFromToken(slot, future_token);
    try addFutureDoneCallbackCore(slot, &slot.futures[future_id].core, wrapper_obj, callback, context);
}

pub fn futureRemoveDoneCallback(
    handle_obj: *PyObject,
    future_token: FutureToken,
    callback: *PyObject,
) LoopError!u32 {
    const slot = try slotFromCapsule(handle_obj);
    const future_id = try futureIdFromToken(slot, future_token);
    return removeFutureDoneCallbackCore(slot, &slot.futures[future_id].core, callback);
}

pub fn futureSetResult(handle_obj: *PyObject, future_token: FutureToken, result: *PyObject) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    const future_id = try futureIdFromToken(slot, future_token);
    try setFutureResultCore(slot, &slot.futures[future_id].core, result);
}

pub fn futureSetException(handle_obj: *PyObject, future_token: FutureToken, exc: *PyObject) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    const future_id = try futureIdFromToken(slot, future_token);
    try setFutureExceptionCore(slot, &slot.futures[future_id].core, exc, null);
}

pub fn futureSetRuntimeError(handle_obj: *PyObject, future_token: FutureToken, msg: [*:0]const u8) LoopError!void {
    const exc = try runtimeError(msg);
    defer ffi.decref(exc);
    try futureSetException(handle_obj, future_token, exc);
}

pub fn gatherRegister(
    handle_obj: *PyObject,
    outer_obj: *PyObject,
    children_obj: *PyObject,
    return_exceptions: bool,
) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    const count = try sequenceLen(children_obj);
    const outer_core = try futureCore(futureObjectFromPy(outer_obj));
    const gather_id = try allocGather(slot, outer_obj, outer_core, children_obj, count, return_exceptions);
    errdefer releaseGather(slot, gather_id);

    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const child_obj = sequenceItemBorrowed(children_obj, idx) orelse return error.PythonError;
        const child_core = try futureCore(futureObjectFromPy(child_obj));
        if (child_core.state == .pending) {
            _ = try allocGatherLink(slot, gather_id, child_core, @intCast(idx));
        } else {
            try processGatherChildCompletion(slot, gather_id, child_core, @intCast(idx));
        }
    }
}

pub fn newTask(
    handle_obj: *PyObject,
    loop_obj: *PyObject,
    wrapper_obj: *PyObject,
    coro: *PyObject,
    context: ?*PyObject,
    name: ?*PyObject,
    eager_start: bool,
) LoopError!TaskToken {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.closed) return error.LoopClosed;
    const task_id = try allocTask(handle_obj, slot, loop_obj, wrapper_obj, coro, context, name, null);
    errdefer releaseTask(slot, task_id);
    if (eager_start and slot.running) {
        try runTaskStepById(slot, task_id);
        const task = &slot.tasks[task_id];
        if (task.used and task.core.state != .pending) {
            hideTaskCoro(task);
        }
    } else {
        try scheduleTaskStep(slot, task_id, null);
    }
    return tokenForTask(slot, task_id);
}

pub fn freeTask(handle_obj: *PyObject, task_token: TaskToken) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    const decoded = decodeTaskToken(task_token);
    if (@as(usize, decoded.id) >= MAX_TASKS) return;
    const task = &slot.tasks[decoded.id];
    if (!task.used or task.generation != decoded.generation) return;
    if (task.core.wrapper) |wrapper| {
        unregisterTask(wrapper) catch {
            if (ffi.errOccurred()) ffi.errClear();
        };
    }
    releaseTask(slot, decoded.id);
}

pub fn taskCancel(handle_obj: *PyObject, task_token: TaskToken, message: ?*PyObject) LoopError!bool {
    const slot = try slotFromCapsule(handle_obj);
    const task_id = taskIdFromToken(slot, task_token) catch |err| switch (err) {
        error.InvalidState => return false,
        else => return err,
    };
    return cancelTask(slot, task_id, message);
}

pub fn taskCancelling(handle_obj: *PyObject, task_token: TaskToken) LoopError!u32 {
    const task = taskFromToken(handle_obj, task_token) catch |err| switch (err) {
        error.InvalidState => return 0,
        else => return err,
    };
    return task.num_cancels_requested;
}

pub fn taskUncancel(handle_obj: *PyObject, task_token: TaskToken) LoopError!u32 {
    const task = taskFromToken(handle_obj, task_token) catch |err| switch (err) {
        error.InvalidState => return 0,
        else => return err,
    };
    if (task.num_cancels_requested > 0) {
        task.num_cancels_requested -= 1;
        if (task.num_cancels_requested == 0) task.must_cancel = false;
    }
    return task.num_cancels_requested;
}

pub fn runForever(handle_obj: *PyObject, loop_obj: *PyObject) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.closed) return error.LoopClosed;
    if (slot.running) return error.EventLoopAlreadyRunning;

    const old_loop = try getRunningLoop();
    defer ffi.decref(old_loop);
    if (!isNone(old_loop)) return error.AnotherLoopRunning;

    const old_depth = try getCoroutineOriginTrackingDepth();
    if (slot.debug and old_depth <= 0) {
        try setCoroutineOriginTrackingDepth(1);
    }

    slot.running = true;
    slot.stopping = false;
    try setRunningLoop(loop_obj);
    defer {
        const had_err = ffi.errOccurred();
        const saved_err = if (had_err) fetchPyError() else SavedPyError{};
        defer if (had_err) restorePyError(saved_err);

        slot.running = false;
        slot.stopping = false;
        setRunningLoop(old_loop) catch {
            if (ffi.errOccurred()) ffi.errClear();
        };
        if (slot.debug and old_depth <= 0) {
            setCoroutineOriginTrackingDepth(old_depth) catch {
                if (ffi.errOccurred()) ffi.errClear();
            };
        }
    }

    while (!slot.stopping) {
        try runOnce(slot);
    }
}

pub fn runUntilComplete(handle_obj: *PyObject, loop_obj: *PyObject, future_obj: *PyObject) LoopError!*PyObject {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.closed) return error.LoopClosed;

    const new_task = !(try isFutureObject(future_obj));
    const target = try ensureFuture(loop_obj, future_obj);
    defer ffi.decref(target);

    if (new_task) {
        const false_obj = ffi.boolFromBool(false);
        defer ffi.decref(false_obj);
        try setAttrRaw(target, "_log_destroy_pending", false_obj);
    }

    const stop_cb = c.PyCFunction_NewEx(&stop_done_callback_def, handle_obj, null) orelse
        return error.PythonError;
    defer ffi.decref(stop_cb);

    const add_res = try callMethodOneArg(target, "add_done_callback", stop_cb);
    ffi.decref(add_res);
    defer {
        const had_err = ffi.errOccurred();
        const saved_err = if (had_err) fetchPyError() else SavedPyError{};
        defer if (had_err) restorePyError(saved_err);

        const rm_res = callMethodOneArg(target, "remove_done_callback", stop_cb) catch blk: {
            if (ffi.errOccurred()) ffi.errClear();
            break :blk null;
        };
        if (rm_res) |obj| ffi.decref(obj);
        discardReadyCallback(slot, stop_cb);
    }

    runForever(handle_obj, loop_obj) catch |err| {
        const had_err = ffi.errOccurred();
        const saved_err = if (had_err) fetchPyError() else SavedPyError{};
        defer if (had_err) restorePyError(saved_err);

        if (!had_err and err == error.PythonError and (futureDoneObject(target) catch false)) {
            const exc_obj = callMethodNoArgs(target, "exception") catch blk: {
                if (ffi.errOccurred()) ffi.errClear();
                break :blk null;
            };
            if (exc_obj) |obj| {
                defer ffi.decref(obj);
                if (!isNone(obj)) {
                    _ = callMethodNoArgs(target, "result") catch |result_err| switch (result_err) {
                        error.PythonError => return error.PythonError,
                        else => return result_err,
                    };
                    return error.PythonError;
                }
            }
        }

        if (new_task and (futureDoneObject(target) catch false) and !(futureCancelledObject(target) catch false)) {
            const exc_obj = callMethodNoArgs(target, "exception") catch blk: {
                if (ffi.errOccurred()) ffi.errClear();
                break :blk null;
            };
            if (exc_obj) |obj| ffi.decref(obj);
        }
        return err;
    };

    if (!try futureDoneObject(target)) return error.EventLoopStoppedBeforeFutureCompleted;
    if (try futureCancelledObject(target)) {
        _ = callMethodNoArgs(target, "result") catch |err| switch (err) {
            error.PythonError => return error.PythonError,
            else => return err,
        };
        c.PyErr_SetString(c.PyExc_RuntimeError, "cancelled awaitable returned a result");
        return error.PythonError;
    }
    return callMethodNoArgs(target, "result");
}

fn slotFromCapsule(handle_obj: *PyObject) LoopError!*LoopSlot {
    const raw = c.PyCapsule_GetPointer(handle_obj, loop_capsule_name);
    if (raw == null) return error.InvalidLoopHandle;
    const handle_state: *LoopHandleState = @ptrCast(@alignCast(raw));
    const slot = handle_state.slot;
    if (slot.generation != handle_state.generation) return error.InvalidLoopHandle;
    return slot;
}

fn initHandlePool(slot: *LoopSlot) void {
    slot.free_handle_len = MAX_HANDLES;
    for (0..MAX_HANDLES) |i| {
        slot.free_handles[i] = @intCast(MAX_HANDLES - 1 - i);
    }
}

fn initFuturePools(slot: *LoopSlot) void {
    slot.free_future_len = MAX_FUTURES;
    for (0..MAX_FUTURES) |i| {
        slot.free_futures[i] = @intCast(MAX_FUTURES - 1 - i);
    }

    slot.free_task_len = MAX_TASKS;
    for (0..MAX_TASKS) |i| {
        slot.free_tasks[i] = @intCast(MAX_TASKS - 1 - i);
    }

    slot.free_callback_len = MAX_FUTURE_CALLBACKS;
    for (0..MAX_FUTURE_CALLBACKS) |i| {
        slot.free_future_callbacks[i] = @intCast(MAX_FUTURE_CALLBACKS - 1 - i);
    }

    slot.free_gather_len = MAX_GATHERS;
    for (0..MAX_GATHERS) |i| {
        slot.free_gathers[i] = @intCast(MAX_GATHERS - 1 - i);
    }

    slot.free_gather_link_len = MAX_GATHER_LINKS;
    for (0..MAX_GATHER_LINKS) |i| {
        slot.free_gather_links[i] = @intCast(MAX_GATHER_LINKS - 1 - i);
    }
}

fn clearLoopQueues(slot: *LoopSlot) void {
    var n: usize = 0;
    while (n < MAX_HANDLES) : (n += 1) {
        if (!slot.handles[n].used) continue;
        finishHandle(slot, @intCast(n), true);
    }

    n = 0;
    while (n < slot.ready_len) : (n += 1) {
        const idx = (slot.ready_head + n) % MAX_READY;
        slot.ready[idx] = invalid_ready_token;
    }
    slot.ready_head = 0;
    slot.ready_len = 0;

    n = 0;
    while (n < slot.scheduled_len) : (n += 1) {
        slot.scheduled[n] = .{};
    }
    slot.scheduled_len = 0;

    n = 0;
    while (n < slot.host_yield_count) : (n += 1) {
        const idx = (slot.host_yield_head + n) % MAX_HOST_YIELDS;
        if (slot.host_yields[idx].sentinel) |sentinel| ffi.decref(sentinel);
        slot.host_yields[idx] = .{};
    }
    slot.host_yield_head = 0;
    slot.host_yield_count = 0;
}

fn clearFutureTaskPools(slot: *LoopSlot) void {
    for (0..MAX_GATHERS) |i| {
        if (slot.gathers[i].used) {
            releaseGather(slot, @intCast(i));
        }
    }
    for (0..MAX_TASKS) |i| {
        if (slot.tasks[i].used) {
            releaseTask(slot, @intCast(i));
        }
    }
    for (0..MAX_FUTURES) |i| {
        if (slot.futures[i].used) {
            releaseFuture(slot, @intCast(i));
        }
    }
    for (0..MAX_FUTURE_CALLBACKS) |i| {
        if (slot.future_callbacks[i].used) {
            freeFutureCallback(slot, @intCast(i));
        }
    }
    for (0..MAX_GATHER_LINKS) |i| {
        if (slot.gather_links[i].used) {
            freeGatherLink(slot, @intCast(i));
        }
    }
}

fn clearSlot(slot: *LoopSlot, free_slot: bool) void {
    clearLoopQueues(slot);
    clearFutureTaskPools(slot);
    if (slot.current_task) |obj| {
        ffi.decref(obj);
        slot.current_task = null;
    }
    const generation = slot.generation;
    slot.closed = free_slot;
    if (free_slot) {
        slot.* = .{};
        slot.generation = generation;
    }
}

fn slotTime(slot: *const LoopSlot) f64 {
    const now: i128 = std.time.nanoTimestamp();
    const elapsed = now - slot.start_ns;
    return @as(f64, @floatFromInt(elapsed)) / @as(f64, std.time.ns_per_s);
}

fn sleepWithGilReleased(ns: u64) void {
    if (ns == 0) return;
    const tstate = PyEval_SaveThread();
    defer PyEval_RestoreThread(tstate);
    std.Thread.sleep(ns);
}

fn allocHandle(
    slot: *LoopSlot,
    loop_obj: *PyObject,
    wrapper_obj: ?*PyObject,
    callback: *PyObject,
    call_args: *PyObject,
    context: ?*PyObject,
    when: f64,
    is_timer: bool,
) LoopError!HandleId {
    if (slot.free_handle_len == 0) return error.HandlePoolFull;

    slot.free_handle_len -= 1;
    const handle_id = slot.free_handles[slot.free_handle_len];
    const native = &slot.handles[handle_id];
    var generation = native.generation +% 1;
    if (generation == 0) generation = 1;
    native.* = .{
        .used = true,
        .running = false,
        .cancelled = false,
        .is_timer = is_timer,
        .generation = generation,
        .when = when,
        .callback = callback,
        .args = call_args,
        .inline_arg = null,
        .has_inline_arg = false,
        .context = if (context != null and !isNone(context.?)) context else null,
        .loop_obj = loop_obj,
        .wrapper = wrapper_obj,
    };
    ffi.incref(loop_obj);
    if (wrapper_obj) |wrapper| ffi.incref(wrapper);
    ffi.incref(callback);
    ffi.incref(call_args);
    if (native.context) |ctx| ffi.incref(ctx);
    return handle_id;
}

fn allocInlineCallbackHandle(
    slot: *LoopSlot,
    loop_obj: *PyObject,
    callback: *PyObject,
    arg: *PyObject,
    context: ?*PyObject,
) LoopError!HandleId {
    if (slot.free_handle_len == 0) return error.HandlePoolFull;

    slot.free_handle_len -= 1;
    const handle_id = slot.free_handles[slot.free_handle_len];
    const native = &slot.handles[handle_id];
    var generation = native.generation +% 1;
    if (generation == 0) generation = 1;
    native.* = .{
        .used = true,
        .running = false,
        .cancelled = false,
        .is_timer = false,
        .has_inline_arg = true,
        .generation = generation,
        .when = 0,
        .callback = callback,
        .args = null,
        .inline_arg = arg,
        .context = if (context != null and !isNone(context.?)) context else null,
        .loop_obj = loop_obj,
        .wrapper = null,
    };
    ffi.incref(loop_obj);
    ffi.incref(callback);
    ffi.incref(arg);
    if (native.context) |ctx| ffi.incref(ctx);
    return handle_id;
}

fn pushReadyHandle(slot: *LoopSlot, handle_id: HandleId) LoopError!void {
    try ensureReadyCapacity(slot);
    const tail = (slot.ready_head + slot.ready_len) % MAX_READY;
    slot.ready[tail] = readyTokenForHandle(handle_id);
    slot.ready_len += 1;
}

fn pushReadyOwned(slot: *LoopSlot, handle_id: HandleId) LoopError!void {
    try ensureReadyCapacity(slot);
    const tail = (slot.ready_head + slot.ready_len) % MAX_READY;
    slot.ready[tail] = readyTokenForHandle(handle_id);
    slot.ready_len += 1;
}

fn pushReadyTask(slot: *LoopSlot, task_id: TaskId) LoopError!void {
    try ensureReadyCapacity(slot);
    const tail = (slot.ready_head + slot.ready_len) % MAX_READY;
    slot.ready[tail] = readyTokenForTask(task_id);
    slot.ready_len += 1;
}

fn pushReadyCallback(slot: *LoopSlot, cb_id: CallbackId) LoopError!void {
    try ensureReadyCapacity(slot);
    const tail = (slot.ready_head + slot.ready_len) % MAX_READY;
    slot.ready[tail] = readyTokenForCallback(cb_id);
    slot.ready_len += 1;
}

fn ensureReadyCapacity(slot: *LoopSlot) LoopError!void {
    if (slot.ready_len == 0) {
        slot.ready_head = 0;
        return;
    }

    if (slot.ready_len < MAX_READY) return;
    try compactReady(slot);
    if (slot.ready_len >= MAX_READY) return error.ReadyQueueFull;
}

fn compactReady(slot: *LoopSlot) LoopError!void {
    if (slot.ready_len == 0) {
        slot.ready_head = 0;
        return;
    }

    var compacted: [MAX_READY]ReadyToken = .{invalid_ready_token} ** MAX_READY;
    var write_idx: usize = 0;
    var n: usize = 0;
    while (n < slot.ready_len) : (n += 1) {
        const idx = (slot.ready_head + n) % MAX_READY;
        const token = slot.ready[idx];
        if (token == invalid_ready_token) continue;
        compacted[write_idx] = token;
        slot.ready[idx] = invalid_ready_token;
        write_idx += 1;
    }

    slot.ready = compacted;
    slot.ready_head = 0;
    slot.ready_len = write_idx;
}

fn discardReadyCallback(slot: *LoopSlot, callback: *PyObject) void {
    var n: usize = 0;
    while (n < slot.ready_len) : (n += 1) {
        const idx = (slot.ready_head + n) % MAX_READY;
        const token = slot.ready[idx];
        if (readyTokenIsHandle(token)) {
            const handle_id = readyHandleId(token);
            if (@as(usize, handle_id) >= MAX_HANDLES) continue;
            const native = &slot.handles[handle_id];
            if (!native.used or native.callback != callback) continue;
            cancelNativeHandle(slot, handle_id);
            slot.ready[idx] = invalid_ready_token;
            continue;
        }
        if (readyTokenIsCallback(token)) {
            const cb_id = readyCallbackId(token);
            if (@as(usize, cb_id) >= MAX_FUTURE_CALLBACKS) continue;
            const entry = &slot.future_callbacks[cb_id];
            if (!entry.used or entry.callback != callback) continue;
            freeFutureCallback(slot, cb_id);
            slot.ready[idx] = invalid_ready_token;
        }
    }
    compactReady(slot) catch {
        if (ffi.errOccurred()) ffi.errClear();
    };
}

fn pushScheduledHandle(slot: *LoopSlot, when: f64, handle_id: HandleId) LoopError!void {
    if (slot.scheduled_len >= MAX_SCHEDULED) return error.ScheduledQueueFull;
    slot.scheduled[slot.scheduled_len] = .{
        .when = when,
        .seq = slot.sequence,
        .handle_id = handle_id,
    };
    slot.sequence += 1;
    slot.scheduled_len += 1;
}

fn runOnce(slot: *LoopSlot) LoopError!void {
    var next_when = try drainScheduled(slot, slotTime(slot));

    if (slot.ready_len == 0) {
        if (next_when) |when| {
            const now = slotTime(slot);
            if (when > now) {
                const ns: u64 = @intFromFloat((when - now) * @as(f64, std.time.ns_per_s));
                sleepWithGilReleased(ns);
            }
        } else {
            sleepWithGilReleased(1 * std.time.ns_per_ms);
        }
        next_when = try drainScheduled(slot, slotTime(slot));
    }

    const ntodo = slot.ready_len;
    var i: usize = 0;
    while (i < ntodo) : (i += 1) {
        const idx = slot.ready_head;
        const token = slot.ready[idx];
        slot.ready[idx] = invalid_ready_token;
        slot.ready_head = (slot.ready_head + 1) % MAX_READY;
        slot.ready_len -= 1;
        try runReadyToken(slot, token);
    }

    if (slot.ready_len == 0) {
        slot.ready_head = 0;
    }
}

fn nextScheduledDelayNs(slot: *LoopSlot, now: f64) LoopError!?u64 {
    var next_when: ?f64 = null;
    var i: usize = 0;
    while (i < slot.scheduled_len) : (i += 1) {
        const entry = slot.scheduled[i];
        const handle_id = entry.handle_id;
        if (handle_id == invalid_handle_id) continue;
        if (@as(usize, handle_id) >= MAX_HANDLES) continue;
        const native = &slot.handles[handle_id];
        if (!native.used or native.cancelled) continue;
        if (next_when == null or entry.when < next_when.?) next_when = entry.when;
    }
    if (next_when) |when| {
        if (when <= now) return 0;
        return @intFromFloat((when - now) * @as(f64, std.time.ns_per_s));
    }
    return null;
}

fn drainScheduled(slot: *LoopSlot, now: f64) LoopError!?f64 {
    var next_when: ?f64 = null;
    var write_idx: usize = 0;
    var i: usize = 0;
    while (i < slot.scheduled_len) : (i += 1) {
        const entry = slot.scheduled[i];
        const handle_id = entry.handle_id;
        if (handle_id == invalid_handle_id) continue;
        if (@as(usize, handle_id) >= MAX_HANDLES) continue;
        const native = &slot.handles[handle_id];

        if (!native.used or native.cancelled) {
            cancelNativeHandle(slot, handle_id);
            continue;
        }

        if (entry.when <= now) {
            try pushReadyOwned(slot, handle_id);
            continue;
        }

        slot.scheduled[write_idx] = entry;
        write_idx += 1;
        if (next_when == null or entry.when < next_when.?) next_when = entry.when;
    }

    const kept = write_idx;
    while (write_idx < slot.scheduled_len) : (write_idx += 1) {
        slot.scheduled[write_idx] = .{};
    }
    slot.scheduled_len = kept;
    return next_when;
}

fn runReadyHandle(slot: *LoopSlot, handle_id: HandleId) LoopError!void {
    if (handle_id == invalid_handle_id or @as(usize, handle_id) >= MAX_HANDLES) return;
    const native = &slot.handles[handle_id];
    if (!native.used) return;
    if (native.cancelled) {
        finishHandle(slot, handle_id, true);
        return;
    }

    native.running = true;
    defer native.running = false;

    const result = invokeNativeHandle(native) catch {
        if (c.PyErr_ExceptionMatches(c.PyExc_Exception) != 0) {
            reportNativeHandleException(native);
            finishHandle(slot, handle_id, false);
            return;
        }
        return error.PythonError;
    };
    ffi.decref(result);
    finishHandle(slot, handle_id, false);
}

fn invokeReadyFutureCallback(entry: *FutureCallbackSlot) LoopError!*PyObject {
    const callback = entry.callback orelse return ffi.getNone();
    const arg = entry.arg orelse return callCallableNoArgs(callback);
    if (entry.context) |ctx| {
        return callContextRunOneArg(ctx, callback, arg);
    }
    return callCallableOneArg(callback, arg);
}

fn reportReadyFutureCallbackException(entry: *FutureCallbackSlot) void {
    const saved = fetchPyError();
    defer {
        if (saved.typ) |obj| ffi.decref(obj);
        if (saved.val) |obj| ffi.decref(obj);
        if (saved.tb) |obj| ffi.decref(obj);
    }

    const loop_obj = entry.loop_obj orelse return;
    const ctx = ffi.dictNew() catch return;
    defer ffi.decref(ctx);

    const msg = ffi.unicodeFromString("Exception in callback") catch return;
    defer ffi.decref(msg);
    _ = c.PyDict_SetItemString(ctx, "message", msg);
    if (saved.val) |exc| _ = c.PyDict_SetItemString(ctx, "exception", exc);

    const res = callMethodOneArg(loop_obj, "call_exception_handler", ctx) catch {
        if (ffi.errOccurred()) ffi.errPrint();
        return;
    };
    ffi.decref(res);
}

fn runReadyFutureCallback(slot: *LoopSlot, cb_id: CallbackId) LoopError!void {
    if (cb_id == invalid_callback_id or @as(usize, cb_id) >= MAX_FUTURE_CALLBACKS) return;
    const entry = &slot.future_callbacks[cb_id];
    if (!entry.used or !entry.ready) return;

    const result = invokeReadyFutureCallback(entry) catch {
        if (c.PyErr_ExceptionMatches(c.PyExc_Exception) != 0) {
            reportReadyFutureCallbackException(entry);
            freeFutureCallback(slot, cb_id);
            return;
        }
        return error.PythonError;
    };
    ffi.decref(result);
    freeFutureCallback(slot, cb_id);
}

fn invokeNativeHandle(native: *NativeHandleSlot) LoopError!*PyObject {
    const callback = native.callback orelse return ffi.getNone();

    if (native.has_inline_arg) {
        const arg = native.inline_arg orelse return callCallableNoArgs(callback);
        if (native.context) |ctx| {
            return callContextRunOneArg(ctx, callback, arg);
        }
        return callCallableOneArg(callback, arg);
    }

    const args = native.args orelse return callCallableNoArgs(callback);

    if (native.context) |ctx| {
        return callContextRun(ctx, callback, args);
    }

    const nargs = ffi.tupleSize(args);
    return switch (nargs) {
        0 => callCallableNoArgs(callback),
        1 => callCallableOneArg(callback, ffi.tupleGetItem(args, 0) orelse return error.PythonError),
        else => callObjectRaw(callback, args),
    };
}

fn reportNativeHandleException(native: *NativeHandleSlot) void {
    const saved = fetchPyError();
    defer {
        if (saved.typ) |obj| ffi.decref(obj);
        if (saved.val) |obj| ffi.decref(obj);
        if (saved.tb) |obj| ffi.decref(obj);
    }

    const loop_obj = native.loop_obj orelse return;
    const ctx = ffi.dictNew() catch return;
    defer ffi.decref(ctx);

    const msg = ffi.unicodeFromString("Exception in callback") catch return;
    defer ffi.decref(msg);
    _ = c.PyDict_SetItemString(ctx, "message", msg);
    if (saved.val) |exc| _ = c.PyDict_SetItemString(ctx, "exception", exc);
    if (native.wrapper) |wrapper| _ = c.PyDict_SetItemString(ctx, "handle", wrapper);

    const res = callMethodOneArg(loop_obj, "call_exception_handler", ctx) catch {
        if (ffi.errOccurred()) ffi.errPrint();
        return;
    };
    ffi.decref(res);
}

fn reportTaskStepAlreadyDone(task: *NativeTaskSlot, exc_obj: ?*PyObject) void {
    const loop_obj = task.core.loop_obj orelse return;
    const ctx = ffi.dictNew() catch return;
    defer ffi.decref(ctx);

    const excs = importModuleRaw("asyncio.exceptions") catch return;
    defer ffi.decref(excs);
    const invalid = getAttrRaw(excs, "InvalidStateError") catch return;
    defer ffi.decref(invalid);

    const detail = ffi.unicodeFromString("__step(): already done") catch return;
    defer ffi.decref(detail);
    const args = ffi.tupleNew(1) catch return;
    defer ffi.decref(args);
    ffi.tupleSetItemTake(args, 0, ffi.OwnedPy.increfBorrowed(detail)) catch return;

    const err = callObjectRaw(invalid, args) catch return;
    defer ffi.decref(err);

    const msg = ffi.unicodeFromString("Exception in callback") catch return;
    defer ffi.decref(msg);
    _ = c.PyDict_SetItemString(ctx, "message", msg);
    _ = c.PyDict_SetItemString(ctx, "exception", err);
    if (task.core.wrapper) |wrapper| _ = c.PyDict_SetItemString(ctx, "task", wrapper);
    if (exc_obj) |exc| _ = c.PyDict_SetItemString(ctx, "source_exception", exc);

    const res = callMethodOneArg(loop_obj, "call_exception_handler", ctx) catch {
        if (ffi.errOccurred()) ffi.errPrint();
        return;
    };
    ffi.decref(res);
}

fn closeTaskCoroutine(task: *NativeTaskSlot) void {
    const coro = task.coro orelse return;
    const res = callMethodNoArgs(coro, "close") catch {
        if (ffi.errOccurred()) ffi.errClear();
        return;
    };
    ffi.decref(res);
}

fn finishHandle(slot: *LoopSlot, handle_id: HandleId, cancelled: bool) void {
    if (handle_id == invalid_handle_id or @as(usize, handle_id) >= MAX_HANDLES) return;
    const native = &slot.handles[handle_id];
    if (!native.used) return;

    if (native.wrapper) |wrapper| {
        if (cancelled) {
            const res: ?*PyObject = callMethodNoArgs(wrapper, "_mark_cancelled") catch blk: {
                if (ffi.errOccurred()) ffi.errClear();
                break :blk null;
            };
            if (res) |obj| ffi.decref(obj);
        }
        ffi.decref(wrapper);
    }
    if (native.callback) |obj| ffi.decref(obj);
    if (native.args) |obj| ffi.decref(obj);
    if (native.inline_arg) |obj| ffi.decref(obj);
    if (native.context) |obj| ffi.decref(obj);
    if (native.loop_obj) |obj| ffi.decref(obj);

    const generation = native.generation;
    native.* = .{ .generation = generation };
    slot.free_handles[slot.free_handle_len] = handle_id;
    slot.free_handle_len += 1;
}

fn cancelNativeHandle(slot: *LoopSlot, handle_id: HandleId) void {
    if (handle_id == invalid_handle_id or @as(usize, handle_id) >= MAX_HANDLES) return;
    const native = &slot.handles[handle_id];
    if (!native.used) return;
    if (native.running) return;
    finishHandle(slot, handle_id, true);
}

fn getRunningLoop() LoopError!*PyObject {
    var events_mod = ffi.OwnedPy.init(try importModuleRaw("asyncio.events"));
    defer events_mod.deinit();
    var func = ffi.OwnedPy.init(try getAttrRaw(events_mod.get(), "_get_running_loop"));
    defer func.deinit();
    return callObjectRaw(func.get(), null);
}

fn setRunningLoop(loop_obj: *PyObject) LoopError!void {
    var events_mod = ffi.OwnedPy.init(try importModuleRaw("asyncio.events"));
    defer events_mod.deinit();
    var func = ffi.OwnedPy.init(try getAttrRaw(events_mod.get(), "_set_running_loop"));
    defer func.deinit();
    var args = ffi.OwnedPy.init(try ffi.tupleNew(1));
    errdefer args.deinit();
    ffi.incref(loop_obj);
    try ffi.tupleSetItemTake(args.get(), 0, ffi.OwnedPy.increfBorrowed(loop_obj));
    var res = ffi.OwnedPy.init(try callObjectRaw(func.get(), args.get()));
    defer res.deinit();
    args.deinit();
}

fn getCoroutineOriginTrackingDepth() LoopError!c_long {
    var sys_mod = ffi.OwnedPy.init(try importModuleRaw("sys"));
    defer sys_mod.deinit();
    var func = ffi.OwnedPy.init(try getAttrRaw(sys_mod.get(), "get_coroutine_origin_tracking_depth"));
    defer func.deinit();
    var res = ffi.OwnedPy.init(try callObjectRaw(func.get(), null));
    defer res.deinit();
    return ffi.longAsLong(res.get());
}

fn setCoroutineOriginTrackingDepth(depth: c_long) LoopError!void {
    var sys_mod = ffi.OwnedPy.init(try importModuleRaw("sys"));
    defer sys_mod.deinit();
    var func = ffi.OwnedPy.init(try getAttrRaw(sys_mod.get(), "set_coroutine_origin_tracking_depth"));
    defer func.deinit();
    var args = ffi.OwnedPy.init(try ffi.tupleNew(1));
    errdefer args.deinit();
    try ffi.tupleSetItemTake(args.get(), 0, ffi.OwnedPy.init(try ffi.longFromLong(depth)));
    var res = ffi.OwnedPy.init(try callObjectRaw(func.get(), args.get()));
    defer res.deinit();
    args.deinit();
}

fn ensureFuture(loop_obj: *PyObject, future_obj: *PyObject) LoopError!*PyObject {
    var asyncio = ffi.OwnedPy.init(try importModuleRaw("asyncio"));
    defer asyncio.deinit();
    var ensure_future_fn = ffi.OwnedPy.init(try getAttrRaw(asyncio.get(), "ensure_future"));
    defer ensure_future_fn.deinit();

    var args = ffi.OwnedPy.init(try ffi.tupleNew(1));
    errdefer args.deinit();
    try ffi.tupleSetItemTake(args.get(), 0, ffi.OwnedPy.increfBorrowed(future_obj));

    var kwargs = ffi.OwnedPy.init(try ffi.dictNew());
    errdefer kwargs.deinit();
    try ffi.dictSetItemString(kwargs.get(), "loop", loop_obj);

    const target = try callObjectKwargsRaw(ensure_future_fn.get(), args.get(), kwargs.get());
    args.deinit();
    kwargs.deinit();
    return target;
}

fn futureDoneObject(future_obj: *PyObject) LoopError!bool {
    const res = try callMethodNoArgs(future_obj, "done");
    defer ffi.decref(res);
    const truth = c.PyObject_IsTrue(res);
    if (truth < 0) return error.PythonError;
    return truth == 1;
}

fn futureCancelledObject(future_obj: *PyObject) LoopError!bool {
    const res = try callMethodNoArgs(future_obj, "cancelled");
    defer ffi.decref(res);
    const truth = c.PyObject_IsTrue(res);
    if (truth < 0) return error.PythonError;
    return truth == 1;
}

fn callCallableNoArgs(callable: *PyObject) LoopError!*PyObject {
    return c.PyObject_CallNoArgs(callable) orelse error.PythonError;
}

fn callCallableOneArg(callable: *PyObject, arg: *PyObject) LoopError!*PyObject {
    return c.PyObject_CallOneArg(callable, arg) orelse error.PythonError;
}

fn callContextRun(context: *PyObject, callback: *PyObject, args: *PyObject) LoopError!*PyObject {
    const nargs: usize = @intCast(ffi.tupleSize(args));
    const run_name = try getRunMethodName();
    defer ffi.decref(run_name);

    return switch (nargs) {
        0 => blk: {
            var argv = [_]*PyObject{ context, callback };
            const res = c.PyObject_VectorcallMethod(run_name, &argv, 2 | vectorcall_offset, null) orelse
                return error.PythonError;
            break :blk res;
        },
        1 => blk: {
            const arg0 = ffi.tupleGetItem(args, 0) orelse return error.PythonError;
            var argv = [_]*PyObject{ context, callback, arg0 };
            const res = c.PyObject_VectorcallMethod(run_name, &argv, 3 | vectorcall_offset, null) orelse
                return error.PythonError;
            break :blk res;
        },
        2 => blk: {
            const arg0 = ffi.tupleGetItem(args, 0) orelse return error.PythonError;
            const arg1 = ffi.tupleGetItem(args, 1) orelse return error.PythonError;
            var argv = [_]*PyObject{ context, callback, arg0, arg1 };
            const res = c.PyObject_VectorcallMethod(run_name, &argv, 4 | vectorcall_offset, null) orelse
                return error.PythonError;
            break :blk res;
        },
        3 => blk: {
            const arg0 = ffi.tupleGetItem(args, 0) orelse return error.PythonError;
            const arg1 = ffi.tupleGetItem(args, 1) orelse return error.PythonError;
            const arg2 = ffi.tupleGetItem(args, 2) orelse return error.PythonError;
            var argv = [_]*PyObject{ context, callback, arg0, arg1, arg2 };
            const res = c.PyObject_VectorcallMethod(run_name, &argv, 5 | vectorcall_offset, null) orelse
                return error.PythonError;
            break :blk res;
        },
        else => blk: {
            const run_fn = try getAttrRaw(context, "run");
            defer ffi.decref(run_fn);

            const call_args = try ffi.tupleNew(@intCast(nargs + 1));
            errdefer ffi.decref(call_args);

            try ffi.tupleSetItemTake(call_args, 0, ffi.OwnedPy.increfBorrowed(callback));
            for (0..nargs) |i| {
                const item = ffi.tupleGetItem(args, @intCast(i)) orelse return error.PythonError;
                try ffi.tupleSetItemTake(call_args, @intCast(i + 1), ffi.OwnedPy.increfBorrowed(item));
            }

            const result = try callObjectRaw(run_fn, call_args);
            ffi.decref(call_args);
            break :blk result;
        },
    };
}

fn callContextRunOneArg(context: *PyObject, callback: *PyObject, arg0: *PyObject) LoopError!*PyObject {
    const run_name = try getRunMethodName();
    defer ffi.decref(run_name);
    var argv = [_]*PyObject{ context, callback, arg0 };
    return c.PyObject_VectorcallMethod(run_name, &argv, 3 | vectorcall_offset, null) orelse error.PythonError;
}

fn callCallableOneArgInContext(context: *PyObject, callable: *PyObject, arg0: *PyObject) LoopError!*PyObject {
    try ffi.contextEnter(context);
    const result = callCallableOneArg(callable, arg0) catch |err| {
        if (ffi.errOccurred()) {
            const saved = fetchPyError();
            ffi.contextExit(context) catch {
                if (ffi.errOccurred()) ffi.errClear();
            };
            restorePyError(saved);
            return err;
        }
        ffi.contextExit(context) catch |exit_err| return exit_err;
        return err;
    };
    ffi.contextExit(context) catch |err| {
        ffi.decref(result);
        return err;
    };
    return result;
}

fn iterSendInContext(context: *PyObject, iter: *PyObject, arg: *PyObject) LoopError!IterSendResult {
    try ffi.contextEnter(context);
    const raw = ffi.iterSend(iter, arg);
    const send = IterSendResult{ .result = raw.result, .status = raw.status };
    if (send.status == .@"error" and ffi.errOccurred()) {
        const saved = fetchPyError();
        ffi.contextExit(context) catch {
            if (ffi.errOccurred()) ffi.errClear();
        };
        restorePyError(saved);
        return send;
    }
    try ffi.contextExit(context);
    return send;
}

fn callMethodNoArgs(obj: *PyObject, method: [*:0]const u8) LoopError!*PyObject {
    var callable = ffi.OwnedPy.init(try getAttrRaw(obj, method));
    defer callable.deinit();
    return callObjectRaw(callable.get(), null);
}

fn callMethodOneArg(obj: *PyObject, method: [*:0]const u8, arg: *PyObject) LoopError!*PyObject {
    var callable = ffi.OwnedPy.init(try getAttrRaw(obj, method));
    defer callable.deinit();
    var args = ffi.OwnedPy.init(try ffi.tupleNew(1));
    errdefer args.deinit();
    try ffi.tupleSetItemTake(args.get(), 0, ffi.OwnedPy.increfBorrowed(arg));
    const res = try callObjectRaw(callable.get(), args.get());
    args.deinit();
    return res;
}

fn isNone(obj: *PyObject) bool {
    const none: *PyObject = @ptrCast(&c._Py_NoneStruct);
    return obj == none;
}

fn fetchPyError() SavedPyError {
    var saved = SavedPyError{};
    c.PyErr_Fetch(&saved.typ, &saved.val, &saved.tb);
    return saved;
}

fn restorePyError(saved: SavedPyError) void {
    c.PyErr_Restore(saved.typ, saved.val, saved.tb);
}

fn importModuleRaw(name: [*:0]const u8) LoopError!*PyObject {
    return c.PyImport_ImportModule(name) orelse error.PythonError;
}

fn getAttrRaw(obj: *PyObject, attr: [*:0]const u8) LoopError!*PyObject {
    return c.PyObject_GetAttrString(obj, attr) orelse error.PythonError;
}

fn setAttrRaw(obj: *PyObject, attr: [*:0]const u8, value: *PyObject) LoopError!void {
    if (c.PyObject_SetAttrString(obj, attr, value) != 0) return error.PythonError;
}

fn callObjectRaw(callable: *PyObject, args: ?*PyObject) LoopError!*PyObject {
    return c.PyObject_CallObject(callable, args) orelse error.PythonError;
}

fn callObjectKwargsRaw(callable: *PyObject, args: ?*PyObject, kwargs: *PyObject) LoopError!*PyObject {
    return c.PyObject_Call(callable, args, kwargs) orelse error.PythonError;
}

fn formatCallbackSource(callback: *PyObject, args: *PyObject, debug: bool) LoopError!*PyObject {
    var helpers_mod = ffi.OwnedPy.init(try importModuleRaw("asyncio.format_helpers"));
    defer helpers_mod.deinit();
    var func = ffi.OwnedPy.init(try getAttrRaw(helpers_mod.get(), "_format_callback_source"));
    defer func.deinit();

    var call_args = ffi.OwnedPy.init(try ffi.tupleNew(2));
    errdefer call_args.deinit();
    try ffi.tupleSetItemTake(call_args.get(), 0, ffi.OwnedPy.increfBorrowed(callback));
    try ffi.tupleSetItemTake(call_args.get(), 1, ffi.OwnedPy.increfBorrowed(args));

    var kwargs = ffi.OwnedPy.init(try ffi.dictNew());
    errdefer kwargs.deinit();
    var debug_obj = ffi.OwnedPy.init(ffi.boolFromBool(debug));
    defer debug_obj.deinit();
    try ffi.dictSetItemString(kwargs.get(), "debug", debug_obj.get());

    const result = try callObjectKwargsRaw(func.get(), call_args.get(), kwargs.get());
    call_args.deinit();
    kwargs.deinit();
    return result;
}

fn tokenForFuture(slot: *LoopSlot, future_id: FutureId) FutureToken {
    const generation = slot.futures[future_id].generation;
    return (@as(FutureToken, generation) << 16) | @as(FutureToken, future_id);
}

fn tokenForTask(slot: *LoopSlot, task_id: TaskId) TaskToken {
    const generation = slot.tasks[task_id].generation;
    return (@as(TaskToken, generation) << 16) | @as(TaskToken, task_id);
}

fn tokenForHandle(slot: *LoopSlot, handle_id: HandleId) HandleToken {
    const generation = slot.handles[handle_id].generation;
    return (@as(HandleToken, generation) << 16) | @as(HandleToken, handle_id);
}

fn decodeHandleToken(handle_token: HandleToken) struct { id: HandleId, generation: u32 } {
    return .{
        .id = @intCast(handle_token & 0xffff),
        .generation = @intCast(handle_token >> 16),
    };
}

fn decodeFutureToken(future_token: FutureToken) struct { id: FutureId, generation: u32 } {
    return .{
        .id = @intCast(future_token & 0xffff),
        .generation = @intCast(future_token >> 16),
    };
}

fn decodeTaskToken(task_token: TaskToken) struct { id: TaskId, generation: u32 } {
    return .{
        .id = @intCast(task_token & 0xffff),
        .generation = @intCast(task_token >> 16),
    };
}

fn futureIdFromToken(slot: *LoopSlot, future_token: FutureToken) LoopError!FutureId {
    const decoded = decodeFutureToken(future_token);
    if (@as(usize, decoded.id) >= MAX_FUTURES) return error.InvalidState;
    const future = &slot.futures[decoded.id];
    if (!future.used or future.generation != decoded.generation) return error.InvalidState;
    return decoded.id;
}

fn taskIdFromToken(slot: *LoopSlot, task_token: TaskToken) LoopError!TaskId {
    const decoded = decodeTaskToken(task_token);
    if (@as(usize, decoded.id) >= MAX_TASKS) return error.InvalidState;
    const task = &slot.tasks[decoded.id];
    if (!task.used or task.generation != decoded.generation) return error.InvalidState;
    return decoded.id;
}

fn futureFromToken(handle_obj: *PyObject, future_token: FutureToken) LoopError!*NativeFutureSlot {
    const slot = try slotFromCapsule(handle_obj);
    const future_id = try futureIdFromToken(slot, future_token);
    return &slot.futures[future_id];
}

fn taskFromToken(handle_obj: *PyObject, task_token: TaskToken) LoopError!*NativeTaskSlot {
    const slot = try slotFromCapsule(handle_obj);
    const task_id = try taskIdFromToken(slot, task_token);
    return &slot.tasks[task_id];
}

fn allocFuture(slot: *LoopSlot, loop_obj: *PyObject, wrapper_obj: *PyObject) LoopError!FutureId {
    if (slot.free_future_len == 0) return error.FuturePoolFull;
    slot.free_future_len -= 1;
    const future_id = slot.free_futures[slot.free_future_len];
    const future = &slot.futures[future_id];
    var generation = future.generation +% 1;
    if (generation == 0) generation = 1;
    future.* = .{
        .used = true,
        .generation = generation,
        .core = .{
            .state = .pending,
            .loop_obj = loop_obj,
            .wrapper = wrapper_obj,
        },
    };
    ffi.incref(loop_obj);
    ffi.incref(wrapper_obj);
    return future_id;
}

fn releaseFutureCore(slot: *LoopSlot, core: *FutureCore) void {
    var cb_id = core.callbacks_head;
    while (cb_id != invalid_callback_id) {
        const next = slot.future_callbacks[cb_id].next;
        freeFutureCallback(slot, cb_id);
        cb_id = next;
    }

    if (core.loop_obj) |obj| ffi.decref(obj);
    if (core.wrapper) |obj| ffi.decref(obj);
    if (core.result) |obj| ffi.decref(obj);
    if (core.exception) |obj| ffi.decref(obj);
    if (core.exception_tb) |obj| ffi.decref(obj);
    if (core.cancel_message) |obj| ffi.decref(obj);

    core.* = .{};
}

fn releaseFuture(slot: *LoopSlot, future_id: FutureId) void {
    const future = &slot.futures[future_id];
    if (!future.used) return;
    releaseFutureCore(slot, &future.core);
    const generation = future.generation;
    future.* = .{ .generation = generation };
    slot.free_futures[slot.free_future_len] = future_id;
    slot.free_future_len += 1;
}

fn snapshotFutureCoreToWrapper(core: *FutureCore) void {
    const wrapper = core.wrapper orelse return;
    const self = futureObjectFromPy(wrapper);
    if (self.shadow_result) |obj| {
        ffi.decref(obj);
        self.shadow_result = null;
    }
    if (self.shadow_exception) |obj| {
        ffi.decref(obj);
        self.shadow_exception = null;
    }
    if (self.shadow_exception_tb) |obj| {
        ffi.decref(obj);
        self.shadow_exception_tb = null;
    }
    if (self.shadow_cancel_message) |obj| {
        ffi.decref(obj);
        self.shadow_cancel_message = null;
    }
    self.shadow_valid = true;
    self.shadow_state = core.state;
    if (core.result) |obj| {
        self.shadow_result = obj;
        ffi.incref(obj);
    }
    if (core.exception) |obj| {
        self.shadow_exception = obj;
        ffi.incref(obj);
    }
    if (core.exception_tb) |obj| {
        self.shadow_exception_tb = obj;
        ffi.incref(obj);
    }
    if (core.cancel_message) |obj| {
        self.shadow_cancel_message = obj;
        ffi.incref(obj);
    }
}

fn dropFutureWrapperCore(core: *FutureCore) void {
    if (core.wrapper) |obj| {
        snapshotFutureCoreToWrapper(core);
        ffi.decref(obj);
        core.wrapper = null;
    }
}

fn allocFutureCallback(slot: *LoopSlot, callback: *PyObject, context: ?*PyObject) LoopError!CallbackId {
    if (slot.free_callback_len == 0) return error.FutureCallbackPoolFull;
    slot.free_callback_len -= 1;
    const cb_id = slot.free_future_callbacks[slot.free_callback_len];
    const entry = &slot.future_callbacks[cb_id];
    entry.* = .{
        .used = true,
        .ready = false,
        .next = invalid_callback_id,
        .callback = callback,
        .context = if (context != null and !isNone(context.?)) context else null,
        .arg = null,
        .loop_obj = null,
    };
    ffi.incref(callback);
    if (entry.context) |ctx| ffi.incref(ctx);
    return cb_id;
}

fn scheduleFutureCallbackReady(
    slot: *LoopSlot,
    cb_id: CallbackId,
    loop_obj: *PyObject,
    arg: *PyObject,
) LoopError!void {
    if (cb_id == invalid_callback_id or @as(usize, cb_id) >= MAX_FUTURE_CALLBACKS) return error.InvalidState;
    const entry = &slot.future_callbacks[cb_id];
    if (!entry.used) return error.InvalidState;
    entry.ready = true;
    entry.arg = arg;
    entry.loop_obj = loop_obj;
    ffi.incref(arg);
    ffi.incref(loop_obj);
    errdefer {
        ffi.decref(arg);
        ffi.decref(loop_obj);
        entry.arg = null;
        entry.loop_obj = null;
        entry.ready = false;
    }
    try pushReadyCallback(slot, cb_id);
}

fn freeFutureCallback(slot: *LoopSlot, cb_id: CallbackId) void {
    if (cb_id == invalid_callback_id or @as(usize, cb_id) >= MAX_FUTURE_CALLBACKS) return;
    const entry = &slot.future_callbacks[cb_id];
    if (!entry.used) return;
    if (entry.callback) |obj| ffi.decref(obj);
    if (entry.context) |obj| ffi.decref(obj);
    if (entry.arg) |obj| ffi.decref(obj);
    if (entry.loop_obj) |obj| ffi.decref(obj);
    entry.* = .{};
    slot.free_future_callbacks[slot.free_callback_len] = cb_id;
    slot.free_callback_len += 1;
}

fn allocGather(
    slot: *LoopSlot,
    outer_obj: *PyObject,
    outer_core: *FutureCore,
    children_obj: *PyObject,
    count: usize,
    return_exceptions: bool,
) LoopError!GatherId {
    if (slot.free_gather_len == 0) return error.GatherPoolFull;
    slot.free_gather_len -= 1;
    const gather_id = slot.free_gathers[slot.free_gather_len];
    const gather = &slot.gathers[gather_id];
    var generation = gather.generation +% 1;
    if (generation == 0) generation = 1;
    gather.* = .{
        .used = true,
        .generation = generation,
        .outer_obj = outer_obj,
        .outer_core = outer_core,
        .children_obj = children_obj,
        .results_obj = null,
        .links_head = invalid_gather_link_id,
        .child_count = @intCast(count),
        .finished_count = 0,
        .return_exceptions = return_exceptions,
    };
    ffi.incref(outer_obj);
    ffi.incref(children_obj);
    return gather_id;
}

fn freeGatherLink(slot: *LoopSlot, link_id: GatherLinkId) void {
    if (link_id == invalid_gather_link_id or @as(usize, link_id) >= MAX_GATHER_LINKS) return;
    const link = &slot.gather_links[link_id];
    if (!link.used) return;
    link.* = .{};
    slot.free_gather_links[slot.free_gather_link_len] = link_id;
    slot.free_gather_link_len += 1;
}

fn releaseGather(slot: *LoopSlot, gather_id: GatherId) void {
    const gather = &slot.gathers[gather_id];
    if (!gather.used) return;
    var link_id = gather.links_head;
    while (link_id != invalid_gather_link_id) {
        const next = slot.gather_links[link_id].next_in_gather;
        freeGatherLink(slot, link_id);
        link_id = next;
    }
    if (gather.outer_obj) |obj| ffi.decref(obj);
    if (gather.children_obj) |obj| ffi.decref(obj);
    if (gather.results_obj) |obj| ffi.decref(obj);
    const generation = gather.generation;
    gather.* = .{ .generation = generation };
    slot.free_gathers[slot.free_gather_len] = gather_id;
    slot.free_gather_len += 1;
}

fn allocGatherLink(slot: *LoopSlot, gather_id: GatherId, child_core: *FutureCore, child_index: u32) LoopError!GatherLinkId {
    if (slot.free_gather_link_len == 0) return error.GatherLinkPoolFull;
    slot.free_gather_link_len -= 1;
    const link_id = slot.free_gather_links[slot.free_gather_link_len];
    const gather = &slot.gathers[gather_id];
    const link = &slot.gather_links[link_id];
    link.* = .{
        .used = true,
        .next_in_child = child_core.gather_links_head,
        .next_in_gather = gather.links_head,
        .gather_id = gather_id,
        .child_index = child_index,
    };
    child_core.gather_links_head = link_id;
    gather.links_head = link_id;
    return link_id;
}

fn sequenceItemBorrowed(seq_obj: *PyObject, index: usize) ?*PyObject {
    if (c.PyList_Check(seq_obj) != 0) {
        return c.PyList_GetItem(seq_obj, @intCast(index));
    }
    if (ffi.isTuple(seq_obj)) {
        return ffi.tupleGetItem(seq_obj, @intCast(index));
    }
    return null;
}

fn sequenceLen(seq_obj: *PyObject) LoopError!usize {
    if (c.PyList_Check(seq_obj) != 0) {
        const len = c.PyList_Size(seq_obj);
        if (len < 0) return error.PythonError;
        return @intCast(len);
    }
    if (ffi.isTuple(seq_obj)) {
        return @intCast(ffi.tupleSize(seq_obj));
    }
    c.PyErr_SetString(c.PyExc_TypeError, "expected list or tuple");
    return error.PythonError;
}

fn gatherCancelRequested(outer_obj: *PyObject) LoopError!bool {
    const requested = getAttrRaw(outer_obj, "_cancel_requested") catch {
        if (ffi.errOccurred()) ffi.errClear();
        return false;
    };
    defer ffi.decref(requested);
    const truth = c.PyObject_IsTrue(requested);
    if (truth < 0) return error.PythonError;
    return truth == 1;
}

fn gatherResults(children_obj: *PyObject) LoopError!*PyObject {
    const count = try sequenceLen(children_obj);
    const result_list = ffi.listNew(@intCast(count)) catch return error.PythonError;
    errdefer ffi.decref(result_list);

    for (0..count) |idx| {
        const child_obj = sequenceItemBorrowed(children_obj, idx) orelse return error.PythonError;
        const child_core = try futureCore(futureObjectFromPy(child_obj));
        const item = blk: {
            if (child_core.state == .cancelled) break :blk try makeCancelledError(child_core.cancel_message);
            if (child_core.exception) |exc| {
                ffi.incref(exc);
                break :blk exc;
            }
            if (child_core.result) |res| {
                ffi.incref(res);
                break :blk res;
            }
            break :blk ffi.getNone();
        };
        try ffi.listSetItemTake(result_list, @intCast(idx), ffi.OwnedPy.init(item));
    }
    return result_list;
}

fn gatherCancelledError(children_obj: *PyObject) LoopError!*PyObject {
    const count = try sequenceLen(children_obj);
    for (0..count) |idx| {
        const child_obj = sequenceItemBorrowed(children_obj, idx) orelse return error.PythonError;
        const child_core = try futureCore(futureObjectFromPy(child_obj));
        if (child_core.state == .cancelled) {
            return makeCancelledError(child_core.cancel_message);
        }
    }
    return makeCancelledError(null);
}

fn consumeCompletedFutureException(child_obj: *PyObject) void {
    const res = callMethodNoArgs(child_obj, "exception") catch {
        if (ffi.errOccurred()) ffi.errClear();
        return;
    };
    ffi.decref(res);
}

fn processGatherChildCompletion(slot: *LoopSlot, gather_id: GatherId, child_core: *FutureCore, child_index: u32) LoopError!void {
    const gather = &slot.gathers[gather_id];
    if (!gather.used) return;
    const outer_obj = gather.outer_obj orelse return;
    const children_obj = gather.children_obj orelse return;
    const outer_core = gather.outer_core orelse return;

    gather.finished_count += 1;

    if (outer_core.state != .pending) {
        if (child_core.state != .cancelled) {
            const child_obj = sequenceItemBorrowed(children_obj, child_index) orelse return error.PythonError;
            consumeCompletedFutureException(child_obj);
        }
        if (gather.finished_count == gather.child_count) releaseGather(slot, gather_id);
        return;
    }

    if (!gather.return_exceptions) {
        if (child_core.state == .cancelled) {
            const exc = try makeCancelledError(child_core.cancel_message);
            defer ffi.decref(exc);
            try setFutureExceptionCore(slot, outer_core, exc, null);
        } else if (child_core.exception) |exc| {
            try setFutureExceptionCore(slot, outer_core, exc, child_core.exception_tb);
        }
    }

    if (gather.finished_count == gather.child_count) {
        if (outer_core.state == .pending) {
            if (try gatherCancelRequested(outer_obj)) {
                const exc = try gatherCancelledError(children_obj);
                defer ffi.decref(exc);
                try setFutureExceptionCore(slot, outer_core, exc, null);
            } else {
                const result_list = try gatherResults(children_obj);
                defer ffi.decref(result_list);
                try setFutureResultCore(slot, outer_core, result_list);
            }
        }
        releaseGather(slot, gather_id);
    }
}

fn notifyGatherLinks(slot: *LoopSlot, child_core: *FutureCore) LoopError!void {
    var link_id = child_core.gather_links_head;
    child_core.gather_links_head = invalid_gather_link_id;
    while (link_id != invalid_gather_link_id) {
        const link = slot.gather_links[link_id];
        const next = link.next_in_child;
        if (link.used) {
            try processGatherChildCompletion(slot, link.gather_id, child_core, link.child_index);
        }
        link_id = next;
    }
}

fn cancelFutureCore(slot: *LoopSlot, core: *FutureCore, message: ?*PyObject) LoopError!bool {
    if (core.state != .pending) return false;
    core.state = .cancelled;
    if (core.wrapper) |wrapper| {
        futureObjectFromPy(wrapper).log_traceback = false;
    }
    if (core.cancel_message) |obj| {
        ffi.decref(obj);
        core.cancel_message = null;
    }
    if (message) |msg| {
        if (!isNone(msg)) {
            core.cancel_message = msg;
            ffi.incref(msg);
        }
    }
    try drainFutureCallbacksCore(slot, core);
    try notifyGatherLinks(slot, core);
    dropFutureWrapperCore(core);
    return true;
}

fn futureResultObject(core: *FutureCore) LoopError!*PyObject {
    switch (core.state) {
        .pending => {
            const excs = try importModuleRaw("asyncio.exceptions");
            defer ffi.decref(excs);
            const invalid = try getAttrRaw(excs, "InvalidStateError");
            defer ffi.decref(invalid);
            c.PyErr_SetString(invalid, "Result is not ready.");
            return error.PythonError;
        },
        .cancelled => {
            const cancelled = try makeCancelledError(core.cancel_message);
            return raiseStoredException(cancelled, null);
        },
        .finished => {
            if (core.exception) |exc| {
                ffi.incref(exc);
                return raiseStoredException(exc, core.exception_tb);
            }
            const result = core.result orelse return ffi.getNone();
            ffi.incref(result);
            return result;
        },
    }
}

fn futureExceptionObject(core: *FutureCore) LoopError!*PyObject {
    switch (core.state) {
        .pending => {
            const excs = try importModuleRaw("asyncio.exceptions");
            defer ffi.decref(excs);
            const invalid = try getAttrRaw(excs, "InvalidStateError");
            defer ffi.decref(invalid);
            c.PyErr_SetString(invalid, "Exception is not set.");
            return error.PythonError;
        },
        .cancelled => {
            const cancelled = try makeCancelledError(core.cancel_message);
            return raiseStoredException(cancelled, null);
        },
        .finished => {
            if (core.exception) |exc| {
                ffi.incref(exc);
                return exc;
            }
            return ffi.getNone();
        },
    }
}

fn addFutureDoneCallbackCore(
    slot: *LoopSlot,
    core: *FutureCore,
    wrapper_obj: *PyObject,
    callback: *PyObject,
    context: ?*PyObject,
) LoopError!void {
    if (core.state != .pending) {
        const loop_obj = core.loop_obj orelse return;
        const cb_id = try allocFutureCallback(slot, callback, context);
        errdefer freeFutureCallback(slot, cb_id);
        try scheduleFutureCallbackReady(slot, cb_id, loop_obj, wrapper_obj);
        return;
    }
    const cb_id = try allocFutureCallback(slot, callback, context);
    if (core.callbacks_tail == invalid_callback_id) {
        core.callbacks_head = cb_id;
        core.callbacks_tail = cb_id;
    } else {
        slot.future_callbacks[core.callbacks_tail].next = cb_id;
        core.callbacks_tail = cb_id;
    }
}

fn removeFutureDoneCallbackCore(slot: *LoopSlot, core: *FutureCore, callback: *PyObject) LoopError!u32 {
    var removed: u32 = 0;
    var prev: CallbackId = invalid_callback_id;
    var cur = core.callbacks_head;
    while (cur != invalid_callback_id) {
        const next = slot.future_callbacks[cur].next;
        const callback_obj = slot.future_callbacks[cur].callback;
        const matches = if (callback_obj) |candidate| blk: {
            ffi.incref(candidate);
            defer ffi.decref(candidate);
            const eq = c.PyObject_RichCompareBool(candidate, callback, c.Py_EQ);
            if (eq < 0) return error.PythonError;
            break :blk eq == 1;
        } else false;
        if (matches) {
            removed += 1;
            if (prev == invalid_callback_id) core.callbacks_head = next else slot.future_callbacks[prev].next = next;
            if (core.callbacks_tail == cur) core.callbacks_tail = prev;
            freeFutureCallback(slot, cur);
        } else {
            prev = cur;
        }
        cur = next;
    }
    return removed;
}

fn setFutureResultCore(slot: *LoopSlot, core: *FutureCore, result: *PyObject) LoopError!void {
    if (core.state != .pending) return error.InvalidState;
    core.state = .finished;
    core.result = result;
    ffi.incref(result);
    try drainFutureCallbacksCore(slot, core);
    try notifyGatherLinks(slot, core);
    dropFutureWrapperCore(core);
}

fn setFutureExceptionCore(slot: *LoopSlot, core: *FutureCore, exc: *PyObject, tb: ?*PyObject) LoopError!void {
    if (core.state != .pending) return error.InvalidState;
    const normalized_exc = try normalizeFutureException(exc);
    errdefer ffi.decref(normalized_exc);
    core.state = .finished;
    core.exception = normalized_exc;
    if (tb) |trace| {
        core.exception_tb = trace;
        ffi.incref(trace);
    } else {
        core.exception_tb = c.PyException_GetTraceback(normalized_exc);
    }
    if (core.wrapper) |wrapper| {
        futureObjectFromPy(wrapper).log_traceback = true;
    }
    try drainFutureCallbacksCore(slot, core);
    try notifyGatherLinks(slot, core);
    dropFutureWrapperCore(core);
}

fn drainFutureCallbacksCore(slot: *LoopSlot, core: *FutureCore) LoopError!void {
    const wrapper = core.wrapper orelse return;
    const loop_obj = core.loop_obj orelse return;
    var cb_id = core.callbacks_head;
    core.callbacks_head = invalid_callback_id;
    core.callbacks_tail = invalid_callback_id;
    while (cb_id != invalid_callback_id) {
        const next = slot.future_callbacks[cb_id].next;
        slot.future_callbacks[cb_id].next = invalid_callback_id;
        try scheduleFutureCallbackReady(slot, cb_id, loop_obj, wrapper);
        cb_id = next;
    }
}

fn inheritRequestConnId(slot: *LoopSlot) RequestConnId {
    const current = slot.current_task orelse return invalid_request_conn_id;
    const future = futureObjectFromPy(current);
    if (future.native_kind != .task) return invalid_request_conn_id;
    const task = taskNative(taskObjectFromFuture(future)) catch return invalid_request_conn_id;
    return task.request_conn_idx;
}

fn allocTask(
    handle_obj: *PyObject,
    slot: *LoopSlot,
    loop_obj: *PyObject,
    wrapper_obj: *PyObject,
    coro: *PyObject,
    context: ?*PyObject,
    name: ?*PyObject,
    request_conn_idx: ?RequestConnId,
) LoopError!TaskId {
    if (slot.free_task_len == 0) return error.TaskPoolFull;
    slot.free_task_len -= 1;
    const task_id = slot.free_tasks[slot.free_task_len];
    const task = &slot.tasks[task_id];
    var generation = task.generation +% 1;
    if (generation == 0) generation = 1;
    _ = handle_obj;

    task.* = .{
        .used = true,
        .generation = generation,
        .core = .{
            .state = .pending,
            .loop_obj = loop_obj,
            .wrapper = wrapper_obj,
        },
        .coro = coro,
        .context = if (context != null and !isNone(context.?)) context else null,
        .name = if (name != null and !isNone(name.?)) name else null,
        .request_conn_idx = request_conn_idx orelse inheritRequestConnId(slot),
    };
    ffi.incref(loop_obj);
    ffi.incref(wrapper_obj);
    ffi.incref(coro);
    if (task.context) |ctx| ffi.incref(ctx);
    if (task.name) |n| ffi.incref(n);
    return task_id;
}

fn ensureTaskWakeupCallback(task: *NativeTaskSlot, task_id: TaskId) LoopError!*PyObject {
    if (task.wakeup_cb) |obj| return obj;

    const wrapper = task.core.wrapper orelse return error.InvalidState;
    const task_obj = taskObjectFromPy(wrapper);
    const handle_obj = task_obj.future.loop_handle orelse return error.InvalidState;

    const self_tuple = try ffi.tupleNew(2);
    errdefer ffi.decref(self_tuple);
    try ffi.tupleSetItemTake(self_tuple, 0, ffi.OwnedPy.increfBorrowed(handle_obj));
    const token_obj = try ffi.longFromLong(@intCast((@as(TaskToken, task.generation) << 16) | @as(TaskToken, task_id)));
    try ffi.tupleSetItemTake(self_tuple, 1, ffi.OwnedPy.init(token_obj));
    const wakeup_cb = c.PyCFunction_NewEx(&task_wakeup_callback_def, self_tuple, null) orelse return error.PythonError;
    ffi.decref(self_tuple);
    task.wakeup_cb = wakeup_cb;
    return wakeup_cb;
}

fn releaseTask(slot: *LoopSlot, task_id: TaskId) void {
    const task = &slot.tasks[task_id];
    if (!task.used) return;
    releaseFutureCore(slot, &task.core);
    if (task.coro) |obj| ffi.decref(obj);
    if (task.context) |obj| ffi.decref(obj);
    if (task.name) |obj| ffi.decref(obj);
    if (task.fut_waiter) |obj| ffi.decref(obj);
    if (task.step_exc) |obj| ffi.decref(obj);
    if (task.step_value) |obj| ffi.decref(obj);
    if (task.wakeup_cb) |obj| ffi.decref(obj);
    const generation = task.generation;
    task.* = .{ .generation = generation };
    slot.free_tasks[slot.free_task_len] = task_id;
    slot.free_task_len += 1;
}

fn clearFinishedTaskState(task: *NativeTaskSlot) void {
    task.scheduled = false;
    task.must_cancel = false;

    if (task.fut_waiter) |obj| {
        ffi.decref(obj);
        task.fut_waiter = null;
    }
    if (task.step_exc) |obj| {
        ffi.decref(obj);
        task.step_exc = null;
    }
    if (task.step_value) |obj| {
        ffi.decref(obj);
        task.step_value = null;
    }
    if (task.wakeup_cb) |obj| {
        ffi.decref(obj);
        task.wakeup_cb = null;
    }
}

fn finishTask(slot: *LoopSlot, task_id: TaskId) void {
    const task = &slot.tasks[task_id];
    if (!task.used) return;
    clearFinishedTaskState(task);
}

fn hideTaskCoro(task: *NativeTaskSlot) void {
    if (task.coro) |obj| {
        ffi.decref(obj);
        task.coro = null;
    }
}

fn scheduleInternalCallback(slot: *LoopSlot, loop_obj: *PyObject, callback: *PyObject, arg: *PyObject, context: ?*PyObject) LoopError!void {
    const handle_id = try allocInlineCallbackHandle(slot, loop_obj, callback, arg, context);
    errdefer finishHandle(slot, handle_id, true);
    try pushReadyHandle(slot, handle_id);
}

fn scheduleTaskStep(slot: *LoopSlot, task_id: TaskId, exc: ?*PyObject) LoopError!void {
    const task = &slot.tasks[task_id];
    if (!task.used) return;
    if (exc) |obj| {
        if (task.step_exc) |old| ffi.decref(old);
        task.step_exc = obj;
        ffi.incref(obj);
    }
    if (task.scheduled) return;
    task.scheduled = true;
    try pushReadyTask(slot, task_id);
}

fn cancelTask(slot: *LoopSlot, task_id: TaskId, message: ?*PyObject) LoopError!bool {
    const task = &slot.tasks[task_id];
    if (!task.used) return false;
    if (task.core.state != .pending) return false;

    task.num_cancels_requested += 1;
    replaceOptionalPyRef(&task.core.cancel_message, message);

    if (task.fut_waiter) |waiter| {
        if (try callCancelable(waiter, message)) {
            return true;
        }
    }

    task.must_cancel = true;
    return true;
}

fn taskWakeup(handle_obj: *PyObject, task_token: TaskToken, future_obj: *PyObject) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    const task_id = try taskIdFromToken(slot, task_token);

    if (ffi.errOccurred()) ffi.errClear();
    const result_obj = callMethodNoArgs(future_obj, "result") catch {
        const saved = fetchPyError();
        defer {
            if (saved.typ) |obj| ffi.decref(obj);
            if (saved.val) |obj| ffi.decref(obj);
            if (saved.tb) |obj| ffi.decref(obj);
        }
        const exc = saved.val orelse saved.typ orelse {
            try runTaskStepByIdInContext(slot, task_id, true);
            return;
        };
        const task = &slot.tasks[task_id];
        if (!task.used) return;
        if (task.step_exc) |old| ffi.decref(old);
        task.step_exc = exc;
        ffi.incref(exc);
        try runTaskStepByIdInContext(slot, task_id, true);
        return;
    };
    ffi.decref(result_obj);
    try runTaskStepByIdInContext(slot, task_id, true);
}

fn runTaskStep(handle_obj: *PyObject, task_token: TaskToken) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    const task_id = try taskIdFromToken(slot, task_token);
    try runTaskStepById(slot, task_id);
}

fn runTaskStepById(slot: *LoopSlot, task_id: TaskId) LoopError!void {
    return runTaskStepByIdInContext(slot, task_id, false);
}

fn runTaskStepByIdInContext(slot: *LoopSlot, task_id: TaskId, task_context_entered: bool) LoopError!void {
    _ = task_context_entered;
    const task = &slot.tasks[task_id];
    if (!task.used) return;
    task.scheduled = false;

    var exc_obj: ?*PyObject = null;
    if (task.step_exc) |obj| {
        exc_obj = obj;
        task.step_exc = null;
    }
    var send_value: ?*PyObject = null;
    if (task.step_value) |obj| {
        send_value = obj;
        task.step_value = null;
    }

    const core = &task.core;
    if (core.state != .pending) {
        reportTaskStepAlreadyDone(task, exc_obj);
        if (exc_obj) |obj| ffi.decref(obj);
        if (send_value) |obj| ffi.decref(obj);
        closeTaskCoroutine(task);
        finishTask(slot, task_id);
        return;
    }

    if (task.must_cancel and exc_obj == null) {
        if (send_value) |obj| {
            ffi.decref(obj);
            send_value = null;
        }
        exc_obj = try makeCancelledError(core.cancel_message);
        task.must_cancel = false;
    }

    if (task.fut_waiter) |obj| {
        ffi.decref(obj);
        task.fut_waiter = null;
    }

    const loop_obj = core.loop_obj orelse return;
    const wrapper = core.wrapper orelse return;
    ffi.incref(loop_obj);
    defer ffi.decref(loop_obj);
    ffi.incref(wrapper);
    defer ffi.decref(wrapper);
    const prev_task = try swapCurrentTask(slot, loop_obj, wrapper);
    defer {
        const had_err = ffi.errOccurred();
        const saved_err = if (had_err) fetchPyError() else SavedPyError{};
        defer if (had_err) restorePyError(saved_err);

        const prev = if (isNone(prev_task)) null else prev_task;
        const restored = swapCurrentTask(slot, loop_obj, prev) catch blk: {
            if (ffi.errOccurred()) ffi.errClear();
            break :blk null;
        };
        if (restored) |obj| ffi.decref(obj);
        ffi.decref(prev_task);
    }

    const coro = task.coro orelse return;
    if (exc_obj) |exc| {
        if (send_value) |obj| ffi.decref(obj);
        const throw_fn = try getAttrRaw(coro, "throw");
        defer ffi.decref(throw_fn);
        const result = if (task.context) |ctx|
            callCallableOneArgInContext(ctx, throw_fn, exc) catch |err| switch (err) {
            error.PythonError => {
                const saved = fetchPyError();
                if (saved.val) |raised| {
                    if (c.PyErr_GivenExceptionMatches(raised, c.PyExc_StopIteration) != 0) {
                        const stop_value = getAttrRaw(raised, "value") catch value_blk: {
                            if (ffi.errOccurred()) ffi.errClear();
                            break :value_blk ffi.getNone();
                        };
                        defer ffi.decref(stop_value);
                        defer {
                            if (saved.typ) |obj| ffi.decref(obj);
                            if (saved.val) |obj| ffi.decref(obj);
                            if (saved.tb) |obj| ffi.decref(obj);
                        }
                        if (task.must_cancel) {
                            task.must_cancel = false;
                            _ = try cancelFutureCore(slot, core, core.cancel_message);
                        } else {
                            try setFutureResultCore(slot, core, stop_value);
                        }
                        finishTask(slot, task_id);
                        return;
                    }
                }
                restorePyError(saved);
                return handleTaskError(slot, task_id);
            },
            else => return err,
            }
        else
            callCallableOneArg(throw_fn, exc) catch |err| switch (err) {
                error.PythonError => {
                    const saved = fetchPyError();
                    if (saved.val) |raised| {
                        if (c.PyErr_GivenExceptionMatches(raised, c.PyExc_StopIteration) != 0) {
                            const stop_value = getAttrRaw(raised, "value") catch value_blk: {
                                if (ffi.errOccurred()) ffi.errClear();
                                break :value_blk ffi.getNone();
                            };
                            defer ffi.decref(stop_value);
                            defer {
                                if (saved.typ) |obj| ffi.decref(obj);
                                if (saved.val) |obj| ffi.decref(obj);
                                if (saved.tb) |obj| ffi.decref(obj);
                            }
                            if (task.must_cancel) {
                                task.must_cancel = false;
                                _ = try cancelFutureCore(slot, core, core.cancel_message);
                            } else {
                                try setFutureResultCore(slot, core, stop_value);
                            }
                            finishTask(slot, task_id);
                            return;
                        }
                    }
                    restorePyError(saved);
                    return handleTaskError(slot, task_id);
                },
                else => return err,
            };
        defer ffi.decref(result);
        try handleTaskYielded(slot, task_id, result);
        return;
    }

    const send_arg = send_value orelse ffi.getNone();
    defer ffi.decref(send_arg);
    const send = if (task.context) |ctx|
        try iterSendInContext(ctx, coro, send_arg)
    else blk: {
        const raw = ffi.iterSend(coro, send_arg);
        break :blk IterSendResult{ .result = raw.result, .status = raw.status };
    };
    switch (send.status) {
        .next => {
            const result = send.result orelse return error.PythonError;
            defer ffi.decref(result);
            try handleTaskYielded(slot, task_id, result);
        },
        .@"return" => {
            const result = send.result orelse ffi.getNone();
            defer ffi.decref(result);
            if (task.must_cancel) {
                task.must_cancel = false;
                _ = try cancelFutureCore(slot, core, core.cancel_message);
            } else {
                try setFutureResultCore(slot, core, result);
            }
            finishTask(slot, task_id);
        },
        .@"error" => return handleTaskError(slot, task_id),
    }
}

fn handleTaskError(slot: *LoopSlot, task_id: TaskId) LoopError!void {
    const task = &slot.tasks[task_id];
    const core = &task.core;
    var saved = fetchPyError();
    defer {
        if (saved.typ) |obj| ffi.decref(obj);
        if (saved.val) |obj| ffi.decref(obj);
        if (saved.tb) |obj| ffi.decref(obj);
    }
    if (saved.val) |exc| {
        const cancelled_cls = try getCancelledErrorClass();
        defer ffi.decref(cancelled_cls);
        if (c.PyErr_GivenExceptionMatches(exc, cancelled_cls) != 0) {
            moveCancelledErrorToCore(core, &saved);
            _ = try cancelFutureCore(slot, core, core.cancel_message);
            finishTask(slot, task_id);
            return;
        }
        try setFutureExceptionCore(slot, core, exc, saved.tb);
        if (c.PyErr_GivenExceptionMatches(exc, c.PyExc_KeyboardInterrupt) != 0 or c.PyErr_GivenExceptionMatches(exc, c.PyExc_SystemExit) != 0) {
            ffi.incref(exc);
            _ = raiseStoredException(exc, saved.tb) catch {};
            finishTask(slot, task_id);
            return error.PythonError;
        }
    }
    finishTask(slot, task_id);
}

fn hostYieldKind(obj: *PyObject) LoopError!?HostYieldKind {
    if (!ffi.isTuple(obj)) return null;
    const size = ffi.tupleSize(obj);
    if (size < 1) return null;
    const id_obj = ffi.tupleGetItem(obj, 0) orelse return null;
    if (c.PyLong_Check(id_obj) == 0) return null;
    const id = try ffi.longAsLong(id_obj);
    if (id >= 0 and id <= 8) return .redis;
    if (id >= 100 and id <= 102) return .pg;
    return null;
}

fn pushHostYield(
    slot: *LoopSlot,
    kind: HostYieldKind,
    task_token: TaskToken,
    conn_idx: u16,
    sentinel: *PyObject,
) LoopError!void {
    if (slot.host_yield_count >= MAX_HOST_YIELDS) return error.HostYieldQueueFull;
    const tail = (slot.host_yield_head + slot.host_yield_count) % MAX_HOST_YIELDS;
    slot.host_yields[tail] = .{
        .kind = kind,
        .task_token = task_token,
        .conn_idx = conn_idx,
        .sentinel = sentinel,
    };
    ffi.incref(sentinel);
    slot.host_yield_count += 1;
}

fn parkTaskOnFuture(slot: *LoopSlot, task_id: TaskId, future_obj: *PyObject, loop_obj: *PyObject, wrapper: *PyObject) LoopError!void {
    const task = &slot.tasks[task_id];
    if (future_obj == wrapper) {
        const exc = try runtimeError("Task cannot await on itself");
        try scheduleTaskStep(slot, task_id, exc);
        ffi.decref(exc);
        return;
    }

    const false_obj = ffi.boolFromBool(false);
    defer ffi.decref(false_obj);
    try setAttrRaw(future_obj, "_asyncio_future_blocking", false_obj);
    const wakeup_cb = try ensureTaskWakeupCallback(task, task_id);
    const add_res = try callMethodOneArg(future_obj, "add_done_callback", wakeup_cb);
    ffi.decref(add_res);
    task.fut_waiter = future_obj;
    ffi.incref(future_obj);
    if (task.must_cancel) {
        if (try callCancelable(future_obj, task.core.cancel_message)) {
            task.must_cancel = false;
        }
    }
    _ = loop_obj;
}

fn handleTaskYielded(slot: *LoopSlot, task_id: TaskId, result: *PyObject) LoopError!void {
    const task = &slot.tasks[task_id];
    const loop_obj = task.core.loop_obj orelse return;
    const wrapper = task.core.wrapper orelse return;

    if (isNone(result)) {
        try scheduleTaskStep(slot, task_id, null);
        return;
    }

    if (task.request_conn_idx != invalid_request_conn_id) {
        if (try hostYieldKind(result)) |kind| {
        const task_token = tokenForTask(slot, task_id);
        pushHostYield(slot, kind, task_token, task.request_conn_idx, result) catch |err| switch (err) {
            error.HostYieldQueueFull => {
                const exc = try runtimeError("Host yield queue is full");
                try scheduleTaskStep(slot, task_id, exc);
                ffi.decref(exc);
                return;
            },
            else => return err,
        };
        return;
        }
    }

    const blocking_attr = getAttrRaw(result, "_asyncio_future_blocking") catch blk: {
        if (ffi.errOccurred()) ffi.errClear();
        break :blk null;
    };
    if (blocking_attr) |blocking_obj| {
        defer ffi.decref(blocking_obj);
        const same_loop = try getFutureLoopMatches(result, loop_obj);
        if (!same_loop) {
            const msg = c.PyUnicode_FromFormat("Task %R got Future %R attached to a different loop", wrapper, result) orelse
                return error.PythonError;
            defer ffi.decref(msg);
            const exc = try runtimeErrorObject(msg);
            try scheduleTaskStep(slot, task_id, exc);
            ffi.decref(exc);
            return;
        }

        const truth = c.PyObject_IsTrue(blocking_obj);
        if (truth < 0) return error.PythonError;
        if (truth == 1) {
            try parkTaskOnFuture(slot, task_id, result, loop_obj, wrapper);
            return;
        }

        const exc = try runtimeError("yield was used instead of yield from in task");
        try scheduleTaskStep(slot, task_id, exc);
        ffi.decref(exc);
        return;
    }

    const inspect_mod = try importModuleRaw("inspect");
    defer ffi.decref(inspect_mod);
    const isgen = try getAttrRaw(inspect_mod, "isgenerator");
    defer ffi.decref(isgen);
    const gen_args = try ffi.tupleNew(1);
    errdefer ffi.decref(gen_args);
    try ffi.tupleSetItemTake(gen_args, 0, ffi.OwnedPy.increfBorrowed(result));
    const isgen_res = try callObjectRaw(isgen, gen_args);
    ffi.decref(gen_args);
    defer ffi.decref(isgen_res);
    const truth = c.PyObject_IsTrue(isgen_res);
    if (truth < 0) return error.PythonError;
    const msg = if (truth == 1) "yield was used instead of yield from for generator in task" else "Task got bad yield";
    const exc = try runtimeError(msg);
    try scheduleTaskStep(slot, task_id, exc);
    ffi.decref(exc);
}

fn getAsyncioTasksAttr(name: [*:0]const u8) LoopError!*PyObject {
    var tasks_mod = ffi.OwnedPy.init(try importModuleRaw("asyncio.tasks"));
    defer tasks_mod.deinit();
    return getAttrRaw(tasks_mod.get(), name);
}

fn registerTask(task_obj: *PyObject) LoopError!void {
    const task = taskObjectFromPy(task_obj);
    const type_state = task.future.type_state orelse return error.InvalidState;
    const func = type_state.register_task orelse return error.InvalidState;
    var res = ffi.OwnedPy.init(try callCallableOneArg(func, task_obj));
    defer res.deinit();
}

fn unregisterTask(task_obj: *PyObject) LoopError!void {
    const task = taskObjectFromPy(task_obj);
    const type_state = task.future.type_state orelse return error.InvalidState;
    const func = type_state.unregister_task orelse return error.InvalidState;
    var res = ffi.OwnedPy.init(try callCallableOneArg(func, task_obj));
    defer res.deinit();
}

fn enterTask(loop_obj: *PyObject, task_obj: *PyObject) LoopError!void {
    var func = ffi.OwnedPy.init(try getAsyncioTasksAttr("_enter_task"));
    defer func.deinit();
    var args = ffi.OwnedPy.init(try ffi.tupleNew(2));
    errdefer args.deinit();
    try ffi.tupleSetItemTake(args.get(), 0, ffi.OwnedPy.increfBorrowed(loop_obj));
    try ffi.tupleSetItemTake(args.get(), 1, ffi.OwnedPy.increfBorrowed(task_obj));
    var res = ffi.OwnedPy.init(try callObjectRaw(func.get(), args.get()));
    defer res.deinit();
    args.deinit();
}

fn leaveTask(loop_obj: *PyObject, task_obj: *PyObject) LoopError!void {
    var func = ffi.OwnedPy.init(try getAsyncioTasksAttr("_leave_task"));
    defer func.deinit();
    var args = ffi.OwnedPy.init(try ffi.tupleNew(2));
    errdefer args.deinit();
    try ffi.tupleSetItemTake(args.get(), 0, ffi.OwnedPy.increfBorrowed(loop_obj));
    try ffi.tupleSetItemTake(args.get(), 1, ffi.OwnedPy.increfBorrowed(task_obj));
    var res = ffi.OwnedPy.init(try callObjectRaw(func.get(), args.get()));
    defer res.deinit();
    args.deinit();
}

fn swapCurrentTask(slot: *LoopSlot, loop_obj: *PyObject, task_obj: ?*PyObject) LoopError!*PyObject {
    _ = loop_obj;
    const prev = slot.current_task orelse ffi.getNone();
    ffi.incref(prev);
    if (slot.current_task) |obj| {
        ffi.decref(obj);
        slot.current_task = null;
    }
    if (task_obj) |obj| {
        if (!isNone(obj)) {
            slot.current_task = obj;
            ffi.incref(obj);
        }
    }
    return prev;
}

fn readyTokenForHandle(handle_id: HandleId) ReadyToken {
    return handle_id;
}

fn readyTokenForTask(task_id: TaskId) ReadyToken {
    return task_ready_base + task_id;
}

fn readyTokenForCallback(cb_id: CallbackId) ReadyToken {
    return callback_ready_base + cb_id;
}

fn readyTokenIsHandle(token: ReadyToken) bool {
    return token != invalid_ready_token and token < task_ready_base;
}

fn readyTokenIsTask(token: ReadyToken) bool {
    return token >= task_ready_base and token < task_ready_base + MAX_TASKS;
}

fn readyTokenIsCallback(token: ReadyToken) bool {
    return token >= callback_ready_base and token < callback_ready_base + MAX_FUTURE_CALLBACKS;
}

fn readyHandleId(token: ReadyToken) HandleId {
    return @intCast(token);
}

fn readyTaskId(token: ReadyToken) TaskId {
    return @intCast(token - task_ready_base);
}

fn readyCallbackId(token: ReadyToken) CallbackId {
    return @intCast(token - callback_ready_base);
}

fn runReadyToken(slot: *LoopSlot, token: ReadyToken) LoopError!void {
    if (token == invalid_ready_token) return;
    if (readyTokenIsHandle(token)) {
        return runReadyHandle(slot, readyHandleId(token));
    }
    if (readyTokenIsTask(token)) {
        return runTaskStepById(slot, readyTaskId(token));
    }
    if (readyTokenIsCallback(token)) {
        return runReadyFutureCallback(slot, readyCallbackId(token));
    }
}

fn getCancelledErrorClass() LoopError!*PyObject {
    var excs = ffi.OwnedPy.init(try importModuleRaw("asyncio.exceptions"));
    defer excs.deinit();
    return getAttrRaw(excs.get(), "CancelledError");
}

fn makeCancelledError(message: ?*PyObject) LoopError!*PyObject {
    var cls = ffi.OwnedPy.init(try getCancelledErrorClass());
    defer cls.deinit();
    if (message) |msg| {
        if (!isNone(msg)) {
            return callCallableOneArg(cls.get(), msg);
        }
    }
    return callCallableNoArgs(cls.get());
}

fn raiseStoredException(exc: *PyObject, tb: ?*PyObject) LoopError!*PyObject {
    if (tb) |trace| {
        if (c.PyException_SetTraceback(exc, trace) != 0) return error.PythonError;
    }
    c.PyErr_SetRaisedException(exc);
    return error.PythonError;
}

fn getFutureLoopMatches(fut_obj: *PyObject, loop_obj: *PyObject) LoopError!bool {
    var fut_loop = ffi.OwnedPy.init(try callMethodNoArgs(fut_obj, "get_loop"));
    defer fut_loop.deinit();
    return fut_loop.get() == loop_obj;
}

fn runtimeError(msg: [*:0]const u8) LoopError!*PyObject {
    var text = ffi.OwnedPy.init(try ffi.unicodeFromString(msg));
    defer text.deinit();
    return runtimeErrorObject(text.get());
}

fn runtimeErrorObject(msg: *PyObject) LoopError!*PyObject {
    var args = ffi.OwnedPy.init(try ffi.tupleNew(1));
    errdefer args.deinit();
    try ffi.tupleSetItemTake(args.get(), 0, ffi.OwnedPy.increfBorrowed(msg));
    const res = c.PyObject_CallObject(c.PyExc_RuntimeError, args.get()) orelse return error.PythonError;
    args.deinit();
    return res;
}

fn callCancelable(obj: *PyObject, message: ?*PyObject) LoopError!bool {
    var callable = ffi.OwnedPy.init(try getAttrRaw(obj, "cancel"));
    defer callable.deinit();
    var res = ffi.OwnedPy.init(blk: {
        if (message) |msg| {
            if (!isNone(msg)) {
                break :blk try callCallableOneArg(callable.get(), msg);
            }
        }
        break :blk try callCallableNoArgs(callable.get());
    });
    defer res.deinit();
    const truth = c.PyObject_IsTrue(res.get());
    if (truth < 0) return error.PythonError;
    return truth == 1;
}

fn getRunMethodName() LoopError!*PyObject {
    return ffi.unicodeFromString("run");
}

fn isFutureObject(obj: *PyObject) LoopError!bool {
    const futures_mod = try importModuleRaw("asyncio.futures");
    defer ffi.decref(futures_mod);
    const isfuture_fn = try getAttrRaw(futures_mod, "isfuture");
    defer ffi.decref(isfuture_fn);

    const args = try ffi.tupleNew(1);
    errdefer ffi.decref(args);
    try ffi.tupleSetItemTake(args, 0, ffi.OwnedPy.increfBorrowed(obj));
    const res = try callObjectRaw(isfuture_fn, args);
    ffi.decref(args);
    defer ffi.decref(res);
    const truth = c.PyObject_IsTrue(res);
    if (truth < 0) return error.PythonError;
    return truth == 1;
}
