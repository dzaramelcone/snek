const std = @import("std");
const ffi = @import("../ffi.zig");
const objects_mod = @import("objects.zig");
const redis_mod = @import("redis.zig");
const pg_mod = @import("pg.zig");

const c = ffi.c;
const PyObject = ffi.PyObject;

pub const TypeState = objects_mod.TypeState;
pub const FutureObject = objects_mod.FutureObject;
pub const RedisFutureObject = redis_mod.RedisFutureObject;
pub const PgFutureObject = pg_mod.PgFutureObject;
pub const TaskObject = objects_mod.TaskObject;
pub const FutureIterObject = objects_mod.FutureIterObject;
pub const SubmittedYield = objects_mod.SubmittedYield;
pub const StmtCache = objects_mod.StmtCache;
pub const MAX_PG_STMTS = objects_mod.MAX_PG_STMTS;

pub fn clearOptional(obj: *?*PyObject) void {
    if (obj.*) |owned| ffi.decref(owned);
    obj.* = null;
}

fn clearFutureBase(self: *FutureObject) void {
    clearOptional(&self.result);
    clearOptional(&self.exception);
    clearOptional(&self.exception_tb);
    clearOptional(&self.cancel_message);
    self.type_state = null;
    self.state = .pending;
    self.submitted = false;
    self.submit_fn = null;
    self.traverse_extra_fn = null;
    self.clear_extra_fn = null;
}

pub fn futureTraverse(self_obj: ?*PyObject, visit: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return 0));
    if (self.result) |owned| {
        const rc = visit.?(@ptrCast(@constCast(owned)), arg);
        if (rc != 0) return rc;
    }
    if (self.exception) |owned| {
        const rc = visit.?(@ptrCast(@constCast(owned)), arg);
        if (rc != 0) return rc;
    }
    if (self.exception_tb) |owned| {
        const rc = visit.?(@ptrCast(@constCast(owned)), arg);
        if (rc != 0) return rc;
    }
    if (self.cancel_message) |owned| {
        const rc = visit.?(@ptrCast(@constCast(owned)), arg);
        if (rc != 0) return rc;
    }
    if (self.traverse_extra_fn) |extra| return extra(self, visit, arg);
    return 0;
}

pub fn taskTraverse(self_obj: ?*PyObject, visit: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    if (futureTraverse(self_obj, visit, arg) != 0) return -1;
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return 0));
    if (self.coro) |owned| {
        const rc = visit.?(@ptrCast(@constCast(owned)), arg);
        if (rc != 0) return rc;
    }
    if (self.context) |owned| {
        const rc = visit.?(@ptrCast(@constCast(owned)), arg);
        if (rc != 0) return rc;
    }
    if (self.name) |owned| return visit.?(@ptrCast(@constCast(owned)), arg);
    return 0;
}

pub fn futureClear(self_obj: ?*PyObject) callconv(.c) c_int {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return 0));
    if (self.clear_extra_fn) |clear| clear(self);
    clearFutureBase(self);
    return 0;
}

pub fn taskClear(self_obj: ?*PyObject) callconv(.c) c_int {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return 0));
    clearOptional(&self.coro);
    clearOptional(&self.context);
    clearOptional(&self.name);
    _ = futureClear(@ptrCast(self));
    self.num_cancels_requested = 0;
    return 0;
}

pub fn futureDealloc(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const self: *FutureObject = @ptrCast(@alignCast(obj));
    c.PyObject_GC_UnTrack(obj);
    c.PyObject_ClearWeakRefs(obj);
    _ = futureClear(obj);
    const tp: *c.PyTypeObject = @ptrCast(@alignCast(self.ob_base.ob_type));
    tp.tp_free.?(@ptrCast(self));
}

pub fn taskDealloc(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const self: *TaskObject = @ptrCast(@alignCast(obj));
    c.PyObject_GC_UnTrack(obj);
    c.PyObject_ClearWeakRefs(obj);
    _ = taskClear(obj);
    const tp: *c.PyTypeObject = @ptrCast(@alignCast(self.future.ob_base.ob_type));
    tp.tp_free.?(@ptrCast(self));
}

