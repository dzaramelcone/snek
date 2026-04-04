const ffi = @import("../ffi.zig");
const types_mod = @import("types.zig");
const stmt_cache_mod = @import("../../db/stmt_cache.zig");

pub const c = ffi.c;
pub const PyObject = ffi.PyObject;
pub const TypeState = types_mod.TypeState;

pub const StmtCache = stmt_cache_mod.StmtCache;
pub const MAX_PG_STMTS = stmt_cache_mod.MAX_STMTS;

pub const PgMode = enum(u8) {
    execute,
    fetch_one,
    fetch_all,
};

pub const RedisYield = struct {
    py_coro: *PyObject,
    py_future: *PyObject,
    bytes_written: usize,
};

pub const PgYield = struct {
    py_coro: *PyObject,
    py_future: *PyObject,
    bytes_written: usize,
    mode: PgMode,
    stmt_idx: u16,
    model_cls: ?*PyObject,
};

pub const SubmittedYield = union(enum) {
    redis: RedisYield,
    pg: PgYield,
};

pub const FutureState = enum(u8) {
    pending,
    cancelled,
    finished,
};

pub const SubmitFn = *const fn (
    self: *FutureObject,
    py_coro: *PyObject,
    py_future: *PyObject,
    redis_buf: ?[]u8,
    pg_buf: ?[]u8,
    pg_stmt_cache: ?*StmtCache,
    pg_conn_prepared: ?*[MAX_PG_STMTS]bool,
) anyerror!SubmittedYield;

pub const TraverseExtraFn = *const fn (self: *FutureObject, visit: c.visitproc, arg: ?*anyopaque) c_int;
pub const ClearExtraFn = *const fn (self: *FutureObject) void;

pub const FutureObject = struct {
    ob_base: c.PyObject,
    type_state: ?*TypeState = null,
    weakreflist: ?*PyObject = null,
    result: ?*PyObject = null,
    exception: ?*PyObject = null,
    exception_tb: ?*PyObject = null,
    cancel_message: ?*PyObject = null,
    state: FutureState = .pending,
    submitted: bool = false,
    submit_fn: ?SubmitFn = null,
    traverse_extra_fn: ?TraverseExtraFn = null,
    clear_extra_fn: ?ClearExtraFn = null,
};

pub const TaskObject = struct {
    future: FutureObject,
    coro: ?*PyObject = null,
    context: ?*PyObject = null,
    name: ?*PyObject = null,
    num_cancels_requested: u32 = 0,
};

pub const FutureIterObject = struct {
    ob_base: c.PyObject,
    future: ?*PyObject = null,
    yielded: bool = false,
};
