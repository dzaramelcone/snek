const ffi = @import("../ffi.zig");
const c = ffi.c;
const PyObject = ffi.PyObject;

pub const TypeState = extern struct {
    future_type: ?*PyObject = null,
    task_type: ?*PyObject = null,
    future_iter_type: ?*PyObject = null,
    redis_future_type: ?*PyObject = null,
    pg_future_type: ?*PyObject = null,
};

pub fn initTypes(
    mod: *PyObject,
    type_state: *TypeState,
    future_type_spec: *c.PyType_Spec,
    task_type_spec: *c.PyType_Spec,
    future_iter_type_spec: *c.PyType_Spec,
    redis_future_type_spec: *c.PyType_Spec,
    pg_future_type_spec: *c.PyType_Spec,
    future_weaklist_offset: usize,
) ffi.PythonError!void {
    clearTypes(type_state);

    const future_iter_type = c.PyType_FromModuleAndSpec(mod, future_iter_type_spec, null) orelse return error.PythonError;
    errdefer ffi.decref(future_iter_type);

    const future_type = c.PyType_FromModuleAndSpec(mod, future_type_spec, null) orelse return error.PythonError;
    errdefer ffi.decref(future_type);
    const future_tp: *c.PyTypeObject = @ptrCast(@alignCast(future_type));
    future_tp.tp_weaklistoffset = @intCast(future_weaklist_offset);

    const task_bases = try makeSingleBaseTuple(future_type);
    defer ffi.decref(task_bases);
    const task_type = c.PyType_FromModuleAndSpec(mod, task_type_spec, task_bases) orelse return error.PythonError;
    errdefer ffi.decref(task_type);
    const task_tp: *c.PyTypeObject = @ptrCast(@alignCast(task_type));
    task_tp.tp_weaklistoffset = @intCast(future_weaklist_offset);

    const redis_bases = try makeSingleBaseTuple(future_type);
    defer ffi.decref(redis_bases);
    const redis_future_type = c.PyType_FromModuleAndSpec(mod, redis_future_type_spec, redis_bases) orelse return error.PythonError;
    errdefer ffi.decref(redis_future_type);
    const redis_tp: *c.PyTypeObject = @ptrCast(@alignCast(redis_future_type));
    redis_tp.tp_weaklistoffset = @intCast(future_weaklist_offset);

    const pg_bases = try makeSingleBaseTuple(future_type);
    defer ffi.decref(pg_bases);
    const pg_future_type = c.PyType_FromModuleAndSpec(mod, pg_future_type_spec, pg_bases) orelse return error.PythonError;
    errdefer ffi.decref(pg_future_type);
    const pg_tp: *c.PyTypeObject = @ptrCast(@alignCast(pg_future_type));
    pg_tp.tp_weaklistoffset = @intCast(future_weaklist_offset);

    try ffi.setAttrRaw(mod, "Future", future_type);
    try ffi.setAttrRaw(mod, "Task", task_type);

    type_state.future_type = future_type;
    type_state.task_type = task_type;
    type_state.future_iter_type = future_iter_type;
    type_state.redis_future_type = redis_future_type;
    type_state.pg_future_type = pg_future_type;
}

pub fn clearTypes(type_state: *TypeState) void {
    if (type_state.future_iter_type) |obj| ffi.decref(obj);
    if (type_state.future_type) |obj| ffi.decref(obj);
    if (type_state.task_type) |obj| ffi.decref(obj);
    if (type_state.redis_future_type) |obj| ffi.decref(obj);
    if (type_state.pg_future_type) |obj| ffi.decref(obj);
    type_state.* = .{};
}

pub fn traverseTypes(type_state: *const TypeState, visit: c.visitproc, arg: ?*anyopaque) c_int {
    if (type_state.future_iter_type) |owned| {
        const rc = visit.?(@ptrCast(@constCast(owned)), arg);
        if (rc != 0) return rc;
    }
    if (type_state.future_type) |owned| {
        const rc = visit.?(@ptrCast(@constCast(owned)), arg);
        if (rc != 0) return rc;
    }
    if (type_state.task_type) |owned| {
        const rc = visit.?(@ptrCast(@constCast(owned)), arg);
        if (rc != 0) return rc;
    }
    if (type_state.redis_future_type) |owned| {
        const rc = visit.?(@ptrCast(@constCast(owned)), arg);
        if (rc != 0) return rc;
    }
    if (type_state.pg_future_type) |owned| return visit.?(@ptrCast(@constCast(owned)), arg);
    return 0;
}

fn makeSingleBaseTuple(base: *PyObject) ffi.PythonError!*PyObject {
    const bases = try ffi.tupleNew(1);
    errdefer ffi.decref(bases);
    try ffi.tupleSetItem(bases, 0, ffi.increfBorrowed(base));
    return bases;
}
