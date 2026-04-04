const std = @import("std");
const ffi = @import("../ffi.zig");
const objects_mod = @import("objects.zig");
const runtime_mod = @import("runtime.zig");

const PyObject = ffi.PyObject;
const TypeState = objects_mod.TypeState;
const FutureObject = objects_mod.FutureObject;
const SubmittedYield = objects_mod.SubmittedYield;

const PgMode = objects_mod.PgMode;
const MAX_PG_ARGS = 3;

pub const PgFutureObject = struct {
    future: FutureObject,
    mode: PgMode = .execute,
    arg_count: u8 = 0,
    args: [MAX_PG_ARGS]?*PyObject = [_]?*PyObject{null} ** MAX_PG_ARGS,
};

pub fn clearPgExtra(base: *FutureObject) void {
    const self: *PgFutureObject = @fieldParentPtr("future", base);
    var i: usize = 0;
    while (i < self.arg_count) : (i += 1) {
        runtime_mod.clearOptional(&self.args[i]);
    }
    self.arg_count = 0;
}

pub fn traversePgExtra(base: *FutureObject, visit: objects_mod.c.visitproc, arg: ?*anyopaque) c_int {
    const self: *PgFutureObject = @fieldParentPtr("future", base);
    var i: usize = 0;
    while (i < self.arg_count) : (i += 1) {
        if (self.args[i]) |owned| {
            const rc = visit.?(@ptrCast(@constCast(owned)), arg);
            if (rc != 0) return rc;
        }
    }
    return 0;
}

const PgEncoded = struct {
    bytes_written: usize,
    stmt_idx: u16,
};

fn encodePg(
    buf: []u8,
    cache: *objects_mod.StmtCache,
    prepared: *[objects_mod.MAX_PG_STMTS]bool,
    sql_obj: *PyObject,
    params_obj: *PyObject,
) !PgEncoded {
    const sql_text = try ffi.unicodeAsUTF8(sql_obj);
    const sql = std.mem.span(sql_text);
    const size = ffi.tupleSize(params_obj);
    const num_params: usize = @intCast(size);

    var param_bufs: [objects_mod.StmtCache.MAX_PARAMS]?[]const u8 = .{null} ** objects_mod.StmtCache.MAX_PARAMS;
    var temp_bufs: [objects_mod.StmtCache.MAX_PARAMS][64]u8 = undefined;

    for (0..num_params) |idx| {
        const param = ffi.tupleGetItem(params_obj, @intCast(idx)) orelse continue;
        if (ffi.isNone(param)) {
            param_bufs[idx] = null;
            continue;
        }
        if (ffi.isString(param)) {
            const text = try ffi.unicodeAsUTF8(param);
            param_bufs[idx] = std.mem.span(text);
            continue;
        }
        const str_obj = try ffi.objectStr(param);
        defer ffi.decref(str_obj);
        const text = try ffi.unicodeAsUTF8(str_obj);
        const span = std.mem.span(text);
        if (span.len > temp_bufs[idx].len) return error.ParamTooLong;
        @memcpy(temp_bufs[idx][0..span.len], span);
        param_bufs[idx] = temp_bufs[idx][0..span.len];
    }

    const encoded = try cache.encodeExtendedWithParams(buf, sql, prepared, param_bufs[0..num_params]);
    return .{
        .bytes_written = encoded.bytes_written,
        .stmt_idx = encoded.stmt_idx,
    };
}

fn submitPg(
    base: *FutureObject,
    py_coro: *PyObject,
    py_future: *PyObject,
    _: ?[]u8,
    pg_buf: ?[]u8,
    pg_stmt_cache: ?*objects_mod.StmtCache,
    pg_conn_prepared: ?*[objects_mod.MAX_PG_STMTS]bool,
) !SubmittedYield {
    const buf = pg_buf orelse return error.NoPgSendBuffer;
    const cache = pg_stmt_cache orelse return error.NoPgStmtCache;
    const prepared = pg_conn_prepared orelse return error.NoPgConnPrepared;
    const self: *PgFutureObject = @fieldParentPtr("future", base);
    const sql = self.args[0] orelse return error.InvalidState;
    const params = self.args[1] orelse return error.InvalidState;
    const encoded = try encodePg(buf, cache, prepared, sql, params);
    const model_cls = switch (self.mode) {
        .execute => null,
        else => if (self.arg_count > 2) self.args[2] else null,
    };
    return .{ .pg = .{
        .py_coro = py_coro,
        .py_future = ffi.increfBorrowed(py_future),
        .bytes_written = encoded.bytes_written,
        .mode = self.mode,
        .stmt_idx = encoded.stmt_idx,
        .model_cls = if (model_cls) |cls| ffi.increfBorrowed(cls) else null,
    } };
}

pub fn createPgFuture(comptime mode: PgMode, type_state: *TypeState, args: []const *PyObject) ffi.PythonError!*PyObject {
    const type_obj = type_state.pg_future_type orelse return error.PythonError;
    if (args.len > MAX_PG_ARGS) return error.TypeError;
    const self = try runtime_mod.allocFutureLike(PgFutureObject, type_obj, type_state);
    self.future.type_state = type_state;
    self.future.traverse_extra_fn = traversePgExtra;
    self.future.clear_extra_fn = clearPgExtra;
    self.future.submit_fn = &submitPg;
    self.mode = mode;
    self.arg_count = @intCast(args.len);
    for (args, 0..) |arg, i| {
        self.args[i] = ffi.increfBorrowed(arg);
    }
    return @ptrCast(&self.future);
}
