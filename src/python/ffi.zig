//! Three-layer CPython FFI bridge.
//!
//! Layer 1: Raw CPython C API bindings via @cImport.
//! Layer 2: Zig-idiomatic wrappers with error handling and refcount helpers.
//! Layer 3: Comptime function wrapper — converts Zig functions to CPython
//!          callables, handling error union → PyErr_SetString conversion.
//!
//! Sources:
//!   - Three-layer FFI bridge from Bun (refs/bun/INSIGHTS.md — C++→C extern→Zig)
//!   - wrapPyFunction comptime wrapper from Bun's toJSHostFn pattern

const std = @import("std");

// ── Layer 1: Raw CPython C API ──────────────────────────────────────

pub const c = @cImport({
    @cInclude("Python.h");
});

/// Opaque PyObject pointer from CPython.
pub const PyObject = c.PyObject;

// ── Layer 2: Zig-idiomatic wrappers ─────────────────────────────────

pub const PythonError = error{
    PythonError,
    ImportError,
    AttributeError,
    TypeError,
    CallError,
    ConversionError,
};

/// Initialize the CPython interpreter.
pub fn init() void {
    c.Py_Initialize();
}

/// Finalize the CPython interpreter.
pub fn deinit() void {
    if (c.Py_IsInitialized() != 0) {
        c.Py_Finalize();
    }
}

/// Execute a Python code string. Returns error.PythonError on failure.
pub fn runString(code: [*:0]const u8) PythonError!void {
    if (c.PyRun_SimpleString(code) != 0) return error.PythonError;
}

/// Import a Python module by name. Caller must decref the returned object.
pub fn importModule(name: [*:0]const u8) PythonError!*PyObject {
    return c.PyImport_ImportModule(name) orelse {
        c.PyErr_Print();
        return error.ImportError;
    };
}

/// Get an attribute from a Python object. Caller must decref the result.
pub fn getAttr(obj: *PyObject, attr: [*:0]const u8) PythonError!*PyObject {
    return c.PyObject_GetAttrString(obj, attr) orelse {
        c.PyErr_Print();
        return error.AttributeError;
    };
}

/// Set an attribute on a Python object.
pub fn setAttr(obj: *PyObject, attr: [*:0]const u8, value: *PyObject) PythonError!void {
    if (c.PyObject_SetAttrString(obj, attr, value) != 0) {
        c.PyErr_Print();
        return error.AttributeError;
    }
}

/// Call a Python callable with optional args tuple. Caller must decref result.
pub fn callObject(callable: *PyObject, args: ?*PyObject) PythonError!*PyObject {
    return c.PyObject_CallObject(callable, args) orelse {
        c.PyErr_Print();
        return error.CallError;
    };
}

// ── Reference counting ──────────────────────────────────────────────

pub fn incref(obj: *PyObject) void {
    c.Py_IncRef(obj);
}

pub fn decref(obj: *PyObject) void {
    c.Py_DecRef(obj);
}

pub fn xincref(obj: ?*PyObject) void {
    if (obj) |o| c.Py_IncRef(o);
}

pub fn xdecref(obj: ?*PyObject) void {
    if (obj) |o| c.Py_DecRef(o);
}

// ── Error handling ──────────────────────────────────────────────────

/// Check if a Python exception is currently set.
pub fn errOccurred() bool {
    return c.PyErr_Occurred() != null;
}

/// Clear any pending Python exception.
pub fn errClear() void {
    c.PyErr_Clear();
}

/// Set a Python exception with a message string.
pub fn errSetString(exc_type: *PyObject, message: [*:0]const u8) void {
    c.PyErr_SetString(exc_type, message);
}

/// Print and clear the current Python exception (to stderr).
pub fn errPrint() void {
    c.PyErr_Print();
}

// ── Object creation helpers ─────────────────────────────────────────

pub fn longFromLong(v: c_long) PythonError!*PyObject {
    return c.PyLong_FromLong(v) orelse return error.PythonError;
}

pub fn longAsLong(obj: *PyObject) PythonError!c_long {
    const val = c.PyLong_AsLong(obj);
    if (val == -1 and c.PyErr_Occurred() != null) return error.ConversionError;
    return val;
}

pub fn floatFromDouble(v: f64) PythonError!*PyObject {
    return c.PyFloat_FromDouble(v) orelse return error.PythonError;
}

pub fn floatAsDouble(obj: *PyObject) PythonError!f64 {
    const val = c.PyFloat_AsDouble(obj);
    if (val == -1.0 and c.PyErr_Occurred() != null) return error.ConversionError;
    return val;
}

pub fn unicodeFromString(s: [*:0]const u8) PythonError!*PyObject {
    return c.PyUnicode_FromString(s) orelse return error.PythonError;
}

pub fn unicodeAsUTF8(obj: *PyObject) PythonError![*:0]const u8 {
    return c.PyUnicode_AsUTF8(obj) orelse {
        c.PyErr_Print();
        return error.ConversionError;
    };
}

pub fn boolFromBool(v: bool) *PyObject {
    return c.PyBool_FromLong(@intFromBool(v));
}