pub fn futureIterDealloc(self_obj: ?*PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const self: *FutureIterObject = @ptrCast(@alignCast(obj));
    clearOptional(&self.future);
    const tp: *c.PyTypeObject = @ptrCast(@alignCast(self.ob_base.ob_type));
    tp.tp_free.?(@ptrCast(self));
}

pub fn futureIterSelf(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    ffi.incref(obj);
    return obj;
}

fn makeCancelledError(message: ?*PyObject) ?*PyObject {
    const excs = ffi.importModuleRaw("asyncio.exceptions") catch return null;
    defer ffi.decref(excs);
    const cancelled = ffi.getAttrRaw(excs, "CancelledError") catch return null;
    defer ffi.decref(cancelled);
    if (message) |msg| {
        const args = ffi.tupleNew(1) catch return null;
        errdefer ffi.decref(args);
        ffi.tupleSetItem(args, 0, ffi.increfBorrowed(msg)) catch return null;
        const exc = ffi.callObjectRaw(cancelled, args) catch return null;
        ffi.decref(args);
        return exc;
    }
    return ffi.callObjectRaw(cancelled, null) catch return null;
}

fn raiseStoredException(exc: *PyObject) ?*PyObject {
    const exc_type: *PyObject = @ptrCast(@alignCast(c.Py_TYPE(exc)));
    c.PyErr_SetObject(exc_type, exc);
    return null;
}

pub fn futureIterNext(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse return null;
    const self: *FutureIterObject = @ptrCast(@alignCast(obj));
    const future_obj = self.future orelse return null;
    const future: *FutureObject = @ptrCast(@alignCast(future_obj));

    if (!self.yielded and future.state == .pending) {
        self.yielded = true;
        ffi.incref(future_obj);
        return future_obj;
    }

    if (future.state == .pending) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "await wasn't used with future");
        return null;
    }

    if (future.state == .cancelled) {
        const cancelled = makeCancelledError(future.cancel_message) orelse return null;
        defer ffi.decref(cancelled);
        return raiseStoredException(cancelled);
    }
    if (future.exception) |exc| return raiseStoredException(exc);

    c.PyErr_SetObject(c.PyExc_StopIteration, future.result orelse ffi.none());
    return null;
}

pub fn futureAwait(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const obj = self_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "missing future");
        return null;
    };
    const future: *FutureObject = @ptrCast(@alignCast(obj));
    const type_state = future.type_state orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "future type state missing");
        return null;
    };
    const iter_type = type_state.future_iter_type orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "future iterator type missing");
        return null;
    };
    const iter_tp: *c.PyTypeObject = @ptrCast(@alignCast(iter_type));
    const raw = iter_tp.tp_alloc.?(iter_tp, 0) orelse return null;
    const iter: *FutureIterObject = @ptrCast(@alignCast(raw));
    iter.future = ffi.increfBorrowed(obj);
    iter.yielded = false;
    return @ptrCast(iter);
}

pub fn futureDoneMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    return ffi.boolFromBool(self.state != .pending);
}

pub fn futureCancelledMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    return ffi.boolFromBool(self.state == .cancelled);
}

pub fn futureResultMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    switch (self.state) {
        .pending => {
            c.PyErr_SetString(c.PyExc_RuntimeError, "Result is not set.");
            return null;
        },
        .cancelled => {
            const cancelled = makeCancelledError(self.cancel_message) orelse return null;
            defer ffi.decref(cancelled);
            return raiseStoredException(cancelled);
        },
        .finished => {},
    }
    if (self.exception) |exc| return raiseStoredException(exc);
    if (self.result) |result| {
        ffi.incref(result);
        return result;
    }
    return ffi.getNone();
}

pub fn futureExceptionMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    switch (self.state) {
        .pending => {
            c.PyErr_SetString(c.PyExc_RuntimeError, "Exception is not set.");
            return null;
        },
        .cancelled => {
            const cancelled = makeCancelledError(self.cancel_message) orelse return null;
            defer ffi.decref(cancelled);
            return raiseStoredException(cancelled);
        },
        .finished => {},
    }
    if (self.exception) |exc| {
        ffi.incref(exc);
        return exc;
    }
    return ffi.getNone();
}

