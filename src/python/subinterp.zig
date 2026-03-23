//! Per-worker sub-interpreter support (PEP 734).
//!
//! Each tardy thread creates its own sub-interpreter with its own GIL via
//! Py_NewInterpreterFromConfig(OWN_GIL). No cross-thread GIL contention.

const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;
const module = @import("module.zig");

extern fn Py_NewInterpreterFromConfig(tstate_p: *?*anyopaque, config: *const c.PyInterpreterConfig) c.PyStatus;
pub extern fn Py_EndInterpreter(tstate: *anyopaque) void;

/// Per-worker sub-interpreter: owns a thread state and a _snek module instance.
pub const WorkerPyContext = struct {
    tstate: *anyopaque,
    snek_module: *ffi.PyObject,

    /// Create a sub-interpreter for the calling thread.
    /// Acquires the main GIL (no-op if already held), creates the sub-interpreter,
    /// imports the user's app module. On error, cleans up via errdefer.
    pub fn init(module_ref: []const u8) !WorkerPyContext {
        _ = c.PyGILState_Ensure();

        var config = c.PyInterpreterConfig{
            .use_main_obmalloc = 0,
            .allow_fork = 0,
            .allow_exec = 0,
            .allow_threads = 1,
            .allow_daemon_threads = 0,
            .check_multi_interp_extensions = 1,
            .gil = 2, // OWN_GIL
        };
        var tstate: ?*anyopaque = null;
        const status = Py_NewInterpreterFromConfig(&tstate, &config);
        if (c.PyStatus_IsError(status) != 0 or tstate == null)
            return error.SubInterpreterCreateFailed;

        errdefer Py_EndInterpreter(tstate.?);

        // Sub-interpreters start with minimal sys.path — add cwd and site packages
        const sys_path = c.PySys_GetObject("path") orelse return error.SubInterpreterImportFailed;
        const cwd = try ffi.unicodeFromString(".");
        defer ffi.decref(cwd);
        _ = c.PyList_Insert(sys_path, 0, cwd);
        const site_mod = ffi.importModule("site") catch return error.SubInterpreterImportFailed;
        ffi.decref(site_mod);

        // Import user module (triggers @app.get() decorators → populates handler table)
        const sep = std.mem.indexOfScalar(u8, module_ref, ':') orelse
            return error.SubInterpreterImportFailed;
        var mod_name_buf: [256:0]u8 = undefined;
        if (sep >= mod_name_buf.len) return error.SubInterpreterImportFailed;
        @memcpy(mod_name_buf[0..sep], module_ref[0..sep]);
        mod_name_buf[sep] = 0;
        const user_mod = ffi.importModule(mod_name_buf[0..sep :0]) catch
            return error.SubInterpreterImportFailed;
        ffi.decref(user_mod);

        const snek_mod = ffi.importModule("snek._snek") catch
            return error.SubInterpreterImportFailed;

        return .{ .tstate = tstate.?, .snek_module = snek_mod };
    }

    /// Destroy the sub-interpreter. Must be called from the owning thread.
    pub fn deinit(self: *WorkerPyContext) void {
        module.releaseHandlers(self.snek_module);
        ffi.decref(self.snek_module);
        Py_EndInterpreter(self.tstate);
    }
};
