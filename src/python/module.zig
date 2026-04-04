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
const server_mod = @import("../server.zig");
const response_hint_mod = @import("../response_hint.zig");
const ResponseHint = response_hint_mod.ResponseHint;

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
    /// Cached response conversion hint.
    response_hint: u8 = @intFromEnum(ResponseHint.any),
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
    /// "module:attr" ref for sub-interpreters to re-import the user app.
    /// Stored as a null-terminated fixed buffer (e.g. "app:app\x00...").
    module_ref: [256]u8,
    module_ref_len: u16,
};

/// Temporary global module reference. Set during pyRun so driver.startServer
/// can access the module state. Will be replaced by per-worker interpreter
/// state in the next refactor step.
var g_current_module: ?*PyObject = null;

/// Get the current module object. Used by driver.zig to access state
/// during server operation (temporary — next step makes this per-worker).
pub fn getCurrentModule() ?*PyObject {
    return g_current_module;
}

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

/// Get the current handler count.
pub fn getHandlerCount(mod: *PyObject) u32 {
    const state = getState(mod) orelse return 0;
    return state.py_handler_count;
}

/// Get route entry by handler_id.
pub fn getRouteEntry(mod: *PyObject, handler_id: u32) ?RouteEntry {
    const state = getState(mod) orelse return null;
    if (handler_id >= state.py_handler_count) return null;
    return state.route_entries[handler_id];
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
    flags.response_hint = @intFromEnum(inspectResponseHint(handler_obj));

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

fn inspectResponseHint(handler_obj: *PyObject) ResponseHint {
    const return_obj = resolvedReturnAnnotation(handler_obj) orelse return .any;
    defer ffi.decref(return_obj);
    return classifyResponseHint(return_obj);
}

fn resolvedReturnAnnotation(handler_obj: *PyObject) ?*PyObject {
    if (resolvedReturnAnnotationViaTyping(handler_obj)) |resolved| return resolved;
    if (resolvedReturnAnnotationFromDict(handler_obj)) |raw| return raw;
    return null;
}

fn resolvedReturnAnnotationViaTyping(handler_obj: *PyObject) ?*PyObject {
    const typing_mod = ffi.importModuleRaw("typing") catch return null;
    defer ffi.decref(typing_mod);
    const get_type_hints = ffi.getAttrRaw(typing_mod, "get_type_hints") catch return null;
    defer ffi.decref(get_type_hints);
    const hints = ffi.callOneArg(get_type_hints, handler_obj) catch {
        ffi.errClear();
        return null;
    };
    defer ffi.decref(hints);
    if (!ffi.isDict(hints)) return null;
    const return_obj = ffi.dictGetItemString(hints, "return") orelse return null;
    return ffi.increfBorrowed(return_obj);
}

fn resolvedReturnAnnotationFromDict(handler_obj: *PyObject) ?*PyObject {
    const annotations = ffi.getAttrOptional(handler_obj, "__annotations__") catch return null;
    if (annotations == null) return null;
    defer ffi.decref(annotations.?);
    if (!ffi.isDict(annotations.?)) return null;
    const return_obj = ffi.dictGetItemString(annotations.?, "return") orelse return null;
    return ffi.increfBorrowed(return_obj);
}

fn classifyResponseHint(return_obj: *PyObject) ResponseHint {
    if (isStrAnnotation(return_obj)) return .str;
    if (isBytesAnnotation(return_obj)) return .bytes;
    if (isRowBackedAnnotation(return_obj)) return .row_json;
    return .any;
}

fn normalizedAnnotationString(obj: *PyObject) ?[]const u8 {
    if (!ffi.isString(obj)) return null;
    const value = ffi.unicodeAsUTF8(obj) catch return null;
    var span: []const u8 = std.mem.span(value);
    if (span.len >= 2) {
        const first = span[0];
        const last = span[span.len - 1];
        if ((first == '\'' and last == '\'') or (first == '"' and last == '"')) {
            span = span[1 .. span.len - 1];
        }
    }
    return span;
}

fn isStrAnnotation(return_obj: *PyObject) bool {
    if (normalizedAnnotationString(return_obj)) |span| {
        return std.mem.eql(u8, span, "str");
    }

    const builtins = ffi.importModuleRaw("builtins") catch return false;
    defer ffi.decref(builtins);
    const str_type = ffi.getAttrRaw(builtins, "str") catch return false;
    defer ffi.decref(str_type);
    return return_obj == str_type;
}

fn isBytesAnnotation(return_obj: *PyObject) bool {
    if (normalizedAnnotationString(return_obj)) |span| {
        return std.mem.eql(u8, span, "bytes") or std.mem.eql(u8, span, "memoryview");
    }

    const builtins = ffi.importModuleRaw("builtins") catch return false;
    defer ffi.decref(builtins);
    const bytes_type = ffi.getAttrRaw(builtins, "bytes") catch return false;
    defer ffi.decref(bytes_type);
    if (return_obj == bytes_type) return true;

    const memoryview_type = ffi.getAttrRaw(builtins, "memoryview") catch return false;
    defer ffi.decref(memoryview_type);
    return return_obj == memoryview_type;
}

fn isRowBackedAnnotation(return_obj: *PyObject) bool {
    if (normalizedAnnotationString(return_obj)) |span| {
        return std.mem.eql(u8, span, "snek.Row");
    }

    const row_factory = ffi.getAttrOptional(return_obj, "_snek_from_row") catch return false;
    if (row_factory) |value| {
        ffi.decref(value);
        return true;
    }
    return false;
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

/// _snek.add_route(method: str, path: str, handler: callable)
///
/// Registers a Python handler for the given HTTP method + path.
/// In multi-phase init, self is the module object with per-interpreter state.
fn pyAddRoute(self_mod: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    const mod = self_mod orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "module object is null");
        return null;
    };
    const state: *SnekModuleState = getState(mod) orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "module state not initialized");
        return null;
    };

    const tuple = args orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "add_route requires 3 arguments");
        return null;
    };

    if (!ffi.isTuple(tuple) or ffi.tupleSize(tuple) != 3) {
        c.PyErr_SetString(c.PyExc_TypeError, "add_route(method, path, handler) requires exactly 3 arguments");
        return null;
    }

    // Extract method string
    const method_obj = ffi.tupleGetItem(tuple, 0) orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "method must be a string");
        return null;
    };
    if (!ffi.isString(method_obj)) {
        c.PyErr_SetString(c.PyExc_TypeError, "method must be a string");
        return null;
    }
    const method_str = ffi.unicodeAsUTF8(method_obj) catch {
        c.PyErr_SetString(c.PyExc_TypeError, "method must be a valid UTF-8 string");
        return null;
    };

    // Extract path string
    const path_obj = ffi.tupleGetItem(tuple, 1) orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "path must be a string");
        return null;
    };
    if (!ffi.isString(path_obj)) {
        c.PyErr_SetString(c.PyExc_TypeError, "path must be a string");
        return null;
    }
    const path_str = ffi.unicodeAsUTF8(path_obj) catch {
        c.PyErr_SetString(c.PyExc_TypeError, "path must be a valid UTF-8 string");
        return null;
    };

    // Extract handler callable
    const handler_obj = ffi.tupleGetItem(tuple, 2) orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "handler must be a callable");
        return null;
    };
    if (!ffi.isCallable(handler_obj)) {
        c.PyErr_SetString(c.PyExc_TypeError, "handler must be a callable");
        return null;
    }

    // Store handler
    if (state.py_handler_count >= MAX_HANDLERS) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "too many handlers registered (max 64)");
        return null;
    }

    const id = state.py_handler_count;

    // Store route metadata
    const method_span = std.mem.span(method_str);
    const path_span = std.mem.span(path_str);

    if (method_span.len > 8) {
        c.PyErr_SetString(c.PyExc_ValueError, "method string too long (max 8 chars)");
        return null;
    }
    if (path_span.len > 256) {
        c.PyErr_SetString(c.PyExc_ValueError, "path string too long (max 256 chars)");
        return null;
    }

    var entry: RouteEntry = undefined;
    @memcpy(entry.method[0..method_span.len], method_span);
    entry.method_len = @intCast(method_span.len);
    @memcpy(entry.path[0..path_span.len], path_span);
    entry.path_len = @intCast(path_span.len);
    state.route_entries[id] = entry;

    // Incref the handler — we own a reference now
    ffi.incref(handler_obj);
    state.py_handlers[id] = handler_obj;

    // Inspect handler signature to determine calling convention flags.
    state.handler_flags[id] = inspectHandlerFlags(handler_obj);

    state.py_handler_count = id + 1;

    return ffi.getNone();
}

