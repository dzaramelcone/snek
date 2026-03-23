//! Per-worker sub-interpreter support (PEP 734).
//!
//! Each worker thread creates its own Python sub-interpreter with its own GIL
//! via Py_NewInterpreterFromConfig(OWN_GIL). This enables true parallel Python
//! handler execution — no GIL contention between workers.
//!
//! Lifecycle:
//!   1. Worker thread acquires the MAIN interpreter's GIL
//!   2. Calls Py_NewInterpreterFromConfig → gets a new sub-interpreter + its own GIL
//!   3. Imports the user's app module (re-runs decorators, gets its own handlers)
//!   4. Runs the event loop — all handler calls use THIS interpreter's GIL
//!   5. At shutdown: cleanup the sub-interpreter
//!
//! PyObjects CANNOT be shared across interpreters. Each sub-interpreter has its own
//! _snek module instance with its own handler table.

const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;
const PyObject = ffi.PyObject;
const module = @import("module.zig");
const driver = @import("driver.zig");
const http1 = @import("../net/http1.zig");
const router_mod = @import("../http/router.zig");
const response_mod = @import("../http/response.zig");

// ── CPython sub-interpreter constants ───────────────────────────────

/// PyInterpreterConfig_OWN_GIL — each sub-interpreter gets its own GIL.
const OWN_GIL: c_int = 2;

// ── Sub-interpreter creation ────────────────────────────────────────

// CPython's PyThreadState contains an opaque sub-struct that @cImport can't
// embed. Use *anyopaque everywhere for thread state pointers, matching gil.zig.
extern fn Py_NewInterpreterFromConfig(tstate_p: *?*anyopaque, config: *const c.PyInterpreterConfig) c.PyStatus;
extern fn Py_EndInterpreter(tstate: *anyopaque) void;

/// Create a sub-interpreter with its own GIL. Acquires the main interpreter's
/// GIL, calls Py_NewInterpreterFromConfig, and returns the new thread state.
/// On success, the calling thread is switched to the new sub-interpreter.
/// On failure, the main GIL is released before returning the error.
fn createSubInterpreter() !*anyopaque {
    const main_gil_state = c.PyGILState_Ensure();

    var config = c.PyInterpreterConfig{
        .use_main_obmalloc = 0,
        .allow_fork = 0,
        .allow_exec = 0,
        .allow_threads = 1,
        .allow_daemon_threads = 0,
        .check_multi_interp_extensions = 1,
        .gil = OWN_GIL,
    };
    var tstate: ?*anyopaque = null;
    const status = Py_NewInterpreterFromConfig(&tstate, &config);

    if (c.PyStatus_IsError(status) != 0 or tstate == null) {
        c.PyGILState_Release(main_gil_state);
        std.log.err("Py_NewInterpreterFromConfig failed", .{});
        return error.SubInterpreterCreateFailed;
    }

    // Success: we are now on the new sub-interpreter's thread state.
    // Py_NewInterpreterFromConfig has detached us from the main interpreter.
    // Do NOT release main_gil_state — we're no longer on that interpreter.

    return tstate.?;
}

// ── Per-worker Python context ───────────────────────────────────────