pub fn futureCancelMethod(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) ?*PyObject {
    _ = kwargs;
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    if (self.state != .pending) return ffi.boolFromBool(false);
    if (args) |tuple| {
        if (!ffi.isTuple(tuple) or ffi.tupleSize(tuple) > 1) {
            c.PyErr_SetString(c.PyExc_TypeError, "cancel() expects at most one argument");
            return null;
        }
        if (ffi.tupleSize(tuple) == 1) {
            clearOptional(&self.cancel_message);
            self.cancel_message = ffi.increfBorrowed(ffi.tupleGetItem(tuple, 0) orelse return null);
        }
    }
    self.state = .cancelled;
    return ffi.boolFromBool(true);
}

fn coerceException(value: *PyObject) ?*PyObject {
    if (c.PyType_Check(value) != 0) return ffi.callObjectRaw(value, null) catch null;
    ffi.incref(value);
    return value;
}

pub fn futureSetResultMethod(self_obj: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    if (self.state != .pending) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "Future already done");
        return null;
    }
    clearOptional(&self.result);
    clearOptional(&self.exception);
    clearOptional(&self.exception_tb);
    self.result = ffi.increfBorrowed(arg orelse ffi.none());
    self.state = .finished;
    return ffi.getNone();
}

pub fn futureSetExceptionMethod(self_obj: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    const value = arg orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "set_exception() missing exception");
        return null;
    };
    if (self.state != .pending) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "Future already done");
        return null;
    }
    const exc = coerceException(value) orelse return null;
    clearOptional(&self.result);
    clearOptional(&self.exception);
    clearOptional(&self.exception_tb);
    self.exception = exc;
    self.state = .finished;
    return ffi.getNone();
}

pub fn futureRepr(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj orelse return null));
    const state_name = switch (self.state) {
        .pending => "pending",
        .cancelled => "cancelled",
        .finished => if (self.exception != null) "errored" else "finished",
    };
    var buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "<_snek.Future state={s}>", .{state_name}) catch return null;
    return ffi.unicodeFromSlice(text.ptr, text.len) catch null;
}

pub fn taskGetCoroMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    if (self.coro) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return ffi.getNone();
}

pub fn taskGetContextMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    if (self.context) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return ffi.getNone();
}

pub fn taskGetNameMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    if (self.name) |obj| {
        ffi.incref(obj);
        return obj;
    }
    return ffi.getNone();
}

pub fn taskSetNameMethod(self_obj: ?*PyObject, arg: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    const value = arg orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "set_name() missing value");
        return null;
    };
    clearOptional(&self.name);
    if (ffi.isString(value)) {
        self.name = ffi.increfBorrowed(value);
    } else {
        self.name = ffi.objectStr(value) catch return null;
    }
    return ffi.getNone();
}

pub fn taskCancelMethod(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    self.num_cancels_requested += 1;
    return futureCancelMethod(@ptrCast(self), args, kwargs);
}

pub fn taskCancellingMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    return ffi.longFromLong(@intCast(self.num_cancels_requested)) catch null;
}

pub fn taskUncancelMethod(self_obj: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    if (self.num_cancels_requested > 0) self.num_cancels_requested -= 1;
    return ffi.longFromLong(@intCast(self.num_cancels_requested)) catch null;
}

pub fn taskRepr(self_obj: ?*PyObject) callconv(.c) ?*PyObject {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj orelse return null));
    var buf: [128]u8 = undefined;
    const name = if (self.name) |obj| std.mem.span(ffi.unicodeAsUTF8(obj) catch "task") else "task";
    const text = std.fmt.bufPrint(&buf, "<_snek.Task name={s}>", .{name}) catch return null;
    return ffi.unicodeFromSlice(text.ptr, text.len) catch null;
}

fn typeStateFromObject(obj: *PyObject) ffi.PythonError!*TypeState {
    const raw = try ffi.typeGetModuleState(c.Py_TYPE(obj));
    return @ptrCast(@alignCast(raw));
}

const FutureInitError = ffi.PythonError || error{
    FutureArgsMustBeTuple,
    FutureTakesNoPositionalArgs,
    FutureKwargsMustBeDict,
    FutureUnexpectedKeyword,
};

