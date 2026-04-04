//! _snek C extension module: multi-phase init (PEP 489).
//!
//! Exposes module-level functions to Python:
//!   _snek.add_route(method, path, handler) — registers a route + Python callable
//!   _snek.run(host, port)                  — starts the Zig HTTP server
//!
//! All per-interpreter state (handlers, routes, flags) lives in SnekModuleState,
//! stored via PyModule_GetState. This supports sub-interpreters with per-interpreter GIL.

const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;
const PyObject = ffi.PyObject;
const driver = @import("driver.zig");
const future_mod = @import("futures/mod.zig");

// ── Module state ────────────────────────────────────────────────────

/// Maximum number of Python handlers that can be registered.
const MAX_HANDLERS: usize = 64;

/// Handler calling convention flags, determined at registration time
/// by inspecting the Python handler's signature.
/// extern struct for C ABI compatibility (embedded in SnekModuleState).
pub const HandlerFlags = extern struct {
    /// Handler takes a single `request` dict argument (default)
    needs_request: bool = true,
    /// Handler takes named path params as **kwargs
    needs_params: bool = false,
    /// Handler takes no arguments at all
    no_args: bool = false,
    /// Handler is async def (pre-computed, saves per-call check)
    is_async: bool = false,
};

/// Route metadata stored alongside handlers for server setup.
/// extern struct for C ABI compatibility (embedded in SnekModuleState).
pub const RouteEntry = extern struct {
    method: [8]u8,
    method_len: u8,
    path: [256]u8,
    path_len: u16,
};

/// Per-interpreter module state. Stored via PyModule_GetState.
/// All handler/route storage is per-interpreter, not global.
pub const SnekModuleState = extern struct {
    py_handlers: [MAX_HANDLERS]?*PyObject,
    py_handler_count: u32,
    handler_flags: [MAX_HANDLERS]HandlerFlags,
    route_entries: [MAX_HANDLERS]RouteEntry,
    future_types: future_mod.TypeState,
    /// "module:attr" ref for sub-interpreters to re-import the user app.
    /// Stored as a null-terminated fixed buffer (e.g. "app:app\x00...").
    module_ref: [256]u8,
    module_ref_len: u16,
};