pub fn getNone() *PyObject {
    const none: *PyObject = @ptrCast(&c._Py_NoneStruct);
    incref(none);
    return none;
}

// ── Tuple operations ────────────────────────────────────────────────

pub fn tupleNew(len: isize) PythonError!*PyObject {
    return c.PyTuple_New(len) orelse return error.PythonError;
}

/// Set item in tuple. Steals a reference to value.
pub fn tupleSetItem(tuple: *PyObject, index: isize, value: *PyObject) PythonError!void {
    if (c.PyTuple_SetItem(tuple, index, value) != 0) return error.PythonError;
}

// ── Dict operations ─────────────────────────────────────────────────

pub fn dictNew() PythonError!*PyObject {
    return c.PyDict_New() orelse return error.PythonError;
}

pub fn dictSetItemString(dict: *PyObject, key: [*:0]const u8, value: *PyObject) PythonError!void {
    if (c.PyDict_SetItemString(dict, key, value) != 0) return error.PythonError;
}

/// Returns a borrowed reference (do not decref).
pub fn dictGetItemString(dict: *PyObject, key: [*:0]const u8) ?*PyObject {
    return c.PyDict_GetItemString(dict, key);
}

// ── List operations ─────────────────────────────────────────────────

pub fn listNew(len: isize) PythonError!*PyObject {
    return c.PyList_New(len) orelse return error.PythonError;
}

pub fn listAppend(list: *PyObject, item: *PyObject) PythonError!void {
    if (c.PyList_Append(list, item) != 0) return error.PythonError;
}

// ── Layer 3: Comptime function wrapper ──────────────────────────────

/// Wrap a Zig function as a CPython method definition.
/// The Zig function must take no arguments (METH_NOARGS) and return
/// either *PyObject or PythonError!*PyObject.
pub fn wrapNoArgs(comptime name: [*:0]const u8, comptime func: fn () PythonError!*PyObject) c.PyMethodDef {
    return .{
        .ml_name = name,
        .ml_meth = &struct {
            fn wrapper(_: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
                return func() catch |err| {
                    c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
                    return null;
                };
            }
        }.wrapper,
        .ml_flags = c.METH_NOARGS,
        .ml_doc = null,
    };
}

/// Wrap a Zig function as a CPython METH_VARARGS method definition.
/// The Zig function signature: fn(?*PyObject, ?*PyObject) callconv(.c) ?*PyObject
pub fn wrapVarArgs(comptime name: [*:0]const u8, comptime func: *const fn (?*PyObject, ?*PyObject) callconv(.c) ?*PyObject) c.PyMethodDef {
    return .{
        .ml_name = name,
        .ml_meth = func,
        .ml_flags = c.METH_VARARGS,
        .ml_doc = null,
    };
}

/// Python str check.
pub fn isString(obj: *PyObject) bool {
    return c.PyUnicode_Check(obj) != 0;
}

/// Python dict check.
pub fn isDict(obj: *PyObject) bool {
    return c.PyDict_Check(obj) != 0;
}

/// Python tuple check.
pub fn isTuple(obj: *PyObject) bool {
    return c.PyTuple_Check(obj) != 0;
}

/// Python callable check.
pub fn isCallable(obj: *PyObject) bool {
    return c.PyCallable_Check(obj) != 0;
}

/// Get tuple item (borrowed reference — do NOT decref).
pub fn tupleGetItem(tuple: *PyObject, index: isize) ?*PyObject {
    return c.PyTuple_GetItem(tuple, index);
}

/// Get tuple size.
pub fn tupleSize(tuple: *PyObject) isize {
    return c.PyTuple_Size(tuple);
}

/// Get dict size.
pub fn dictSize(dict: *PyObject) isize {
    return c.PyDict_Size(dict);
}

/// Iterate over dict items. Returns 0 when iteration is done.
/// pos must be initialized to 0 before first call.
/// key and value are borrowed references.
pub fn dictNext(dict: *PyObject, pos: *isize, key: *?*PyObject, value: *?*PyObject) bool {
    return c.PyDict_Next(dict, pos, key, value) != 0;
}

/// Get Python object's string representation. Caller must decref.
pub fn objectStr(obj: *PyObject) PythonError!*PyObject {
    return c.PyObject_Str(obj) orelse {
        c.PyErr_Print();
        return error.ConversionError;
    };
}

/// Create a PyModuleDef with the given name and methods table.
/// The methods slice must be null-terminated (last entry all zeroes).
pub fn moduleDef(name: [*:0]const u8, methods: [*]c.PyMethodDef) c.PyModuleDef {
    return .{
        .m_base = std.mem.zeroes(c.PyModuleDef_Base),
        .m_name = name,
        .m_doc = null,
        .m_size = -1,
        .m_methods = methods,
        .m_slots = null,
        .m_traverse = null,
        .m_clear = null,
        .m_free = null,
    };
}

/// Create a module from a PyModuleDef. Caller must decref the result.
pub fn createModule(def: *c.PyModuleDef) PythonError!*PyObject {
    return c.PyModule_Create(def) orelse return error.PythonError;
}

