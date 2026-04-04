//! Python handler driver: invoke handlers, drive coroutines, consume native async yields.
//!
//! This file does not convert Python returns into HTTP responses. The uring
//! send path carries raw `PyObject*` values until send preparation time.

const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;
const PyObject = ffi.PyObject;
const gil = @import("gil.zig");
const future_mod = @import("future.zig");
const module = @import("module.zig");
const response_mod = @import("../http/response.zig");
const router_mod = @import("../http/router.zig");
const stmt_cache_mod = @import("../db/stmt_cache.zig");
const StmtCache = stmt_cache_mod.StmtCache;
const MAX_PG_STMTS = stmt_cache_mod.MAX_STMTS;

pub fn buildParamsKwargs(params: []const router_mod.PathParam) ffi.PythonError!*PyObject {
    const kwargs = try ffi.dictNew();
    for (params) |p| {
        const name_obj = try ffi.unicodeFromSlice(p.name.ptr, p.name.len);
        defer ffi.decref(name_obj);
        const val_obj = try ffi.unicodeFromSlice(p.value.ptr, p.value.len);
        defer ffi.decref(val_obj);
        try ffi.dictSetItem(kwargs, name_obj, val_obj);
    }
    return kwargs;
}

pub const InvokeResult = union(enum) {
    native_response: response_mod.Response,
    py_result: *PyObject,
    redis_yield: RedisYield,
    pg_yield: PgYield,

    pub const RedisYield = struct {
        py_coro: *PyObject,
        bytes_written: usize,
    };

    pub const PgYield = struct {
        py_coro: *PyObject,
        bytes_written: usize,
        cmd: PgCmd,
        stmt_idx: u16,
        model_cls: ?*PyObject,
    };
};

pub const InvokeMetrics = struct {
    invocations: u64 = 0,
    coroutines: u64 = 0,
    sync_responses: u64 = 0,
    async_immediate_returns: u64 = 0,
    redis_yields: u64 = 0,
    pg_yields: u64 = 0,
    ns_lookup: u64 = 0,
    ns_arg_build: u64 = 0,
    ns_call: u64 = 0,
    ns_resume: u64 = 0,
    ns_sentinel: u64 = 0,
};

fn nowInstant() ?std.time.Instant {
    return std.time.Instant.now() catch null;
}

fn accumElapsed(total: *u64, start: ?std.time.Instant) void {
    const t0 = start orelse return;
    const t1 = std.time.Instant.now() catch return;
    total.* += t1.since(t0);
}

pub fn invokePythonHandlerWithKnownFlags(
    mod: *PyObject,
    handler_id: u32,
    no_args: bool,
    needs_params: bool,
    is_async: bool,
    req_obj: ?*PyObject,
    params: []const router_mod.PathParam,
    redis_send_buf: ?[]u8,
    pg_send_buf: ?[]u8,
    pg_stmt_cache: ?*StmtCache,
    pg_conn_prepared: ?*[MAX_PG_STMTS]bool,
    metrics: ?*InvokeMetrics,
) !InvokeResult {
    if (metrics) |m| m.invocations += 1;

    const t_lookup = nowInstant();
    const handler = module.getHandler(mod, handler_id) orelse {
        return .{ .native_response = response_mod.Response.init(.internal_server_error) };
    };
    if (metrics) |m| accumElapsed(&m.ns_lookup, t_lookup);

    const t_call = nowInstant();
    const call_result = if (no_args) blk: {
        break :blk ffi.vectorcallNoArgs(handler) catch {
            if (ffi.errOccurred()) ffi.errPrint();
            return .{ .native_response = response_mod.Response.init(.internal_server_error) };
        };
    } else if (needs_params) blk: {
        if (params.len == 0) {
            break :blk ffi.vectorcallNoArgs(handler) catch {
                if (ffi.errOccurred()) ffi.errPrint();
                return .{ .native_response = response_mod.Response.init(.internal_server_error) };
            };
        }

        const t_args = nowInstant();
        const kwargs = buildParamsKwargs(params) catch {
            return .{ .native_response = response_mod.Response.init(.internal_server_error) };
        };
        defer ffi.decref(kwargs);
        const empty_args = ffi.tupleNew(0) catch {
            return .{ .native_response = response_mod.Response.init(.internal_server_error) };
        };
        defer ffi.decref(empty_args);
        if (metrics) |m| accumElapsed(&m.ns_arg_build, t_args);

        break :blk ffi.callObjectKwargs(handler, empty_args, kwargs) catch {
            if (ffi.errOccurred()) ffi.errPrint();
            return .{ .native_response = response_mod.Response.init(.internal_server_error) };
        };
    } else blk: {
        const request = req_obj orelse {
            return .{ .native_response = response_mod.Response.init(.internal_server_error) };
        };
        break :blk ffi.vectorcallOneArg(handler, request) catch {
            if (ffi.errOccurred()) ffi.errPrint();
            return .{ .native_response = response_mod.Response.init(.internal_server_error) };
        };
    };
    if (metrics) |m| accumElapsed(&m.ns_call, t_call);

    if (is_async) {
        if (metrics) |m| m.coroutines += 1;

        const t_resume = nowInstant();
        const send = ffi.iterSend(call_result, ffi.none());
        if (metrics) |m| accumElapsed(&m.ns_resume, t_resume);

        switch (send.status) {
            .next => {
                const sentinel = send.result.?;
                defer ffi.decref(sentinel);

                const t_sentinel = nowInstant();
                const yield = consumeAsyncYield(
                    mod,
                    sentinel,
                    call_result,
                    redis_send_buf,
                    pg_send_buf,
                    pg_stmt_cache,
                    pg_conn_prepared,
                ) catch {
                    ffi.coroutineClose(call_result);
                    ffi.decref(call_result);
                    return .{ .native_response = response_mod.Response.init(.service_unavailable) };
                };
                if (metrics) |m| {
                    accumElapsed(&m.ns_sentinel, t_sentinel);
                    switch (yield) {
                        .redis => m.redis_yields += 1,
                        .pg => m.pg_yields += 1,
                    }
                }
                return switch (yield) {
                    .redis => |redis_yield| .{ .redis_yield = redis_yield },
                    .pg => |pg_yield| .{ .pg_yield = pg_yield },
                };
            },
            .@"return" => {
                ffi.decref(call_result);
                if (metrics) |m| m.async_immediate_returns += 1;
                const py_result = send.result orelse {
                    return .{ .native_response = response_mod.Response.init(.internal_server_error) };
                };
                return .{ .py_result = py_result };
            },
            .@"error" => {
                ffi.decref(call_result);
                if (ffi.errOccurred()) ffi.errPrint();
                return .{ .native_response = response_mod.Response.init(.internal_server_error) };
            },
        }
    }

    if (metrics) |m| m.sync_responses += 1;
    return .{ .py_result = call_result };
}