/// Get module state from a module object.
pub fn getState(mod: *PyObject) ?*SnekModuleState {
    const raw = ffi.moduleGetState(mod) orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Get stored Python callable by handler_id.
pub fn getHandler(mod: *PyObject, handler_id: u32) ?*PyObject {
    const state = getState(mod) orelse return null;
    if (handler_id >= MAX_HANDLERS) return null;
    return state.py_handlers[handler_id];
}

/// Get handler flags by handler_id.
pub fn getHandlerFlags(mod: *PyObject, handler_id: u32) HandlerFlags {
    const state = getState(mod) orelse return HandlerFlags{};
    if (handler_id >= state.py_handler_count) return HandlerFlags{};
    return state.handler_flags[handler_id];
}

/// Get the stored "module:attr" reference string for sub-interpreter re-import.
pub fn getModuleRef(mod: *PyObject) ?[]const u8 {
    const state = getState(mod) orelse return null;
    if (state.module_ref_len == 0) return null;
    return state.module_ref[0..state.module_ref_len];
}

// ── Handler introspection ───────────────────────────────────────────

/// Inspect a Python handler's signature at registration time to determine
/// what arguments it needs. Uses __code__.co_argcount and co_varnames.
///
/// Rules:
///   - 0 args → no_args (don't build any request dict)
///   - 1 arg named "request" or "req" → needs_request (full dict)
///   - named params (not "request"/"req"/"self") → needs_params (kwargs injection)
///   - fallback → needs_request
fn inspectHandlerFlags(handler_obj: *PyObject) HandlerFlags {
    var flags = HandlerFlags{};

    // Detect async: check if the handler is a coroutine function
    flags.is_async = c.PyCoro_CheckExact(handler_obj) != 0 or isCoroutineFunction(handler_obj);

    // Get __code__ attribute — functions and lambdas have this
    const code = c.PyObject_GetAttrString(handler_obj, "__code__") orelse {
        // No __code__ (e.g. a class with __call__) — fall back to needs_request
        ffi.errClear();
        return flags;
    };
    defer ffi.decref(code);

    // Get co_argcount (excludes *args and **kwargs)
    const argcount_obj = c.PyObject_GetAttrString(code, "co_argcount") orelse {
        ffi.errClear();
        return flags;
    };
    defer ffi.decref(argcount_obj);
    const argcount = ffi.longAsLong(argcount_obj) catch return flags;

    if (argcount == 0) {
        // Zero positional args — handler() takes nothing
        flags.no_args = true;
        flags.needs_request = false;
        return flags;
    }

    // Get co_varnames to check the first parameter name
    const varnames_obj = c.PyObject_GetAttrString(code, "co_varnames") orelse {
        ffi.errClear();
        return flags;
    };
    defer ffi.decref(varnames_obj);

    // co_varnames is a tuple — get the first element
    const first_param = ffi.tupleGetItem(varnames_obj, 0) orelse return flags;
    if (!ffi.isString(first_param)) return flags;
    const param_name = ffi.unicodeAsUTF8(first_param) catch return flags;
    const name_span = std.mem.span(param_name);

    // If the first param is "request" or "req", it wants the full dict
    if (std.mem.eql(u8, name_span, "request") or std.mem.eql(u8, name_span, "req")) {
        flags.needs_request = true;
        return flags;
    }

    // If the first param is "self", this is a method — check second param
    if (std.mem.eql(u8, name_span, "self")) {
        if (argcount >= 2) {
            const second_param = ffi.tupleGetItem(varnames_obj, 1) orelse return flags;
            if (!ffi.isString(second_param)) return flags;
            const second_name = ffi.unicodeAsUTF8(second_param) catch return flags;
            const second_span = std.mem.span(second_name);
            if (std.mem.eql(u8, second_span, "request") or std.mem.eql(u8, second_span, "req")) {
                return flags;
            }
        }
        // Method with no recognizable params — needs_request as fallback
        return flags;
    }

    // Named params like `name`, `id` etc. — inject as kwargs
    flags.needs_params = true;
    flags.needs_request = false;
    return flags;
}

/// Check if a callable is an async def (coroutine function).
fn isCoroutineFunction(obj: *PyObject) bool {
    const inspect_mod = ffi.importModuleRaw("inspect") catch return false;
    defer ffi.decref(inspect_mod);

    const is_coro_fn = ffi.getAttrRaw(inspect_mod, "iscoroutinefunction") catch return false;
    defer ffi.decref(is_coro_fn);

    const result = ffi.callOneArg(is_coro_fn, obj) catch {
        ffi.errClear();
        return false;
    };
    defer ffi.decref(result);

    return ffi.objectIsTrue(result) catch false;
}

// ── Module methods ──────────────────────────────────────────────────

fn pyAddRoute(self: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    const mod = self.?;
    const state = ffi.moduleStateRequired(SnekModuleState, mod) catch {
        c.PyErr_SetString(c.PyExc_RuntimeError, "module state not initialized");
        return null;
    };
    const tuple = args.?;
    if (ffi.tupleSize(tuple) != 3) {
        c.PyErr_SetString(c.PyExc_TypeError, "add_route(method, path, handler) requires exactly 3 arguments");
        return null;
    }

    const method_obj = ffi.tupleGetItem(tuple, 0).?;
    const path_obj = ffi.tupleGetItem(tuple, 1).?;
    const handler_obj = ffi.tupleGetItem(tuple, 2).?;
    if (!ffi.isString(method_obj)) {
        c.PyErr_SetString(c.PyExc_TypeError, "add_route(method, path, handler): method must be a string");
        return null;
    }
    if (!ffi.isString(path_obj)) {
        c.PyErr_SetString(c.PyExc_TypeError, "add_route(method, path, handler): path must be a string");
        return null;
    }
    if (!ffi.isCallable(handler_obj)) {
        c.PyErr_SetString(c.PyExc_TypeError, "add_route(method, path, handler): handler must be callable");
        return null;
    }
    if (state.py_handler_count >= MAX_HANDLERS) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "too many handlers registered (max 64)");
        return null;
    }

    const method_span = std.mem.span(ffi.unicodeAsUTF8(method_obj) catch return null);
    const path_span = std.mem.span(ffi.unicodeAsUTF8(path_obj) catch return null);
    if (method_span.len > 8) {
        c.PyErr_SetString(c.PyExc_ValueError, "method string too long (max 8 chars)");
        return null;
    }
    if (path_span.len > 256) {
        c.PyErr_SetString(c.PyExc_ValueError, "path string too long (max 256 chars)");
        return null;
    }

    const id = state.py_handler_count;
    var entry = RouteEntry{
        .method = std.mem.zeroes([8]u8),
        .method_len = @intCast(method_span.len),
        .path = std.mem.zeroes([256]u8),
        .path_len = @intCast(path_span.len),
    };
    @memcpy(entry.method[0..method_span.len], method_span);
    @memcpy(entry.path[0..path_span.len], path_span);
    state.route_entries[id] = entry;

    ffi.incref(handler_obj);
    state.py_handlers[id] = handler_obj;
    state.handler_flags[id] = inspectHandlerFlags(handler_obj);
    state.py_handler_count = id + 1;
    return ffi.getNone();
}