const TaskInitError = ffi.PythonError || error{
    TaskMissingCoroutine,
    TaskArgsMustBeTuple,
    TaskTakesExactlyOnePositionalArg,
    TaskKwargsMustBeDict,
    TaskUnexpectedKeyword,
};

fn initConstructedFuture(self_obj: *PyObject, args: ?*PyObject, kwargs: ?*PyObject) FutureInitError!void {
    const self: *FutureObject = @ptrCast(@alignCast(self_obj));
    if (args) |tuple| {
        if (!ffi.isTuple(tuple)) return error.FutureArgsMustBeTuple;
        if (ffi.tupleSize(tuple) != 0) return error.FutureTakesNoPositionalArgs;
    }
    if (kwargs) |kw| {
        if (!ffi.isDict(kw)) return error.FutureKwargsMustBeDict;
        const kw_loop = ffi.dictGetItemString(kw, "loop");
        const allowed: isize = if (kw_loop != null) 1 else 0;
        if (ffi.dictSize(kw) != allowed) return error.FutureUnexpectedKeyword;
    }

    _ = futureClear(self_obj);
    self.type_state = try typeStateFromObject(self_obj);
}

fn initConstructedTask(self_obj: *PyObject, args: ?*PyObject, kwargs: ?*PyObject) TaskInitError!void {
    const self: *TaskObject = @ptrCast(@alignCast(self_obj));
    const tuple = args orelse return error.TaskMissingCoroutine;
    if (!ffi.isTuple(tuple)) return error.TaskArgsMustBeTuple;
    if (ffi.tupleSize(tuple) != 1) return error.TaskTakesExactlyOnePositionalArg;
    if (kwargs) |kw| {
        if (!ffi.isDict(kw)) return error.TaskKwargsMustBeDict;
    }

    _ = taskClear(self_obj);

    self.future.type_state = try typeStateFromObject(self_obj);
    self.coro = ffi.increfBorrowed(ffi.tupleGetItem(tuple, 0).?);

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
        if (ffi.dictSize(kw) != allowed) return error.TaskUnexpectedKeyword;
        if (kw_context) |ctx| self.context = ffi.increfBorrowed(ctx);
        if (kw_name) |name| {
            if (ffi.isString(name)) {
                self.name = ffi.increfBorrowed(name);
            } else {
                self.name = try ffi.objectStr(name);
            }
        }
    }
}

pub fn futureTypeNew(tp_obj: ?*c.PyTypeObject, _: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const tp = tp_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "future type is null");
        return null;
    };
    return tp.tp_alloc.?(tp, 0);
}

fn setUnhandledInitError(err: anyerror) c_int {
    if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
    return -1;
}

pub fn futureTypeInit(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) c_int {
    initConstructedFuture(self_obj orelse return -1, args, kwargs) catch |err| switch (err) {
        error.FutureArgsMustBeTuple => {
            c.PyErr_SetString(c.PyExc_TypeError, "Future() arguments must be a tuple");
            return -1;
        },
        error.FutureTakesNoPositionalArgs => {
            c.PyErr_SetString(c.PyExc_TypeError, "Future() takes no positional arguments");
            return -1;
        },
        error.FutureKwargsMustBeDict => {
            c.PyErr_SetString(c.PyExc_TypeError, "Future() keyword arguments must be a dict");
            return -1;
        },
        error.FutureUnexpectedKeyword => {
            c.PyErr_SetString(c.PyExc_TypeError, "Future() got an unexpected keyword argument");
            return -1;
        },
        error.ModuleStateError => {
            c.PyErr_SetString(c.PyExc_RuntimeError, "future type state missing");
            return -1;
        },
        else => return setUnhandledInitError(err),
    };
    return 0;
}

pub fn taskTypeNew(tp_obj: ?*c.PyTypeObject, _: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    const tp = tp_obj orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "task type is null");
        return null;
    };
    return tp.tp_alloc.?(tp, 0);
}