/// _snek.run(host: str, port: int, module_ref: str = "")
///
/// Starts the Zig HTTP server. Blocks until the server shuts down.
/// Routes must be registered via add_route() before calling run().
/// module_ref is "module:attr" (e.g. "app:app") so sub-interpreters
/// can re-import the user's app independently.
fn pyRun(self_mod: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    const mod = self_mod orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "module object is null");
        return null;
    };

    const tuple = args orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "run requires 2-3 arguments");
        return null;
    };

    const tuple_size = if (ffi.isTuple(tuple)) ffi.tupleSize(tuple) else 0;
    if (tuple_size < 3 or tuple_size > 5) {
        c.PyErr_SetString(c.PyExc_TypeError, "run(host, port, threads[, module_ref[, backlog]]) requires 3-5 arguments");
        return null;
    }

    // Extract host string
    const host_obj = ffi.tupleGetItem(tuple, 0) orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "host must be a string");
        return null;
    };
    if (!ffi.isString(host_obj)) {
        c.PyErr_SetString(c.PyExc_TypeError, "host must be a string");
        return null;
    }
    const host_str = ffi.unicodeAsUTF8(host_obj) catch {
        c.PyErr_SetString(c.PyExc_TypeError, "host must be a valid UTF-8 string");
        return null;
    };

    // Extract port int
    const port_obj = ffi.tupleGetItem(tuple, 1) orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "port must be an integer");
        return null;
    };
    const port_long = ffi.longAsLong(port_obj) catch {
        c.PyErr_SetString(c.PyExc_TypeError, "port must be an integer");
        return null;
    };
    if (port_long < 0 or port_long > 65535) {
        c.PyErr_SetString(c.PyExc_ValueError, "port must be 0-65535");
        return null;
    }

    // Extract threads int
    const threads_obj = ffi.tupleGetItem(tuple, 2) orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "threads must be an integer");
        return null;
    };
    const threads_long = ffi.longAsLong(threads_obj) catch {
        c.PyErr_SetString(c.PyExc_TypeError, "threads must be an integer");
        return null;
    };
    if (threads_long < 1 or threads_long > 256) {
        c.PyErr_SetString(c.PyExc_ValueError, "threads must be 1-256");
        return null;
    }

    // Extract optional module_ref string (e.g. "app:app")
    const state: *SnekModuleState = getState(mod) orelse {
        c.PyErr_SetString(c.PyExc_RuntimeError, "module state not initialized");
        return null;
    };
    if (tuple_size >= 4) {
        const ref_obj = ffi.tupleGetItem(tuple, 3) orelse {
            c.PyErr_SetString(c.PyExc_TypeError, "module_ref must be a string");
            return null;
        };
        if (ffi.isString(ref_obj)) {
            const ref_str = ffi.unicodeAsUTF8(ref_obj) catch {
                c.PyErr_SetString(c.PyExc_TypeError, "module_ref must be valid UTF-8");
                return null;
            };
            const ref_span = std.mem.span(ref_str);
            if (ref_span.len > 0 and ref_span.len < state.module_ref.len) {
                @memcpy(state.module_ref[0..ref_span.len], ref_span);
                state.module_ref_len = @intCast(ref_span.len);
            }
        }
    }

    const host_span = std.mem.span(host_str);
    const port: u16 = @intCast(port_long);
    const threads: usize = @intCast(threads_long);

    // Extract optional backlog (tuple index 4, default 2048)
    var backlog: u16 = 2048;
    if (tuple_size >= 5) {
        if (ffi.tupleGetItem(tuple, 4)) |obj| {
            const bl = ffi.longAsLong(obj) catch {
                c.PyErr_SetString(c.PyExc_TypeError, "backlog must be an integer");
                return null;
            };
            if (bl < 1 or bl > 65535) {
                c.PyErr_SetString(c.PyExc_ValueError, "backlog must be 1-65535");
                return null;
            }
            backlog = @intCast(bl);
        }
    }

    // Set global module ref so driver can access state (temporary)
    g_current_module = mod;
    defer g_current_module = null;

    // Start the server with Python handlers wired in.
    driver.startServer(host_span, port, threads, backlog) catch {
        c.PyErr_SetString(c.PyExc_RuntimeError, "failed to start server");
        return null;
    };

    return ffi.getNone();
}

