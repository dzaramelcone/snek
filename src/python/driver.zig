//! Python handler driver: invoke handlers, drive coroutines, consume native async yields.
//!
//! This file does not convert Python returns into HTTP responses. The uring
//! send path carries raw `PyObject*` values until send preparation time.

const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;
const PyObject = ffi.PyObject;
const future_mod = @import("futures/mod.zig");
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
    redis_yield: future_mod.RedisYield,
    pg_yield: future_mod.PgYield,
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
    ns_yield_consume: u64 = 0,
};

fn nowInstant() ?std.time.Instant {
    return std.time.Instant.now() catch |e| switch (e) {
        error.Unsupported => unreachable,
    };
}

fn accumElapsed(total: *u64, start: ?std.time.Instant) void {
    const t0 = start orelse return;
    const t1 = std.time.Instant.now() catch |e| switch (e) {
        error.Unsupported => unreachable,
    };
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

    const t_lookup = if (metrics != null) nowInstant() else null;
    const handler = module.getHandler(mod, handler_id) orelse {
        return .{ .native_response = response_mod.Response.init(.internal_server_error) };
    };
    if (metrics) |m| accumElapsed(&m.ns_lookup, t_lookup);

    const t_call = if (metrics != null) nowInstant() else null;
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

        const t_args = if (metrics != null) nowInstant() else null;
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

        const t_resume = if (metrics != null) nowInstant() else null;
        const send = ffi.iterSend(call_result, ffi.none());
        if (metrics) |m| accumElapsed(&m.ns_resume, t_resume);

        switch (send.status) {
            .next => {
                const yielded = send.result.?;
                defer ffi.decref(yielded);

                const t_yield_consume = if (metrics != null) nowInstant() else null;
                const state = module.getState(mod) orelse {
                    ffi.coroutineClose(call_result);
                    ffi.decref(call_result);
                    return .{ .native_response = response_mod.Response.init(.internal_server_error) };
                };
                const yield = future_mod.consumeYield(
                    &state.future_types,
                    yielded,
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
                    accumElapsed(&m.ns_yield_consume, t_yield_consume);
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

pub fn startServer(mod: *PyObject, host: []const u8, port: u16, threads: usize, backlog: u16) !void {
    drv_log.info("startServer called host={s} port={d} threads={d} backlog={d}", .{ host, port, threads, backlog });
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
        const method = std.meta.stringToEnum(std.http.Method, entry.method[0..entry.method_len]) orelse continue;
        const route_id = server.handler_count;
        server.addPythonRoute(method, entry.path[0..entry.path_len], i) catch continue;
        server.py_handler_flags[route_id] = .{
            .needs_request = state.handler_flags[i].needs_request,
            .needs_params = state.handler_flags[i].needs_params,
            .no_args = state.handler_flags[i].no_args,
            .is_async = state.handler_flags[i].is_async,
        };
    }

    _ = ffi.PyEval_SaveThread();
    try server_mod.run(std.heap.smp_allocator, &server);
}
