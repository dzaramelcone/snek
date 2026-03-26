//! RedisCtx — lightweight context for a task parked on the redis reader.
//!
//! Holds the Python coroutine and a pointer back to ConnCtx.
//! Task.ctx swaps to RedisCtx while parked, swaps back on resume.

const ffi = @import("../python/ffi.zig");
const conn_mod = @import("../connection.zig");
const Pool = @import("../pool.zig").Pool;

pub const RedisCtx = struct {
    py_coro: *ffi.PyObject,
    conn: *conn_mod.ConnCtx,
    pool_index: usize,
    pool: *Pool(RedisCtx),

    pub fn release(self: *RedisCtx) void {
        self.pool.release(self.pool_index);
    }
};