fn pyRun(self: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    const mod = self.?;
    const state = ffi.moduleStateRequired(SnekModuleState, mod) catch {
        c.PyErr_SetString(c.PyExc_RuntimeError, "module state not initialized");
        return null;
    };
    const tuple = args.?;
    const argc = ffi.tupleSize(tuple);
    if (argc < 3 or argc > 5) {
        c.PyErr_SetString(c.PyExc_TypeError, "run(host, port, threads, module_ref?, backlog?) requires 3-5 arguments");
        return null;
    }

    const host_obj = ffi.tupleGetItem(tuple, 0).?;
    const port_obj = ffi.tupleGetItem(tuple, 1).?;
    const threads_obj = ffi.tupleGetItem(tuple, 2).?;
    if (!ffi.isString(host_obj)) {
        c.PyErr_SetString(c.PyExc_TypeError, "run(host, port, threads, module_ref?, backlog?): host must be a string");
        return null;
    }
    if (c.PyLong_Check(port_obj) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "run(host, port, threads, module_ref?, backlog?): port must be an integer");
        return null;
    }
    if (c.PyLong_Check(threads_obj) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "run(host, port, threads, module_ref?, backlog?): threads must be an integer");
        return null;
    }
    if (argc >= 4 and !ffi.isString(ffi.tupleGetItem(tuple, 3).?)) {
        c.PyErr_SetString(c.PyExc_TypeError, "run(host, port, threads, module_ref?, backlog?): module_ref must be a string");
        return null;
    }
    if (argc >= 5 and c.PyLong_Check(ffi.tupleGetItem(tuple, 4).?) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "run(host, port, threads, module_ref?, backlog?): backlog must be an integer");
        return null;
    }

    const host_span = std.mem.span(ffi.unicodeAsUTF8(host_obj) catch return null);
    const port_long = ffi.longAsLong(port_obj) catch return null;
    const threads_long = ffi.longAsLong(threads_obj) catch return null;
    if (port_long < 0 or port_long > 65535) {
        c.PyErr_SetString(c.PyExc_ValueError, "port must be 0-65535");
        return null;
    }
    if (threads_long < 1 or threads_long > 256) {
        c.PyErr_SetString(c.PyExc_ValueError, "threads must be 1-256");
        return null;
    }

    state.module_ref_len = 0;
    if (argc >= 4) {
        const ref_span = std.mem.span(ffi.unicodeAsUTF8(ffi.tupleGetItem(tuple, 3).?) catch return null);
        if (ref_span.len >= state.module_ref.len) {
            c.PyErr_SetString(c.PyExc_ValueError, "module_ref string too long (max 255 chars)");
            return null;
        }
        if (ref_span.len > 0) {
            @memcpy(state.module_ref[0..ref_span.len], ref_span);
            state.module_ref_len = @intCast(ref_span.len);
        }
    }

    var backlog: u16 = 2048;
    if (argc >= 5) {
        const backlog_long = ffi.longAsLong(ffi.tupleGetItem(tuple, 4).?) catch return null;
        if (backlog_long < 1 or backlog_long > 65535) {
            c.PyErr_SetString(c.PyExc_ValueError, "backlog must be 1-65535");
            return null;
        }
        backlog = @intCast(backlog_long);
    }

    driver.startServer(mod, host_span, @intCast(port_long), @intCast(threads_long), backlog) catch {
        return null;
    };
    return ffi.getNone();
}

fn redisGet(state: *SnekModuleState, key: *PyObject) ffi.PythonError!*PyObject {
    const args = [_]*PyObject{key};
    return future_mod.createRedisFuture("GET", &state.future_types, &args);
}

fn redisSet(state: *SnekModuleState, args: [*]const *PyObject, nargs: c.Py_ssize_t) ffi.PythonError!*PyObject {
    const count: usize = @intCast(nargs);
    return future_mod.createRedisFuture("SET", &state.future_types, args[0..count]);
}

