//! _snek C extension module: the entry point for Python → Zig integration.
//!
//! Exposes module-level functions to Python:
//!   _snek.add_route(method, path, handler) — registers a route + Python callable
//!   _snek.run(host, port)                  — starts the Zig HTTP server
//!
//! Under the hood, add_route stores the Python callable in a global route table.
//! run() starts the Zig HTTP server, and for each request the server looks up
//! the callable by handler_id and calls driver.invokePythonHandler().

const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;
const PyObject = ffi.PyObject;
const driver = @import("driver.zig");

// ── Global route table ──────────────────────────────────────────────

/// Maximum number of Python handlers that can be registered.
const MAX_HANDLERS: usize = 64;

/// Python callables stored by handler_id. Owned references (incref'd).
var py_handlers: [MAX_HANDLERS]?*PyObject = .{null} ** MAX_HANDLERS;
var py_handler_count: u32 = 0;

/// Route metadata stored alongside handlers for server setup.
const RouteEntry = struct {
    method: [8]u8,
    method_len: u8,
    path: [256]u8,
    path_len: u16,
};

var route_entries: [MAX_HANDLERS]RouteEntry = undefined;

/// Get stored Python callable by handler_id.
pub fn getHandler(handler_id: u32) ?*PyObject {
    if (handler_id >= MAX_HANDLERS) return null;
    return py_handlers[handler_id];
}

/// Get the current handler count.
pub fn getHandlerCount() u32 {
    return py_handler_count;
}

/// Get route entry by handler_id.
pub fn getRouteEntry(handler_id: u32) ?RouteEntry {
    if (handler_id >= py_handler_count) return null;
    return route_entries[handler_id];
}

// ── Module methods ──────────────────────────────────────────────────

/// _snek.add_route(method: str, path: str, handler: callable)
///
/// Registers a Python handler for the given HTTP method + path.
/// The handler must be a callable that accepts a request dict and returns
/// a dict (JSON), string (text/plain), or tuple (status, body).
fn pyAddRoute(_: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
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
    if (py_handler_count >= MAX_HANDLERS) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "too many handlers registered (max 64)");
        return null;
    }

    const id = py_handler_count;

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
    route_entries[id] = entry;

    // Incref the handler — we own a reference now
    ffi.incref(handler_obj);
    py_handlers[id] = handler_obj;
    py_handler_count = id + 1;

    return ffi.getNone();
}

/// _snek.run(host: str, port: int)
///
/// Starts the Zig HTTP server. Blocks until the server shuts down.
/// Routes must be registered via add_route() before calling run().
fn pyRun(_: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    const tuple = args orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "run requires 2 arguments");
        return null;
    };

    if (!ffi.isTuple(tuple) or ffi.tupleSize(tuple) != 2) {
        c.PyErr_SetString(c.PyExc_TypeError, "run(host, port) requires exactly 2 arguments");
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

    const host_span = std.mem.span(host_str);
    const port: u16 = @intCast(port_long);

    // Start the server with Python handlers wired in.
    // Release the GIL while the server runs (it will reacquire per-request).
    driver.startServer(host_span, port) catch {
        c.PyErr_SetString(c.PyExc_RuntimeError, "failed to start server");
        return null;
    };

    return ffi.getNone();
}

// ── Module definition ───────────────────────────────────────────────

fn pyGetRouteCountImpl() ffi.PythonError!*PyObject {
    return ffi.longFromLong(@intCast(py_handler_count));
}

var methods = [_]c.PyMethodDef{
    ffi.wrapVarArgs("add_route", &pyAddRoute),
    ffi.wrapVarArgs("run", &pyRun),
    ffi.wrapNoArgs("get_route_count", pyGetRouteCountImpl),
    std.mem.zeroes(c.PyMethodDef), // sentinel
};

var module_def = ffi.moduleDef("_snek", &methods);

/// CPython calls this when `import _snek` executes.
pub export fn PyInit__snek() ?*PyObject {
    return ffi.createModule(&module_def) catch null;
}

// ── Registration for embedded interpreter ───────────────────────────

/// Register the _snek module as a built-in so the embedded interpreter
/// can import it. Must be called BEFORE Py_Initialize().
pub fn registerBuiltin() void {
    // PyImport_AppendInittab adds our init function to the built-in module table.
    _ = c.PyImport_AppendInittab("_snek", &pyInitSnek);
}

