const ffi = @import("../ffi.zig");
const objects_mod = @import("objects.zig");
const types_mod = @import("types.zig");
const runtime_mod = @import("runtime.zig");
const slots_mod = @import("slots.zig");
const redis_mod = @import("redis.zig");
const pg_mod = @import("pg.zig");

pub const c = ffi.c;
pub const PyObject = ffi.PyObject;

pub const TypeState = types_mod.TypeState;

pub const PgMode = objects_mod.PgMode;
pub const RedisYield = objects_mod.RedisYield;
pub const PgYield = objects_mod.PgYield;
pub const SubmittedYield = objects_mod.SubmittedYield;

pub fn initTypes(mod: *PyObject, type_state: *TypeState) ffi.PythonError!void {
    return types_mod.initTypes(
        mod,
        type_state,
        &slots_mod.future_type_spec,
        &slots_mod.task_type_spec,
        &slots_mod.future_iter_type_spec,
        &slots_mod.redis_future_type_spec,
        &slots_mod.pg_future_type_spec,
        @offsetOf(objects_mod.FutureObject, "weakreflist"),
    );
}

pub fn clearTypes(type_state: *TypeState) void {
    types_mod.clearTypes(type_state);
}

pub fn traverseTypes(type_state: *const TypeState, visit: c.visitproc, arg: ?*anyopaque) c_int {
    return types_mod.traverseTypes(type_state, visit, arg);
}

pub const createRedisFuture = redis_mod.createRedisFuture;
pub const createPgFuture = pg_mod.createPgFuture;

pub const isManagedFuture = runtime_mod.isManagedFuture;
pub const consumeYield = runtime_mod.consumeYield;
pub const setResult = runtime_mod.setResult;
pub const setException = runtime_mod.setException;