// ── Redis bridge ────────────────────────────────────────────────────

/// _snek.redis_command("GET", "key") or _snek.redis_command("SET", "key", "val")
/// Uses the thread-local redis connection and tardy runtime for async I/O.
/// Bulk string responses are received directly into PyBytes (zero-copy).
fn pyRedisCommand(_: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
    // TODO: async redis support for Python handlers
    c.PyErr_SetString(c.PyExc_RuntimeError, "redis_command: async path not yet implemented");
    return null;
}

// ── Module definition (multi-phase init, PEP 489) ───────────────────

fn pyGetRouteCountImpl(mod: *PyObject) ffi.PythonError!*PyObject {
    const state = getState(mod) orelse return error.PythonError;
    return ffi.longFromLong(@intCast(state.py_handler_count));
}

var methods = [_]c.PyMethodDef{
    ffi.wrapVarArgs("add_route", &pyAddRoute),
    ffi.wrapVarArgs("run", &pyRun),
    ffi.wrapNoArgsModule("get_route_count", pyGetRouteCountImpl),
    ffi.wrapVarArgs("redis_command", &pyRedisCommand),
    std.mem.zeroes(c.PyMethodDef), // sentinel
};

// ── Py_mod_exec slot: initialize module state ───────────────────────

fn snekModuleExec(mod: ?*PyObject) callconv(.c) c_int {
    const m = mod orelse return -1;
    const state: *SnekModuleState = getState(m) orelse return -1;
    state.py_handlers = .{null} ** MAX_HANDLERS;
    state.py_handler_count = 0;
    state.handler_flags = .{HandlerFlags{}} ** MAX_HANDLERS;
    // route_entries don't need zeroing — only valid up to py_handler_count
    state.module_ref = .{0} ** 256;
    state.module_ref_len = 0;
    return 0;
}

