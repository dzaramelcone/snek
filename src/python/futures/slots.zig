const std = @import("std");
const ffi = @import("../ffi.zig");
const objects_mod = @import("objects.zig");
const runtime_mod = @import("runtime.zig");
const redis_mod = @import("redis.zig");
const pg_mod = @import("pg.zig");

const c = ffi.c;

const type_flags: c_ulong = c.Py_TPFLAGS_DEFAULT | c.Py_TPFLAGS_BASETYPE;
const gc_type_flags: c_ulong = type_flags | c.Py_TPFLAGS_HAVE_GC;

var future_methods = [_]c.PyMethodDef{
    .{ .ml_name = "cancel", .ml_meth = @ptrCast(&runtime_mod.futureCancelMethod), .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS, .ml_doc = null },
    .{ .ml_name = "cancelled", .ml_meth = @ptrCast(&runtime_mod.futureCancelledMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "done", .ml_meth = @ptrCast(&runtime_mod.futureDoneMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "result", .ml_meth = @ptrCast(&runtime_mod.futureResultMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "exception", .ml_meth = @ptrCast(&runtime_mod.futureExceptionMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "set_result", .ml_meth = @ptrCast(&runtime_mod.futureSetResultMethod), .ml_flags = c.METH_O, .ml_doc = null },
    .{ .ml_name = "set_exception", .ml_meth = @ptrCast(&runtime_mod.futureSetExceptionMethod), .ml_flags = c.METH_O, .ml_doc = null },
    std.mem.zeroes(c.PyMethodDef),
};

var task_methods = [_]c.PyMethodDef{
    .{ .ml_name = "get_coro", .ml_meth = @ptrCast(&runtime_mod.taskGetCoroMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "get_context", .ml_meth = @ptrCast(&runtime_mod.taskGetContextMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "get_name", .ml_meth = @ptrCast(&runtime_mod.taskGetNameMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "set_name", .ml_meth = @ptrCast(&runtime_mod.taskSetNameMethod), .ml_flags = c.METH_O, .ml_doc = null },
    .{ .ml_name = "cancel", .ml_meth = @ptrCast(&runtime_mod.taskCancelMethod), .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS, .ml_doc = null },
    .{ .ml_name = "cancelling", .ml_meth = @ptrCast(&runtime_mod.taskCancellingMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    .{ .ml_name = "uncancel", .ml_meth = @ptrCast(&runtime_mod.taskUncancelMethod), .ml_flags = c.METH_NOARGS, .ml_doc = null },
    std.mem.zeroes(c.PyMethodDef),
};

var future_type_slots = [_]c.PyType_Slot{
    .{ .slot = c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&runtime_mod.futureDealloc)) },
    .{ .slot = c.Py_tp_traverse, .pfunc = @ptrCast(@constCast(&runtime_mod.futureTraverse)) },
    .{ .slot = c.Py_tp_clear, .pfunc = @ptrCast(@constCast(&runtime_mod.futureClear)) },
    .{ .slot = c.Py_tp_repr, .pfunc = @ptrCast(@constCast(&runtime_mod.futureRepr)) },
    .{ .slot = c.Py_tp_methods, .pfunc = &future_methods },
    .{ .slot = c.Py_tp_new, .pfunc = @ptrCast(@constCast(&runtime_mod.futureTypeNew)) },
    .{ .slot = c.Py_tp_init, .pfunc = @ptrCast(@constCast(&runtime_mod.futureTypeInit)) },
    .{ .slot = c.Py_am_await, .pfunc = @ptrCast(@constCast(&runtime_mod.futureAwait)) },
    .{ .slot = c.Py_tp_iter, .pfunc = @ptrCast(@constCast(&runtime_mod.futureAwait)) },
    .{ .slot = c.Py_tp_doc, .pfunc = @constCast("native snek future") },
    .{ .slot = 0, .pfunc = null },
};

var task_type_slots = [_]c.PyType_Slot{
    .{ .slot = c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&runtime_mod.taskDealloc)) },
    .{ .slot = c.Py_tp_traverse, .pfunc = @ptrCast(@constCast(&runtime_mod.taskTraverse)) },
    .{ .slot = c.Py_tp_clear, .pfunc = @ptrCast(@constCast(&runtime_mod.taskClear)) },
    .{ .slot = c.Py_tp_repr, .pfunc = @ptrCast(@constCast(&runtime_mod.taskRepr)) },
    .{ .slot = c.Py_tp_methods, .pfunc = &task_methods },
    .{ .slot = c.Py_tp_new, .pfunc = @ptrCast(@constCast(&runtime_mod.taskTypeNew)) },
    .{ .slot = c.Py_tp_init, .pfunc = @ptrCast(@constCast(&runtime_mod.taskTypeInit)) },
    .{ .slot = c.Py_tp_doc, .pfunc = @constCast("native snek task") },
    .{ .slot = 0, .pfunc = null },
};

var future_iter_type_slots = [_]c.PyType_Slot{
    .{ .slot = c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&runtime_mod.futureIterDealloc)) },
    .{ .slot = c.Py_tp_iter, .pfunc = @ptrCast(@constCast(&runtime_mod.futureIterSelf)) },
    .{ .slot = c.Py_tp_iternext, .pfunc = @ptrCast(@constCast(&runtime_mod.futureIterNext)) },
    .{ .slot = c.Py_tp_doc, .pfunc = @constCast("native snek future iterator") },
    .{ .slot = 0, .pfunc = null },
};

var redis_future_type_slots = [_]c.PyType_Slot{
    .{ .slot = c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&runtime_mod.futureDealloc)) },
    .{ .slot = c.Py_tp_traverse, .pfunc = @ptrCast(@constCast(&runtime_mod.futureTraverse)) },
    .{ .slot = c.Py_tp_clear, .pfunc = @ptrCast(@constCast(&runtime_mod.futureClear)) },
    .{ .slot = c.Py_tp_doc, .pfunc = @constCast("native snek redis future") },
    .{ .slot = 0, .pfunc = null },
};

var pg_future_type_slots = [_]c.PyType_Slot{
    .{ .slot = c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&runtime_mod.futureDealloc)) },
    .{ .slot = c.Py_tp_traverse, .pfunc = @ptrCast(@constCast(&runtime_mod.futureTraverse)) },
    .{ .slot = c.Py_tp_clear, .pfunc = @ptrCast(@constCast(&runtime_mod.futureClear)) },
    .{ .slot = c.Py_tp_doc, .pfunc = @constCast("native snek postgres future") },
    .{ .slot = 0, .pfunc = null },
};

