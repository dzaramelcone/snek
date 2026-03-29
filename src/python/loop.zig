const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;
const PyObject = ffi.PyObject;

pub const MAX_LOOPS: usize = 32;
pub const MAX_READY: usize = 256;
pub const MAX_SCHEDULED: usize = 256;
pub const MAX_HANDLES: usize = MAX_READY + MAX_SCHEDULED;
const HandleId = u16;
pub const HandleToken = u64;
const invalid_handle_id = std.math.maxInt(HandleId);
const loop_capsule_name: [*:0]const u8 = "snek.loop_slot";
const vectorcall_offset: usize = @as(usize, c.PY_VECTORCALL_ARGUMENTS_OFFSET);

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
};

pub const NativeHandleSlot = extern struct {
    used: bool = false,
    running: bool = false,
    cancelled: bool = false,
    is_timer: bool = false,
    generation: u32 = 0,
    when: f64 = 0,
    callback: ?*PyObject = null,
    args: ?*PyObject = null,
    context: ?*PyObject = null,
    loop_obj: ?*PyObject = null,
    wrapper: ?*PyObject = null,
};

pub const ScheduledEntry = extern struct {
    when: f64 = 0,
    seq: u64 = 0,
    handle_id: HandleId = invalid_handle_id,
};

pub const LoopSlot = extern struct {
    used: bool = false,
    closed: bool = false,
    running: bool = false,
    stopping: bool = false,
    debug: bool = false,
    ready_head: usize = 0,
    ready_len: usize = 0,
    scheduled_len: usize = 0,
    free_handle_len: usize = 0,
    sequence: u64 = 0,
    start_ns: i64 = 0,
    ready: [MAX_READY]HandleId = .{invalid_handle_id} ** MAX_READY,
    scheduled: [MAX_SCHEDULED]ScheduledEntry = .{ScheduledEntry{}} ** MAX_SCHEDULED,
    handles: [MAX_HANDLES]NativeHandleSlot = .{NativeHandleSlot{}} ** MAX_HANDLES,
    free_handles: [MAX_HANDLES]HandleId = .{invalid_handle_id} ** MAX_HANDLES,
};

const SavedPyError = struct {
    typ: ?*PyObject = null,
    val: ?*PyObject = null,
    tb: ?*PyObject = null,
};

var stop_done_callback_def = c.PyMethodDef{
    .ml_name = "snek_loop_stop_done",
    .ml_meth = @ptrCast(&stopDoneCallback),
    .ml_flags = c.METH_O,
    .ml_doc = null,
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

pub fn initSlots(slots: *[MAX_LOOPS]LoopSlot) void {
    for (slots) |*slot| {
        slot.* = .{};
        initHandlePool(slot);
    }
}

pub fn clearAllSlots(slots: *[MAX_LOOPS]LoopSlot) void {
    for (slots) |*slot| clearSlot(slot, true);
}

pub fn newLoop(slots: *[MAX_LOOPS]LoopSlot) LoopError!*PyObject {
    for (slots) |*slot| {
        if (slot.used) continue;
        slot.* = .{};
        initHandlePool(slot);
        slot.used = true;
        slot.start_ns = @intCast(std.time.nanoTimestamp());
        return c.PyCapsule_New(slot, loop_capsule_name, null) orelse error.PythonError;
    }
    return error.TooManyLoops;
}

pub fn freeLoop(handle_obj: *PyObject) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.running) return error.LoopRunning;
    clearSlot(slot, true);
}

pub fn isClosed(handle_obj: *PyObject) LoopError!bool {
    return (try slotFromCapsule(handle_obj)).closed;
}

pub fn isRunning(handle_obj: *PyObject) LoopError!bool {
    return (try slotFromCapsule(handle_obj)).running;
}

pub fn closeLoop(handle_obj: *PyObject) LoopError!void {
    const slot = try slotFromCapsule(handle_obj);
    if (slot.closed) return;
    if (slot.running) return error.LoopRunning;
    clearLoopQueues(slot);
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

    if (try futureDone(target)) {
        return callMethodNoArgs(target, "result");
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

        if (new_task and (futureDone(target) catch false) and !(futureCancelled(target) catch false)) {
            const exc_obj = callMethodNoArgs(target, "exception") catch blk: {
                if (ffi.errOccurred()) ffi.errClear();
                break :blk null;
            };
            if (exc_obj) |obj| ffi.decref(obj);
        }
        return err;
    };

    if (!try futureDone(target)) return error.EventLoopStoppedBeforeFutureCompleted;
    return callMethodNoArgs(target, "result");
}

fn slotFromCapsule(handle_obj: *PyObject) LoopError!*LoopSlot {
    const raw = c.PyCapsule_GetPointer(handle_obj, loop_capsule_name);
    if (raw == null) return error.InvalidLoopHandle;
    return @ptrCast(@alignCast(raw));
}

fn initHandlePool(slot: *LoopSlot) void {
    slot.free_handle_len = MAX_HANDLES;
    for (0..MAX_HANDLES) |i| {
        slot.free_handles[i] = @intCast(MAX_HANDLES - 1 - i);
    }
}

