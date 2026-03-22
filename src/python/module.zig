//! _snek C extension module: initialization, method table, and registrations.
//!
//! This is the entry point for the CPython extension. Defines the module
//! with abi3 stable ABI markers, registers routes/injectables/models/
//! middleware/lifecycle hooks from Python decorators.

const ffi = @import("ffi.zig");
const coerce = @import("coerce.zig");
const driver = @import("driver.zig");
const inject = @import("inject.zig");

// ── Module definition (abi3 stable ABI) ─────────────────────────────

pub const module_name: [*:0]const u8 = "_snek";

pub const module_doc: [*:0]const u8 =
    "snek native extension — Zig-backed web framework runtime.";

pub const module_def = ffi.PyModuleDef{
    .name = module_name,
    .doc = module_doc,
    .size = -1,
    .methods = &module_methods,
};

/// Method table exposed to Python.
pub const module_methods = [_]ffi.PyMethodDef{
    ffi.wrapPyFunction(pyRegisterRoute),
    ffi.wrapPyFunction(pyRegisterInjectable),
    ffi.wrapPyFunction(pyRegisterModel),
    ffi.wrapPyFunction(pyRegisterMiddleware),
    ffi.wrapPyFunction(pyRegisterOnStartup),
    ffi.wrapPyFunction(pyRegisterOnShutdown),
    ffi.wrapPyFunction(pySpawn),
};

// ── PyInit entry point ──────────────────────────────────────────────

/// CPython calls this when `import _snek` executes. abi3 stable ABI.
pub fn PyInit__snek() callconv(.c) ?*ffi.PyObject {
    // Stub: call PyModule_Create(&module_def), return the module object.
    return null;
}

// ── Route registration ──────────────────────────────────────────────

fn pyRegisterRoute(self: ?*ffi.PyObject, args: ?*ffi.PyObject) callconv(.c) ?*ffi.PyObject {
    _ = .{ self, args };
    // Stub: extract method, path, handler from args.
    // Run ParameterExtractor on handler at registration time.
    // Store in route table for the Zig HTTP router.
    return null;
}

// ── Injectable registration (@app.injectable) ───────────────────────

fn pyRegisterInjectable(self: ?*ffi.PyObject, args: ?*ffi.PyObject) callconv(.c) ?*ffi.PyObject {
    _ = .{ self, args };
    // Stub: extract factory function, scope, type annotation.
    // Register in DependencyGraph.
    return null;
}

// ── Model registration (snek.Model subclasses) ─────────────────────

fn pyRegisterModel(self: ?*ffi.PyObject, args: ?*ffi.PyObject) callconv(.c) ?*ffi.PyObject {
    _ = .{ self, args };
    // Stub: receive Model subclass, run SchemaBuilder.inspectAnnotations,
    // compile and cache the SchemaNode tree for fused decode+validate.
    return null;
}

// ── Middleware registration ─────────────────────────────────────────

fn pyRegisterMiddleware(self: ?*ffi.PyObject, args: ?*ffi.PyObject) callconv(.c) ?*ffi.PyObject {
    _ = .{ self, args };
    // Stub: extract middleware function, hooks (before/after), priority.
    return null;
}

// ── Lifecycle hook registration ─────────────────────────────────────

fn pyRegisterOnStartup(self: ?*ffi.PyObject, args: ?*ffi.PyObject) callconv(.c) ?*ffi.PyObject {
    _ = .{ self, args };
    return null;
}

fn pyRegisterOnShutdown(self: ?*ffi.PyObject, args: ?*ffi.PyObject) callconv(.c) ?*ffi.PyObject {
    _ = .{ self, args };
    return null;
}

// ── Background task spawning ────────────────────────────────────────

fn pySpawn(self: ?*ffi.PyObject, args: ?*ffi.PyObject) callconv(.c) ?*ffi.PyObject {
    _ = .{ self, args };
    // Stub: extract callable + args, create a Spawn sentinel,
    // submit to the scheduler as fire-and-forget.
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "module init PyInit__snek" {}

test "register route" {}

test "register injectable" {}

test "register model triggers schema compilation" {}

test "register middleware" {}

test "register lifecycle hooks" {}

test "spawn background task" {}