pub var future_type_spec = c.PyType_Spec{
    .name = "snek._snek.Future",
    .basicsize = @sizeOf(objects_mod.FutureObject),
    .itemsize = 0,
    .flags = gc_type_flags,
    .slots = &future_type_slots,
};

pub var task_type_spec = c.PyType_Spec{
    .name = "snek._snek.Task",
    .basicsize = @sizeOf(objects_mod.TaskObject),
    .itemsize = 0,
    .flags = gc_type_flags,
    .slots = &task_type_slots,
};

pub var future_iter_type_spec = c.PyType_Spec{
    .name = "snek._snek._FutureIter",
    .basicsize = @sizeOf(objects_mod.FutureIterObject),
    .itemsize = 0,
    .flags = c.Py_TPFLAGS_DEFAULT,
    .slots = &future_iter_type_slots,
};

pub var redis_future_type_spec = c.PyType_Spec{
    .name = "snek._snek._RedisFuture",
    .basicsize = @sizeOf(redis_mod.RedisFutureObject),
    .itemsize = 0,
    .flags = gc_type_flags,
    .slots = &redis_future_type_slots,
};

pub var pg_future_type_spec = c.PyType_Spec{
    .name = "snek._snek._PgFuture",
    .basicsize = @sizeOf(pg_mod.PgFutureObject),
    .itemsize = 0,
    .flags = gc_type_flags,
    .slots = &pg_future_type_slots,
};