fn redisSetex(state: *SnekModuleState, args: [*]const *PyObject, nargs: c.Py_ssize_t) ffi.PythonError!*PyObject {
    const count: usize = @intCast(nargs);
    return future_mod.createRedisFuture("SETEX", &state.future_types, args[0..count]);
}

fn redisDel(state: *SnekModuleState, args: [*]const *PyObject, nargs: c.Py_ssize_t) ffi.PythonError!*PyObject {
    const count: usize = @intCast(nargs);
    return future_mod.createRedisFuture("DEL", &state.future_types, args[0..count]);
}

fn redisIncr(state: *SnekModuleState, args: [*]const *PyObject, nargs: c.Py_ssize_t) ffi.PythonError!*PyObject {
    const count: usize = @intCast(nargs);
    return future_mod.createRedisFuture("INCR", &state.future_types, args[0..count]);
}

fn redisExpire(state: *SnekModuleState, args: [*]const *PyObject, nargs: c.Py_ssize_t) ffi.PythonError!*PyObject {
    const count: usize = @intCast(nargs);
    return future_mod.createRedisFuture("EXPIRE", &state.future_types, args[0..count]);
}

fn redisTtl(state: *SnekModuleState, key: *PyObject) ffi.PythonError!*PyObject {
    const args = [_]*PyObject{key};
    return future_mod.createRedisFuture("TTL", &state.future_types, &args);
}

fn redisExists(state: *SnekModuleState, args: [*]const *PyObject, nargs: c.Py_ssize_t) ffi.PythonError!*PyObject {
    const count: usize = @intCast(nargs);
    return future_mod.createRedisFuture("EXISTS", &state.future_types, args[0..count]);
}

fn redisPing(state: *SnekModuleState) ffi.PythonError!*PyObject {
    const args = [_]*PyObject{};
    return future_mod.createRedisFuture("PING", &state.future_types, &args);
}

fn pgExecute(state: *SnekModuleState, args: [*]const *PyObject, nargs: c.Py_ssize_t) ffi.PythonError!*PyObject {
    const count: usize = @intCast(nargs);
    return future_mod.createPgFuture(.execute, &state.future_types, args[0..count]);
}

fn pgFetchOne(state: *SnekModuleState, args: [*]const *PyObject, nargs: c.Py_ssize_t) ffi.PythonError!*PyObject {
    const count: usize = @intCast(nargs);
    return future_mod.createPgFuture(.fetch_one, &state.future_types, args[0..count]);
}

fn pgFetchAll(state: *SnekModuleState, args: [*]const *PyObject, nargs: c.Py_ssize_t) ffi.PythonError!*PyObject {
    const count: usize = @intCast(nargs);
    return future_mod.createPgFuture(.fetch_all, &state.future_types, args[0..count]);
}

fn getRouteCount(state: *SnekModuleState) ffi.PythonError!*PyObject {
    return ffi.longFromLong(@intCast(state.py_handler_count));
}

// ── Module definition (multi-phase init, PEP 489) ───────────────────

const methods = [_]c.PyMethodDef{
    .{ .ml_name = "add_route", .ml_meth = @ptrCast(&pyAddRoute), .ml_flags = c.METH_VARARGS, .ml_doc = null },
    .{ .ml_name = "run", .ml_meth = @ptrCast(&pyRun), .ml_flags = c.METH_VARARGS, .ml_doc = null },
    ffi.wrapStateMethod("get_route_count", SnekModuleState, .noargs, getRouteCount),
    ffi.wrapStateMethod("redis_get", SnekModuleState, .onearg, redisGet),
    ffi.wrapStateMethod("redis_set", SnekModuleState, .fastcall, redisSet),
    ffi.wrapStateMethod("redis_setex", SnekModuleState, .fastcall, redisSetex),
    ffi.wrapStateMethod("redis_del", SnekModuleState, .fastcall, redisDel),
    ffi.wrapStateMethod("redis_incr", SnekModuleState, .fastcall, redisIncr),
    ffi.wrapStateMethod("redis_expire", SnekModuleState, .fastcall, redisExpire),
    ffi.wrapStateMethod("redis_ttl", SnekModuleState, .onearg, redisTtl),
    ffi.wrapStateMethod("redis_exists", SnekModuleState, .fastcall, redisExists),
    ffi.wrapStateMethod("redis_ping", SnekModuleState, .noargs, redisPing),
    ffi.wrapStateMethod("pg_execute", SnekModuleState, .fastcall, pgExecute),
    ffi.wrapStateMethod("pg_fetch_one", SnekModuleState, .fastcall, pgFetchOne),
    ffi.wrapStateMethod("pg_fetch_all", SnekModuleState, .fastcall, pgFetchAll),
    ffi.wrapStateMethod("pg_fetch_one_model", SnekModuleState, .fastcall, pgFetchOne),
    ffi.wrapStateMethod("pg_fetch_all_model", SnekModuleState, .fastcall, pgFetchAll),
    std.mem.zeroes(c.PyMethodDef), // sentinel
};