// ── GC callbacks for PyObject references in module state ────────────

fn snekModuleTraverse(mod: ?*PyObject, visit: c.visitproc, arg: ?*anyopaque) callconv(.c) c_int {
    const m = mod orelse return 0;
    const state: *SnekModuleState = getState(m) orelse return 0;
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

var module_slots = [_]c.PyModuleDef_Slot{
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

test "add_route stores str response hint from annotation" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();

    const mod = try ffi.importModule("_snek");
    defer ffi.decref(mod);
    defer releaseHandlers(mod);

    try ffi.runString(
        \\import _snek
        \\def hello() -> str:
        \\    return "ok"
        \\_snek.add_route("GET", "/text", hello)
    );

    const state = getState(mod).?;
    try std.testing.expectEqual(@as(u32, 1), state.py_handler_count);
    try std.testing.expectEqual(@intFromEnum(ResponseHint.str), state.handler_flags[0].response_hint);
}

test "add_route stores stringified str response hint from annotation" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();

    const mod = try ffi.importModule("_snek");
    defer ffi.decref(mod);
    defer releaseHandlers(mod);

    try ffi.runString(
        \\from __future__ import annotations
        \\import _snek
        \\def hello() -> "str":
        \\    return "ok"
        \\_snek.add_route("GET", "/text", hello)
    );

    const state = getState(mod).?;
    try std.testing.expectEqual(@as(u32, 1), state.py_handler_count);
    try std.testing.expectEqual(@intFromEnum(ResponseHint.str), state.handler_flags[0].response_hint);
}

test "add_route stores bytes response hint from annotation" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();

    const mod = try ffi.importModule("_snek");
    defer ffi.decref(mod);
    defer releaseHandlers(mod);

    try ffi.runString(
        \\import _snek
        \\def hello() -> bytes:
        \\    return b"ok"
        \\_snek.add_route("GET", "/bytes", hello)
    );

    const state = getState(mod).?;
    try std.testing.expectEqual(@as(u32, 1), state.py_handler_count);
    try std.testing.expectEqual(@intFromEnum(ResponseHint.bytes), state.handler_flags[0].response_hint);
}

test "add_route stores row_json response hint from model annotation" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();

    const mod = try ffi.importModule("_snek");
    defer ffi.decref(mod);
    defer releaseHandlers(mod);

    try ffi.runString(
        \\import _snek
        \\class MyModel:
        \\    @classmethod
        \\    def _snek_from_row(cls, row):
        \\        return cls()
        \\def hello() -> MyModel:
        \\    return MyModel()
        \\_snek.add_route("GET", "/model", hello)
    );

    const state = getState(mod).?;
    try std.testing.expectEqual(@as(u32, 1), state.py_handler_count);
    try std.testing.expectEqual(@intFromEnum(ResponseHint.row_json), state.handler_flags[0].response_hint);
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