pub fn taskTypeInit(self_obj: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) c_int {
    initConstructedTask(self_obj orelse return -1, args, kwargs) catch |err| switch (err) {
        error.TaskMissingCoroutine => {
            c.PyErr_SetString(c.PyExc_TypeError, "Task() missing coroutine");
            return -1;
        },
        error.TaskArgsMustBeTuple => {
            c.PyErr_SetString(c.PyExc_TypeError, "Task() arguments must be a tuple");
            return -1;
        },
        error.TaskTakesExactlyOnePositionalArg => {
            c.PyErr_SetString(c.PyExc_TypeError, "Task() takes exactly one positional argument");
            return -1;
        },
        error.TaskKwargsMustBeDict => {
            c.PyErr_SetString(c.PyExc_TypeError, "Task() keyword arguments must be a dict");
            return -1;
        },
        error.TaskUnexpectedKeyword => {
            c.PyErr_SetString(c.PyExc_TypeError, "Task() got an unexpected keyword argument");
            return -1;
        },
        error.ModuleStateError => {
            c.PyErr_SetString(c.PyExc_RuntimeError, "task type state missing");
            return -1;
        },
        else => return setUnhandledInitError(err),
    };
    return 0;
}

pub fn allocFutureLike(comptime T: type, type_obj: *PyObject, type_state: *TypeState) ffi.PythonError!*T {
    const tp: *c.PyTypeObject = @ptrCast(@alignCast(type_obj));
    const raw = tp.tp_alloc.?(tp, 0) orelse return error.PythonError;
    const self: *T = @ptrCast(@alignCast(raw));
    switch (T) {
        FutureObject => {
            const ob_base = self.ob_base;
            self.* = std.mem.zeroes(T);
            self.ob_base = ob_base;
            self.type_state = type_state;
        },
        RedisFutureObject => {
            const ob_base = self.future.ob_base;
            self.* = std.mem.zeroes(T);
            self.future.ob_base = ob_base;
            self.future.type_state = type_state;
        },
        PgFutureObject => {
            const ob_base = self.future.ob_base;
            self.* = std.mem.zeroes(T);
            self.future.ob_base = ob_base;
            self.future.type_state = type_state;
        },
        TaskObject => {
            const ob_base = self.future.ob_base;
            self.* = std.mem.zeroes(T);
            self.future.ob_base = ob_base;
            self.future.type_state = type_state;
        },
        else => {},
    }
    return self;
}

pub fn isManagedFuture(type_state: *const TypeState, obj: *PyObject) bool {
    const future_type = type_state.future_type orelse return false;
    const future_tp: *c.PyTypeObject = @ptrCast(@alignCast(future_type));
    return c.PyType_IsSubtype(c.Py_TYPE(obj), future_tp) != 0;
}

pub fn consumeYield(
    type_state: *TypeState,
    yielded: *PyObject,
    py_coro: *PyObject,
    redis_buf: ?[]u8,
    pg_buf: ?[]u8,
    pg_stmt_cache: ?*StmtCache,
    pg_conn_prepared: ?*[MAX_PG_STMTS]bool,
) !SubmittedYield {
    if (!isManagedFuture(type_state, yielded)) return error.UnknownFutureType;
    const future: *FutureObject = @ptrCast(@alignCast(yielded));
    const submit_fn = future.submit_fn orelse return error.UnknownFutureType;
    if (future.state != .pending or future.submitted) return error.UnknownFutureState;
    future.submitted = true;
    return submit_fn(future, py_coro, yielded, redis_buf, pg_buf, pg_stmt_cache, pg_conn_prepared);
}

pub fn setResult(obj: *PyObject, result: *PyObject) !void {
    const future: *FutureObject = @ptrCast(@alignCast(obj));
    if (future.state != .pending) return error.InvalidFutureState;
    clearOptional(&future.result);
    clearOptional(&future.exception);
    clearOptional(&future.exception_tb);
    future.result = ffi.increfBorrowed(result);
    future.state = .finished;
}

pub fn setException(obj: *PyObject, exc: *PyObject) !void {
    const future: *FutureObject = @ptrCast(@alignCast(obj));
    if (future.state != .pending) return error.InvalidFutureState;
    const owned = coerceException(exc) orelse return error.PythonError;
    clearOptional(&future.result);
    clearOptional(&future.exception);
    clearOptional(&future.exception_tb);
    future.exception = owned;
    future.state = .finished;
}