pub const PgCmd = enum(u8) {
    EXECUTE = 100,
    FETCH_ONE = 101,
    FETCH_ALL = 102,
    FETCH_ONE_MODEL = 103,
    FETCH_ALL_MODEL = 104,

    pub fn normalize(self: PgCmd) PgCmd {
        return switch (self) {
            .FETCH_ONE_MODEL => .FETCH_ONE,
            .FETCH_ALL_MODEL => .FETCH_ALL,
            else => self,
        };
    }
};

pub const SentinelYield = union(enum) {
    redis: InvokeResult.RedisYield,
    pg: InvokeResult.PgYield,
};

fn writeRedisOp(buf: []u8, cmd: []const u8, args_tuple: *PyObject) !usize {
    if (!ffi.isTuple(args_tuple)) return error.TypeError;
    const size = ffi.tupleSize(args_tuple);
    if (size < 0) return error.PythonError;
    if (size + 1 > 8) return error.TypeError;

    var args: [8][]const u8 = undefined;
    args[0] = cmd;
    var arg_count: usize = 1;
    var i: isize = 0;
    while (i < size) : (i += 1) {
        const arg_obj = ffi.tupleGetItem(args_tuple, i) orelse return error.PythonError;
        if (!ffi.isString(arg_obj)) return error.TypeError;
        const s = try ffi.unicodeAsUTF8(arg_obj);
        args[arg_count] = std.mem.span(s);
        arg_count += 1;
    }

    const n = writeResp(buf, args[0..arg_count]);
    if (n == 0) return error.RespBufferOverflow;
    return n;
}

fn encodePgYield(
    py_coro: *PyObject,
    buf: []u8,
    cache: *StmtCache,
    prepared: *[MAX_PG_STMTS]bool,
    cmd: PgCmd,
    data: future_mod.PgOp,
) !SentinelYield {
    const sql_str = try ffi.unicodeAsUTF8(data.sql);
    const sql = std.mem.span(sql_str);
    const size = ffi.tupleSize(data.params);
    const num_params: usize = @intCast(size);

    var param_bufs: [StmtCache.MAX_PARAMS]?[]const u8 = .{null} ** StmtCache.MAX_PARAMS;
    var str_bufs: [StmtCache.MAX_PARAMS][64]u8 = undefined;

    for (0..num_params) |pi| {
        const param_obj = ffi.tupleGetItem(data.params, @intCast(pi)) orelse continue;
        if (ffi.isNone(param_obj)) {
            param_bufs[pi] = null;
            continue;
        }
        if (ffi.isString(param_obj)) {
            const s = try ffi.unicodeAsUTF8(param_obj);
            param_bufs[pi] = std.mem.span(s);
            continue;
        }

        const str_obj = try ffi.objectStr(param_obj);
        defer ffi.decref(str_obj);
        const s = try ffi.unicodeAsUTF8(str_obj);
        const span = std.mem.span(s);
        if (span.len > str_bufs[pi].len) return error.ParamTooLong;
        @memcpy(str_bufs[pi][0..span.len], span);
        param_bufs[pi] = str_bufs[pi][0..span.len];
    }

    const result = try cache.encodeExtendedWithParams(buf, sql, prepared, param_bufs[0..num_params]);
    return .{ .pg = .{
        .py_coro = py_coro,
        .bytes_written = result.bytes_written,
        .cmd = cmd,
        .stmt_idx = result.stmt_idx,
        .model_cls = if (data.model_cls) |cls| ffi.increfBorrowed(cls) else null,
    } };
}