// ── Py_mod_exec slot: initialize module state ───────────────────────

fn snekModuleExec(mod: ?*PyObject) callconv(.c) c_int {
    const m = mod orelse return -1;
    const state: *SnekModuleState = getState(m) orelse return -1;
    state.py_handlers = .{null} ** MAX_HANDLERS;
    state.py_handler_count = 0;
    state.handler_flags = .{HandlerFlags{}} ** MAX_HANDLERS;
    state.future_types = .{};
    // route_entries don't need zeroing — only valid up to py_handler_count
    state.module_ref = .{0} ** 256;
    state.module_ref_len = 0;
    future_mod.initTypes(m, &state.future_types) catch {
        if (!ffi.errOccurred()) c.PyErr_SetString(c.PyExc_RuntimeError, "failed to initialize _snek future types");
        return -1;
    };
    return 0;
}

// ── GC callbacks for PyObject references in module state ────────────

fn snekModuleTraverse(mod: ?*PyObject, visit: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    const m = mod orelse return 0;
    const state: *SnekModuleState = getState(m) orelse return 0;
    if (future_mod.traverseTypes(&state.future_types, visit, arg) != 0) return -1;
    var i: u32 = 0;
    while (i < state.py_handler_count) : (i += 1) {
        if (state.py_handlers[i]) |handler| {
            const vret = visit.?(@ptrCast(@constCast(handler)), arg);
            if (vret != 0) return vret;
        }
    }
    return 0;
}

fn snekModuleClear(mod: ?*PyObject) callconv(.c) c_int {
    const m = mod orelse return 0;
    const state: *SnekModuleState = getState(m) orelse return 0;
    future_mod.clearTypes(&state.future_types);
    var i: u32 = 0;
    while (i < MAX_HANDLERS) : (i += 1) {
        if (state.py_handlers[i]) |handler| {
            state.py_handlers[i] = null;
            ffi.decref(handler);
        }
    }
    state.py_handler_count = 0;
    return 0;
}

fn snekModuleFree(mod_ptr: ?*anyopaque) callconv(.c) void {
    if (mod_ptr) |ptr| {
        const mod: *PyObject = @ptrCast(@alignCast(ptr));
        _ = snekModuleClear(mod);
    }
}

// ── Module slots (multi-phase init) ─────────────────────────────────

const module_slots = [_]c.PyModuleDef_Slot{
    .{ .slot = c.Py_mod_exec, .value = @ptrCast(@constCast(&snekModuleExec)) },
    .{ .slot = c.Py_mod_multiple_interpreters, .value = c.Py_MOD_PER_INTERPRETER_GIL_SUPPORTED },
    .{ .slot = 0, .value = null }, // sentinel
};

var module_def = ffi.moduleDef(
    "_snek",
    &methods,
    @sizeOf(SnekModuleState),
    &module_slots,
    &snekModuleTraverse,
    &snekModuleClear,
    &snekModuleFree,
);

/// CPython calls this when `import _snek` executes.
/// Multi-phase init: returns the module definition, not a created module.
pub export fn PyInit__snek() ?*PyObject {
    return ffi.moduleDefInit(&module_def);
}

// ── Registration for embedded interpreter ───────────────────────────

/// Register the _snek module as a built-in so the embedded interpreter
/// can import it. Must be called BEFORE Py_Initialize().
/// PyImport_AppendInittab works with multi-phase init.
pub fn registerBuiltin() void {
    _ = c.PyImport_AppendInittab("_snek", &pyInitSnek);
}

fn pyInitSnek() callconv(.c) ?*PyObject {
    return PyInit__snek();
}

// ── Cleanup ─────────────────────────────────────────────────────────

/// Release all stored Python handler references for a given module.
pub fn releaseHandlers(mod: *PyObject) void {
    const state = getState(mod) orelse return;
    var i: u32 = 0;
    while (i < MAX_HANDLERS) : (i += 1) {
        if (state.py_handlers[i]) |handler| {
            ffi.decref(handler);
            state.py_handlers[i] = null;
        }
        state.handler_flags[i] = HandlerFlags{};
    }
    state.py_handler_count = 0;
}