fn pyInitSnek() callconv(.c) ?*PyObject {
    return PyInit__snek();
}

// ── Cleanup ─────────────────────────────────────────────────────────

/// Release all stored Python handler references.
pub fn releaseHandlers() void {
    for (&py_handlers) |*h| {
        if (h.*) |obj| {
            ffi.decref(obj);
            h.* = null;
        }
    }
    py_handler_count = 0;
}

// ── Tests ───────────────────────────────────────────────────────────

test "module registers and imports" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();
    defer releaseHandlers();

    // Import the module
    const mod = try ffi.importModule("_snek");
    defer ffi.decref(mod);

    // Verify get_route_count works
    const func = try ffi.getAttr(mod, "get_route_count");
    defer ffi.decref(func);
    const result = try ffi.callObject(func, null);
    defer ffi.decref(result);
    const count = try ffi.longAsLong(result);
    std.testing.expectEqual(@as(c_long, 0), count) catch unreachable;
}

test "add_route stores handler" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();
    defer releaseHandlers();

    // Register a lambda handler via Python
    try ffi.runString(
        \\import _snek
        \\_snek.add_route("GET", "/test", lambda req: {"status": "ok"})
    );

    // Verify handler count
    std.testing.expectEqual(@as(u32, 1), py_handler_count) catch unreachable;
    std.testing.expect(py_handlers[0] != null) catch unreachable;

    // Verify route metadata
    const entry = route_entries[0];
    std.testing.expect(std.mem.eql(u8, entry.method[0..entry.method_len], "GET")) catch unreachable;
    std.testing.expect(std.mem.eql(u8, entry.path[0..entry.path_len], "/test")) catch unreachable;
}

test "add_route rejects non-callable" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();
    defer releaseHandlers();

    // This should raise TypeError in Python
    const err = ffi.runString(
        \\import _snek
        \\_snek.add_route("GET", "/bad", "not a callable")
    );
    std.testing.expectError(error.PythonError, err) catch unreachable;
}

test "add_route multiple routes" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();
    defer releaseHandlers();

    try ffi.runString(
        \\import _snek
        \\_snek.add_route("GET", "/", lambda req: {"msg": "root"})
        \\_snek.add_route("POST", "/users", lambda req: {"msg": "create"})
        \\_snek.add_route("GET", "/users/{id}", lambda req, **kw: {"id": kw.get("id")})
    );

    std.testing.expectEqual(@as(u32, 3), py_handler_count) catch unreachable;

    // Check each route entry
    const e0 = route_entries[0];
    std.testing.expect(std.mem.eql(u8, e0.method[0..e0.method_len], "GET")) catch unreachable;
    std.testing.expect(std.mem.eql(u8, e0.path[0..e0.path_len], "/")) catch unreachable;

    const e1 = route_entries[1];
    std.testing.expect(std.mem.eql(u8, e1.method[0..e1.method_len], "POST")) catch unreachable;
    std.testing.expect(std.mem.eql(u8, e1.path[0..e1.path_len], "/users")) catch unreachable;

    const e2 = route_entries[2];
    std.testing.expect(std.mem.eql(u8, e2.method[0..e2.method_len], "GET")) catch unreachable;
    std.testing.expect(std.mem.eql(u8, e2.path[0..e2.path_len], "/users/{id}")) catch unreachable;
}

test "call stored handler" {
    registerBuiltin();
    ffi.init();
    defer ffi.deinit();
    defer releaseHandlers();

    try ffi.runString(
        \\import _snek
        \\_snek.add_route("GET", "/hello", lambda req: {"message": "hello from python"})
    );

    // Get the handler and call it directly
    const handler = py_handlers[0].?;

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
    std.testing.expect(ffi.isDict(result)) catch unreachable;
    const msg = ffi.dictGetItemString(result, "message"); // borrowed
    std.testing.expect(msg != null) catch unreachable;
    const msg_str = try ffi.unicodeAsUTF8(msg.?);
    std.testing.expect(std.mem.eql(u8, std.mem.span(msg_str), "hello from python")) catch unreachable;
}