pub fn consumeAsyncYield(
    mod: *PyObject,
    yielded: *PyObject,
    py_coro: *PyObject,
    redis_buf: ?[]u8,
    pg_buf: ?[]u8,
    pg_stmt_cache: ?*StmtCache,
    pg_conn_prepared: ?*[MAX_PG_STMTS]bool,
) !SentinelYield {
    const state = module.getState(mod) orelse return error.UnknownSentinelType;
    var op = future_mod.takePending(&state.async_state, yielded) orelse return error.UnknownSentinelType;
    defer op.deinit();

    return switch (op) {
        .redis => |redis| blk: {
            const buf = redis_buf orelse return error.NoRedisBuffer;
            const cmd = switch (redis.kind) {
                .get => "GET",
                .set => "SET",
                .del => "DEL",
                .incr => "INCR",
                .expire => "EXPIRE",
                .ttl => "TTL",
                .exists => "EXISTS",
                .ping => "PING",
                .setex => "SETEX",
            };
            const n = try writeRedisOp(buf, cmd, redis.args);
            break :blk .{ .redis = .{ .py_coro = py_coro, .bytes_written = n } };
        },
        .pg => |pg| blk: {
            const buf = pg_buf orelse return error.NoPgSendBuffer;
            const cache = pg_stmt_cache orelse return error.NoPgStmtCache;
            const prepared = pg_conn_prepared orelse return error.NoPgConnPrepared;
            const cmd = switch (pg.kind) {
                .execute => PgCmd.EXECUTE,
                .fetch_one, .fetch_one_model => PgCmd.FETCH_ONE,
                .fetch_all, .fetch_all_model => PgCmd.FETCH_ALL,
            };
            break :blk try encodePgYield(py_coro, buf, cache, prepared, cmd, pg);
        },
    };
}

pub fn writeResp(buf: []u8, args: []const []const u8) usize {
    var pos: usize = 0;
    if (pos >= buf.len) return 0;
    buf[pos] = '*';
    pos += 1;

    const n_str = std.fmt.bufPrint(buf[pos..], "{d}\r\n", .{args.len}) catch return 0;
    pos += n_str.len;

    for (args) |arg| {
        if (pos >= buf.len) return 0;
        buf[pos] = '$';
        pos += 1;

        const l_str = std.fmt.bufPrint(buf[pos..], "{d}\r\n", .{arg.len}) catch return 0;
        pos += l_str.len;

        if (pos + arg.len + 2 > buf.len) return 0;
        @memcpy(buf[pos..][0..arg.len], arg);
        pos += arg.len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
    }

    return pos;
}

const server_mod = @import("../server.zig");
const posix = std.posix;

fn shutdownSignalHandler(_: c_int) callconv(.c) void {
    std.posix.exit(0);
}

fn installShutdownSignals() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = shutdownSignalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.INT, &act, null);
}

const drv_log = std.log.scoped(.@"snek/driver");

pub fn startServer(host: []const u8, port: u16, threads: usize, backlog: u16) !void {
    drv_log.info("startServer called host={s} port={d} threads={d} backlog={d}", .{ host, port, threads, backlog });
    const mod = module.getCurrentModule() orelse return error.ModuleNotSet;
    const state = module.getState(mod) orelse return error.ModuleNotSet;

    installShutdownSignals();

    var server = server_mod.Server.init(std.heap.smp_allocator, host, port);
    defer server.deinit();
    server.num_threads = threads;
    server.backlog = @intCast(backlog);

    if (module.getModuleRef(mod)) |ref| server.setModuleRef(ref);

    var i: u32 = 0;
    while (i < state.py_handler_count) : (i += 1) {
        const entry = state.route_entries[i];
        const method = router_mod.Method.fromString(entry.method[0..entry.method_len]) orelse continue;
        const route_id = server.handler_count;
        server.addPythonRoute(method, entry.path[0..entry.path_len], i) catch continue;
        server.py_handler_flags[route_id] = .{
            .needs_request = state.handler_flags[i].needs_request,
            .needs_params = state.handler_flags[i].needs_params,
            .no_args = state.handler_flags[i].no_args,
            .is_async = state.handler_flags[i].is_async,
        };
    }

    _ = gil.PyEval_SaveThread();
    try server_mod.run(std.heap.smp_allocator, &server);
}