/// Holds the per-worker sub-interpreter state: its thread state and
/// a reference to the _snek module (with its own handler table).
pub const WorkerPyContext = struct {
    /// The sub-interpreter's PyThreadState (as *anyopaque). Owned by this worker.
    tstate: ?*anyopaque,
    /// The _snek module in this sub-interpreter. Borrowed (module stays alive
    /// as long as the interpreter does).
    snek_module: ?*PyObject,

    /// Create a sub-interpreter for this worker thread.
    ///
    /// Must be called from the worker thread. Acquires the main interpreter's
    /// GIL to create the sub-interpreter, then switches to the new one.
    ///
    /// module_ref: "module:attr" string (e.g. "app:app") — the user's app.
    pub fn init(module_ref: []const u8) !WorkerPyContext {
        // Acquire the main interpreter's GIL to call Py_NewInterpreterFromConfig.
        // On success, the new sub-interpreter is attached and we hold ITS GIL.
        // On failure, we must release the main GIL.
        const tstate = try createSubInterpreter();

        // Set up sys.path — sub-interpreters start with minimal path.
        // Add cwd and import site to get venv packages.
        const sys_path = c.PySys_GetObject("path") orelse return error.SubInterpreterImportFailed;
        const cwd = try ffi.unicodeFromString(".");
        defer ffi.decref(cwd);
        if (c.PyList_Insert(sys_path, 0, cwd) != 0) return error.SubInterpreterImportFailed;
        // Import site to activate venv site-packages
        const site_mod = ffi.importModule("site") catch return error.SubInterpreterImportFailed;
        ffi.decref(site_mod);

        // Parse "module:attr" into module name and attr name
        const sep = std.mem.indexOfScalar(u8, module_ref, ':') orelse {
            std.log.err("sub-interpreter: invalid module_ref (no ':')", .{});
            return error.SubInterpreterImportFailed;
        };

        var mod_name_buf: [256:0]u8 = undefined;
        if (sep >= mod_name_buf.len) return error.SubInterpreterImportFailed;
        @memcpy(mod_name_buf[0..sep], module_ref[0..sep]);
        mod_name_buf[sep] = 0;

        // Import the user's module — this triggers all @app.get() etc decorators,
        // which call _snek.add_route() — populating THIS interpreter's handler table.
        const user_mod = ffi.importModule(mod_name_buf[0..sep :0]) catch {
            std.log.err("sub-interpreter: failed to import module", .{});
            return error.SubInterpreterImportFailed;
        };
        defer ffi.decref(user_mod);

        // Get the _snek module — it was populated by the decorators
        const snek_mod = ffi.importModule("snek._snek") catch {
            std.log.err("sub-interpreter: failed to import snek._snek", .{});
            return error.SubInterpreterImportFailed;
        };

        return .{
            .tstate = tstate,
            .snek_module = snek_mod,
        };
    }

    /// Clean up the sub-interpreter. Must be called from the same worker thread.
    pub fn deinit(self: *WorkerPyContext) void {
        if (self.snek_module) |mod| {
            module.releaseHandlers(mod);
            ffi.decref(mod);
            self.snek_module = null;
        }
        if (self.tstate) |ts| {
            Py_EndInterpreter(ts);
            self.tstate = null;
        }
    }

    /// Invoke a Python handler using this worker's sub-interpreter.
    /// No shared GIL acquire needed — this worker already holds its own GIL.
    pub fn invokePythonHandler(
        self: *WorkerPyContext,
        handler_id: u32,
        parser: *const http1.Parser,
        params: []const router_mod.PathParam,
        resp_body_buf: []u8,
    ) response_mod.Response {
        const mod = self.snek_module orelse {
            return response_mod.Response.init(500);
        };
        const handler = module.getHandler(mod, handler_id) orelse {
            return response_mod.Response.init(500);
        };
        const flags = module.getHandlerFlags(mod, handler_id);

        // No GIL acquire/release — we own our sub-interpreter's GIL permanently.
        // Dispatch based on handler flags (same logic as driver.invokePythonHandler)
        const call_result = if (flags.no_args) blk: {
            break :blk ffi.callObject(handler, null) catch {
                if (ffi.errOccurred()) ffi.errPrint();
                return response_mod.Response.init(500);
            };
        } else if (flags.needs_params) blk: {
            const empty_args = ffi.tupleNew(0) catch {
                return response_mod.Response.init(500);
            };
            defer ffi.decref(empty_args);

            if (params.len > 0) {
                const kwargs = driver.buildParamsKwargs(params) catch {
                    return response_mod.Response.init(500);
                };
                defer ffi.decref(kwargs);
                break :blk ffi.callObjectKwargs(handler, empty_args, kwargs) catch {
                    if (ffi.errOccurred()) ffi.errPrint();
                    return response_mod.Response.init(500);
                };
            } else {
                break :blk ffi.callObject(handler, empty_args) catch {
                    if (ffi.errOccurred()) ffi.errPrint();
                    return response_mod.Response.init(500);
                };
            }
        } else blk: {
            const req_dict = driver.buildRequestDict(parser, params) catch {
                return response_mod.Response.init(500);
            };
            defer ffi.decref(req_dict);

            const call_args = ffi.tupleNew(1) catch {
                return response_mod.Response.init(500);
            };
            ffi.incref(req_dict);
            ffi.tupleSetItem(call_args, 0, req_dict) catch {
                ffi.decref(call_args);
                return response_mod.Response.init(500);
            };

            const result = ffi.callObject(handler, call_args) catch {
                ffi.decref(call_args);
                if (ffi.errOccurred()) ffi.errPrint();
                return response_mod.Response.init(500);
            };
            ffi.decref(call_args);
            break :blk result;
        };

        // Drive coroutines (async def) to completion
        const py_result = if (ffi.isCoroutine(call_result)) blk: {
            const none = ffi.getNone();
            defer ffi.decref(none);
            if (ffi.callMethod1(call_result, "send", none)) |unexpected| {
                ffi.decref(unexpected);
                ffi.decref(call_result);
                return response_mod.Response.init(501);
            } else |_| {
                const exc = ffi.errFetch();
                defer {
                    if (exc.exc_type) |t| ffi.decref(t);
                    if (exc.exc_tb) |tb| ffi.decref(tb);
                }
                ffi.decref(call_result);
                if (exc.exc_value) |val| {
                    const result = ffi.stopIterationValue(val) orelse val;
                    if (result != val) ffi.decref(val);
                    break :blk result;
                }
                return response_mod.Response.init(500);
            }
        } else call_result;
        defer ffi.decref(py_result);

        return driver.convertPythonResponse(py_result, resp_body_buf) catch {
            return response_mod.Response.init(500);
        };
    }
};