// ── Tests ───────────────────────────────────────────────────────────

test "initialize and finalize python" {
    init();
    defer deinit();
    // If we get here without crashing, init/deinit works.
    std.testing.expect(c.Py_IsInitialized() != 0) catch unreachable;
}

test "run python string" {
    init();
    defer deinit();
    try runString("x = 1 + 1");
}

test "import module" {
    init();
    defer deinit();

    const sys = try importModule("sys");
    defer decref(sys);

    const version = try getAttr(sys, "version");
    defer decref(version);

    const version_str = try unicodeAsUTF8(version);
    const span = std.mem.span(version_str);
    // Python 3.14 version string starts with "3.14"
    std.testing.expect(span.len > 0) catch unreachable;
}

test "call python function" {
    init();
    defer deinit();

    try runString("def add(a, b): return a + b");

    const main_mod = try importModule("__main__");
    defer decref(main_mod);

    const add_fn = try getAttr(main_mod, "add");
    defer decref(add_fn);

    const args = try tupleNew(2);
    // tupleSetItem steals the reference — no decref on the items
    try tupleSetItem(args, 0, try longFromLong(3));
    try tupleSetItem(args, 1, try longFromLong(4));

    const result = try callObject(add_fn, args);
    defer decref(result);
    decref(args);

    const val = try longAsLong(result);
    std.testing.expectEqual(@as(c_long, 7), val) catch unreachable;
}

test "python exception handling" {
    init();
    defer deinit();

    // PyRun_SimpleString returns -1 on exception
    const err = runString("raise ValueError('test error')");
    std.testing.expectError(error.PythonError, err) catch unreachable;
}

test "reference counting" {
    init();
    defer deinit();

    // Create object, verify refcount management doesn't crash
    const obj = try longFromLong(42);
    incref(obj);
    decref(obj);
    decref(obj);

    // xincref/xdecref handle null safely
    xincref(null);
    xdecref(null);

    // Verify gc.collect() reports no issues
    try runString("import gc; gc.collect()");
}

test "unicode round-trip" {
    init();
    defer deinit();

    const obj = try unicodeFromString("hello snek");
    defer decref(obj);

    const back = try unicodeAsUTF8(obj);
    const span = std.mem.span(back);
    std.testing.expect(std.mem.eql(u8, span, "hello snek")) catch unreachable;
}

test "float round-trip" {
    init();
    defer deinit();

    const obj = try floatFromDouble(3.14);
    defer decref(obj);

    const val = try floatAsDouble(obj);
    std.testing.expect(@abs(val - 3.14) < 0.001) catch unreachable;
}

test "dict operations" {
    init();
    defer deinit();

    const dict = try dictNew();
    defer decref(dict);

    const val = try longFromLong(42);
    try dictSetItemString(dict, "key", val);
    decref(val);

    const got = dictGetItemString(dict, "key"); // borrowed ref
    std.testing.expect(got != null) catch unreachable;
    const got_val = try longAsLong(got.?);
    std.testing.expectEqual(@as(c_long, 42), got_val) catch unreachable;
}

test "list operations" {
    init();
    defer deinit();

    const list = try listNew(0);
    defer decref(list);

    const item = try longFromLong(99);
    try listAppend(list, item);
    decref(item);

    const size = c.PyList_Size(list);
    std.testing.expectEqual(@as(isize, 1), size) catch unreachable;
}

test "tuple operations" {
    init();
    defer deinit();

    const tuple = try tupleNew(2);
    defer decref(tuple);

    // tupleSetItem steals refs
    try tupleSetItem(tuple, 0, try longFromLong(10));
    try tupleSetItem(tuple, 1, try longFromLong(20));

    const size = c.PyTuple_Size(tuple);
    std.testing.expectEqual(@as(isize, 2), size) catch unreachable;
}

test "bool and none" {
    init();
    defer deinit();

    const t = boolFromBool(true);
    defer decref(t);
    const f = boolFromBool(false);
    defer decref(f);

    const none = getNone();
    defer decref(none);
    std.testing.expect(c.Py_IsNone(none) != 0) catch unreachable;
}

test "error set and check" {
    init();
    defer deinit();

    std.testing.expect(!errOccurred()) catch unreachable;
    errSetString(c.PyExc_RuntimeError, "test error");
    std.testing.expect(errOccurred()) catch unreachable;
    errClear();
    std.testing.expect(!errOccurred()) catch unreachable;
}

test "wrapNoArgs produces valid method" {
    init();
    defer deinit();

    const answer = struct {
        fn call() PythonError!*PyObject {
            return longFromLong(42);
        }
    }.call;

    var methods = [_]c.PyMethodDef{
        wrapNoArgs("answer", answer),
        std.mem.zeroes(c.PyMethodDef),
    };

    var def = moduleDef("test_wrap", &methods);
    const mod = try createModule(&def);
    defer decref(mod);

    const func = try getAttr(mod, "answer");
    defer decref(func);

    const result = try callObject(func, null);
    defer decref(result);

    const val = try longAsLong(result);
    std.testing.expectEqual(@as(c_long, 42), val) catch unreachable;
}