fn clearLoopQueues(slot: *LoopSlot) void {
    var n: usize = 0;
    while (n < slot.ready_len) : (n += 1) {
        const idx = (slot.ready_head + n) % MAX_READY;
        cancelNativeHandle(slot, slot.ready[idx]);
        slot.ready[idx] = invalid_handle_id;
    }
    slot.ready_head = 0;
    slot.ready_len = 0;

    n = 0;
    while (n < slot.scheduled_len) : (n += 1) {
        cancelNativeHandle(slot, slot.scheduled[n].handle_id);
        slot.scheduled[n] = .{};
    }
    slot.scheduled_len = 0;
}

fn clearSlot(slot: *LoopSlot, free_slot: bool) void {
    clearLoopQueues(slot);
    slot.closed = free_slot;
    if (free_slot) {
        slot.* = .{};
    }
}

fn slotTime(slot: *const LoopSlot) f64 {
    const now: i128 = std.time.nanoTimestamp();
    const elapsed = now - slot.start_ns;
    return @as(f64, @floatFromInt(elapsed)) / @as(f64, std.time.ns_per_s);
}

fn allocHandle(
    slot: *LoopSlot,
    loop_obj: *PyObject,
    wrapper_obj: *PyObject,
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
        .context = if (context != null and !isNone(context.?)) context else null,
        .loop_obj = loop_obj,
        .wrapper = wrapper_obj,
    };
    ffi.incref(loop_obj);
    ffi.incref(wrapper_obj);
    ffi.incref(callback);
    ffi.incref(call_args);
    if (native.context) |ctx| ffi.incref(ctx);
    return handle_id;
}

fn pushReadyHandle(slot: *LoopSlot, handle_id: HandleId) LoopError!void {
    try ensureReadyCapacity(slot);
    const tail = (slot.ready_head + slot.ready_len) % MAX_READY;
    slot.ready[tail] = handle_id;
    slot.ready_len += 1;
}

fn pushReadyOwned(slot: *LoopSlot, handle_id: HandleId) LoopError!void {
    try ensureReadyCapacity(slot);
    const tail = (slot.ready_head + slot.ready_len) % MAX_READY;
    slot.ready[tail] = handle_id;
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

    var compacted: [MAX_READY]HandleId = .{invalid_handle_id} ** MAX_READY;
    var write_idx: usize = 0;
    var n: usize = 0;
    while (n < slot.ready_len) : (n += 1) {
        const idx = (slot.ready_head + n) % MAX_READY;
        const handle_id = slot.ready[idx];
        if (handle_id == invalid_handle_id) continue;
        compacted[write_idx] = handle_id;
        slot.ready[idx] = invalid_handle_id;
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
        const handle_id = slot.ready[idx];
        if (handle_id == invalid_handle_id) continue;
        if (@as(usize, handle_id) >= MAX_HANDLES) continue;
        const native = &slot.handles[handle_id];
        if (!native.used or native.callback != callback) continue;
        cancelNativeHandle(slot, handle_id);
        slot.ready[idx] = invalid_handle_id;
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
                if (ns > 0) std.Thread.sleep(ns);
            }
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        next_when = try drainScheduled(slot, slotTime(slot));
    }

    const ntodo = slot.ready_len;
    var i: usize = 0;
    while (i < ntodo) : (i += 1) {
        const idx = slot.ready_head;
        const handle_id = slot.ready[idx];
        slot.ready[idx] = invalid_handle_id;
        slot.ready_head = (slot.ready_head + 1) % MAX_READY;
        slot.ready_len -= 1;

        try runReadyHandle(slot, handle_id);
    }

    if (slot.ready_len == 0) {
        slot.ready_head = 0;
    }
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

fn invokeNativeHandle(native: *NativeHandleSlot) LoopError!*PyObject {
    const callback = native.callback orelse return ffi.getNone();
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
    const events_mod = try importModuleRaw("asyncio.events");
    defer ffi.decref(events_mod);
    const func = try getAttrRaw(events_mod, "_get_running_loop");
    defer ffi.decref(func);
    return callObjectRaw(func, null);
}

fn setRunningLoop(loop_obj: *PyObject) LoopError!void {
    const events_mod = try importModuleRaw("asyncio.events");
    defer ffi.decref(events_mod);
    const func = try getAttrRaw(events_mod, "_set_running_loop");
    defer ffi.decref(func);
    const args = try ffi.tupleNew(1);
    errdefer ffi.decref(args);
    ffi.incref(loop_obj);
    try ffi.tupleSetItem(args, 0, loop_obj);
    const res = try callObjectRaw(func, args);
    ffi.decref(args);
    ffi.decref(res);
}

fn getCoroutineOriginTrackingDepth() LoopError!c_long {
    const sys_mod = try importModuleRaw("sys");
    defer ffi.decref(sys_mod);
    const func = try getAttrRaw(sys_mod, "get_coroutine_origin_tracking_depth");
    defer ffi.decref(func);
    const res = try callObjectRaw(func, null);
    defer ffi.decref(res);
    return ffi.longAsLong(res);
}