// ── Tests ───────────────────────────────────────────────────────────

test "module registers and imports" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();

    // Import the module
    const mod = try ffi.importModule("_snek");
    defer ffi.decref(mod);
    defer releaseHandlers(mod);

    // Verify get_route_count works
    const func = try ffi.getAttr(mod, "get_route_count");
    defer ffi.decref(func);
    const result = try ffi.callObject(func, null);
    defer ffi.decref(result);
    const count = try ffi.longAsLong(result);
    try std.testing.expectEqual(@as(c_long, 0), count);
}

test "add_route stores handler" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();

    const mod = try ffi.importModule("_snek");
    defer ffi.decref(mod);
    defer releaseHandlers(mod);

    // Register a lambda handler via Python
    try ffi.runString(
        \\import _snek
        \\_snek.add_route("GET", "/test", lambda req: {"status": "ok"})
    );

    // Verify handler count via module state
    const state = getState(mod).?;
    try std.testing.expectEqual(@as(u32, 1), state.py_handler_count);
    try std.testing.expect(state.py_handlers[0] != null);

    // Verify route metadata
    const entry = state.route_entries[0];
    try std.testing.expect(std.mem.eql(u8, entry.method[0..entry.method_len], "GET"));
    try std.testing.expect(std.mem.eql(u8, entry.path[0..entry.path_len], "/test"));
}

test "add_route rejects non-callable" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();

    const mod = try ffi.importModule("_snek");
    defer ffi.decref(mod);
    defer releaseHandlers(mod);

    // This should raise TypeError in Python
    const err = ffi.runString(
        \\import _snek
        \\_snek.add_route("GET", "/bad", "not a callable")
    );
    try std.testing.expectError(error.PythonError, err);
}

test "add_route multiple routes" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();

    const mod = try ffi.importModule("_snek");
    defer ffi.decref(mod);
    defer releaseHandlers(mod);

    try ffi.runString(
        \\import _snek
        \\_snek.add_route("GET", "/", lambda req: {"msg": "root"})
        \\_snek.add_route("POST", "/users", lambda req: {"msg": "create"})
        \\_snek.add_route("GET", "/users/{id}", lambda req, **kw: {"id": kw.get("id")})
    );

    const state = getState(mod).?;
    try std.testing.expectEqual(@as(u32, 3), state.py_handler_count);

    // Check each route entry
    const e0 = state.route_entries[0];
    try std.testing.expect(std.mem.eql(u8, e0.method[0..e0.method_len], "GET"));
    try std.testing.expect(std.mem.eql(u8, e0.path[0..e0.path_len], "/"));

    const e1 = state.route_entries[1];
    try std.testing.expect(std.mem.eql(u8, e1.method[0..e1.method_len], "POST"));
    try std.testing.expect(std.mem.eql(u8, e1.path[0..e1.path_len], "/users"));

    const e2 = state.route_entries[2];
    try std.testing.expect(std.mem.eql(u8, e2.method[0..e2.method_len], "GET"));
    try std.testing.expect(std.mem.eql(u8, e2.path[0..e2.path_len], "/users/{id}"));
}

test "call stored handler" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();

    const mod = try ffi.importModule("_snek");
    defer ffi.decref(mod);
    defer releaseHandlers(mod);

    try ffi.runString(
        \\import _snek
        \\_snek.add_route("GET", "/hello", lambda req: {"message": "hello from python"})
    );

    // Get the handler via state
    const state = getState(mod).?;
    const handler = state.py_handlers[0].?;

    // Build a request dict
    const req = try ffi.dictNew();
    defer ffi.decref(req);
    const method_val = try ffi.unicodeFromString("GET");
    defer ffi.decref(method_val);
    try ffi.dictSetItemString(req, "method", method_val);

    // Call: handler(req)
    const call_args = try ffi.tupleNew(1);
    ffi.incref(req);
    try ffi.tupleSetItem(call_args, 0, req); // steals ref
    const result = try ffi.callObject(handler, call_args);
    defer ffi.decref(result);
    ffi.decref(call_args);

    // Verify result is a dict with "message" key
    try std.testing.expect(ffi.isDict(result));
    const msg = ffi.dictGetItemString(result, "message"); // borrowed
    try std.testing.expect(msg != null);
    const msg_str = try ffi.unicodeAsUTF8(msg.?);
    try std.testing.expect(std.mem.eql(u8, std.mem.span(msg_str), "hello from python"));
}