fn setCoroutineOriginTrackingDepth(depth: c_long) LoopError!void {
    const sys_mod = try importModuleRaw("sys");
    defer ffi.decref(sys_mod);
    const func = try getAttrRaw(sys_mod, "set_coroutine_origin_tracking_depth");
    defer ffi.decref(func);
    const args = try ffi.tupleNew(1);
    errdefer ffi.decref(args);
    try ffi.tupleSetItem(args, 0, try ffi.longFromLong(depth));
    const res = try callObjectRaw(func, args);
    ffi.decref(args);
    ffi.decref(res);
}

fn ensureFuture(loop_obj: *PyObject, future_obj: *PyObject) LoopError!*PyObject {
    const asyncio = try importModuleRaw("asyncio");
    defer ffi.decref(asyncio);
    const ensure_future_fn = try getAttrRaw(asyncio, "ensure_future");
    defer ffi.decref(ensure_future_fn);

    const args = try ffi.tupleNew(1);
    errdefer ffi.decref(args);
    ffi.incref(future_obj);
    try ffi.tupleSetItem(args, 0, future_obj);

    const kwargs = try ffi.dictNew();
    errdefer ffi.decref(kwargs);
    try ffi.dictSetItemString(kwargs, "loop", loop_obj);

    const target = try callObjectKwargsRaw(ensure_future_fn, args, kwargs);
    ffi.decref(args);
    ffi.decref(kwargs);
    return target;
}

fn futureDone(future_obj: *PyObject) LoopError!bool {
    const res = try callMethodNoArgs(future_obj, "done");
    defer ffi.decref(res);
    const truth = c.PyObject_IsTrue(res);
    if (truth < 0) return error.PythonError;
    return truth == 1;
}

fn futureCancelled(future_obj: *PyObject) LoopError!bool {
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

            ffi.incref(callback);
            try ffi.tupleSetItem(call_args, 0, callback);
            for (0..nargs) |i| {
                const item = ffi.tupleGetItem(args, @intCast(i)) orelse return error.PythonError;
                ffi.incref(item);
                try ffi.tupleSetItem(call_args, @intCast(i + 1), item);
            }

            const result = try callObjectRaw(run_fn, call_args);
            ffi.decref(call_args);
            break :blk result;
        },
    };
}

fn callMethodNoArgs(obj: *PyObject, method: [*:0]const u8) LoopError!*PyObject {
    const callable = try getAttrRaw(obj, method);
    defer ffi.decref(callable);
    return callObjectRaw(callable, null);
}

fn callMethodOneArg(obj: *PyObject, method: [*:0]const u8, arg: *PyObject) LoopError!*PyObject {
    const callable = try getAttrRaw(obj, method);
    defer ffi.decref(callable);
    const args = try ffi.tupleNew(1);
    errdefer ffi.decref(args);
    ffi.incref(arg);
    try ffi.tupleSetItem(args, 0, arg);
    const res = try callObjectRaw(callable, args);
    ffi.decref(args);
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
    const helpers_mod = try importModuleRaw("asyncio.format_helpers");
    defer ffi.decref(helpers_mod);
    const func = try getAttrRaw(helpers_mod, "_format_callback_source");
    defer ffi.decref(func);

    const call_args = try ffi.tupleNew(2);
    errdefer ffi.decref(call_args);
    ffi.incref(callback);
    try ffi.tupleSetItem(call_args, 0, callback);
    ffi.incref(args);
    try ffi.tupleSetItem(call_args, 1, args);

    const kwargs = try ffi.dictNew();
    errdefer ffi.decref(kwargs);
    const debug_obj = ffi.boolFromBool(debug);
    defer ffi.decref(debug_obj);
    try ffi.dictSetItemString(kwargs, "debug", debug_obj);

    const result = try callObjectKwargsRaw(func, call_args, kwargs);
    ffi.decref(call_args);
    ffi.decref(kwargs);
    return result;
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

fn getRunMethodName() LoopError!*PyObject {
    const Holder = struct {
        var obj: ?*PyObject = null;
    };
    if (Holder.obj == null) {
        Holder.obj = try ffi.unicodeFromString("run");
    }
    return Holder.obj.?;
}

fn isFutureObject(obj: *PyObject) LoopError!bool {
    const futures_mod = try importModuleRaw("asyncio.futures");
    defer ffi.decref(futures_mod);
    const isfuture_fn = try getAttrRaw(futures_mod, "isfuture");
    defer ffi.decref(isfuture_fn);

    const args = try ffi.tupleNew(1);
    errdefer ffi.decref(args);
    ffi.incref(obj);
    try ffi.tupleSetItem(args, 0, obj);
    const res = try callObjectRaw(isfuture_fn, args);
    ffi.decref(args);
    defer ffi.decref(res);
    const truth = c.PyObject_IsTrue(res);
    if (truth < 0) return error.PythonError;
    return truth == 1;
}
