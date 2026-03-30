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

/// Vectorcall a Python callable with no arguments (PEP 590).
/// Fastest calling convention — no tuple creation, no method lookup.
pub fn vectorcallNoArgs(callable: *PyObject) PythonError!*PyObject {
    return c.PyObject_Vectorcall(callable, null, 0, null) orelse {
        c.PyErr_Print();
        return error.CallError;
    };
}

/// Vectorcall a Python callable with a single positional argument (PEP 590).
/// Avoids tuple creation — passes a stack array directly.
pub fn vectorcallOneArg(callable: *PyObject, arg: *PyObject) PythonError!*PyObject {
    var args = [1]?*PyObject{arg};
    return c.PyObject_Vectorcall(callable, @ptrCast(&args), 1, null) orelse {
        c.PyErr_Print();
        return error.CallError;
    };
}

/// Call a Python callable with args tuple and kwargs dict. Caller must decref result.
pub fn callObjectKwargs(callable: *PyObject, args: ?*PyObject, kwargs: *PyObject) PythonError!*PyObject {
    return c.PyObject_Call(callable, args, kwargs) orelse {
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

pub const OwnedPy = struct {
    obj: *PyObject,

    pub fn init(obj: *PyObject) OwnedPy {
        return .{ .obj = obj };
    }

    pub fn increfBorrowed(obj: *PyObject) OwnedPy {
        incref(obj);
        return .{ .obj = obj };
    }

    pub fn get(self: OwnedPy) *PyObject {
        return self.obj;
    }

    pub fn deinit(self: *OwnedPy) void {
        decref(self.obj);
        self.obj = undefined;
    }
};

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

/// Check if an object is a coroutine (from async def).
pub fn isCoroutine(obj: *PyObject) bool {
    return c.PyCoro_CheckExact(obj) != 0;
}

/// Properly close a suspended coroutine/generator by calling its .close() method.
/// This throws GeneratorExit into the coroutine, allowing finally blocks to run
/// and preventing GC corruption from half-unwound frames.
/// Must be called BEFORE decref on any coroutine that was suspended (yielded).
pub fn coroutineClose(coro: *PyObject) void {
    const close_result = c.PyObject_CallMethod(coro, "close", null);
    if (close_result) |r| {
        c.Py_DecRef(r);
    } else {
        c.PyErr_Clear();
    }
}

pub fn contextCopyCurrent() PythonError!*PyObject {
    return c.PyContext_CopyCurrent() orelse error.PythonError;
}

pub fn contextEnter(context: *PyObject) PythonError!void {
    if (c.PyContext_Enter(context) != 0) return error.PythonError;
}

pub fn contextExit(context: *PyObject) PythonError!void {
    if (c.PyContext_Exit(context) != 0) return error.PythonError;
}

/// Fast coroutine/generator send — bypasses method lookup, tuple creation,
/// and StopIteration exception overhead. Uses the am_send slot directly.
pub const SendResult = enum(c_int) { @"return" = 0, @"error" = -1, next = 1 };
pub fn iterSend(iter: *PyObject, arg: *PyObject) struct { result: ?*PyObject, status: SendResult } {
    var presult: ?*PyObject = null;
    const status: SendResult = @enumFromInt(c.PyIter_Send(iter, arg, &presult));
    return .{ .result = presult, .status = status };
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

/// Create a Python str from a pointer + length. No null terminator needed.
/// One copy: src buffer → Python heap. Python manages the result.
pub fn unicodeFromSlice(ptr: [*]const u8, len: usize) PythonError!*PyObject {
    return c.PyUnicode_DecodeUTF8(ptr, @intCast(len), null) orelse return error.PythonError;
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

/// Borrowed reference to None — no incref, do NOT decref.
/// Use for transient reads (e.g. passing to PyIter_Send which increfs internally).
pub fn none() *PyObject {
    return @ptrCast(&c._Py_NoneStruct);
}

/// Check if an object is None.
pub fn isNone(obj: *PyObject) bool {
    return obj == none();
}

/// New reference to None — caller must decref.
pub fn getNone() *PyObject {
    const n = none();
    incref(n);
    return n;
}

// ── Bytes operations ────────────────────────────────────────────────

/// Check if an object is bytes.
pub fn isBytes(obj: *PyObject) bool {
    return c.PyBytes_Check(obj) != 0;
}

/// Allocate a PyBytes with uninitialized buffer. Caller must decref.
/// Pass null data to get writable memory via bytesAsSlice.
pub fn bytesNew(len: isize) PythonError!*PyObject {
    return c.PyBytes_FromStringAndSize(null, len) orelse return error.PythonError;
}

/// Get a mutable pointer to the PyBytes internal buffer.
pub fn bytesAsSlice(obj: *PyObject, len: usize) [*]u8 {
    const ptr: [*]u8 = @ptrCast(c.PyBytes_AS_STRING(obj));
    _ = len;
    return ptr;
}

/// Get PyBytes data as a const slice.
pub fn bytesData(obj: *PyObject) []const u8 {
    const ptr: [*]const u8 = @ptrCast(c.PyBytes_AS_STRING(obj));
    const len: usize = @intCast(c.PyBytes_GET_SIZE(obj));
    return ptr[0..len];
}

// ── Tuple operations ────────────────────────────────────────────────

pub fn tupleNew(len: isize) PythonError!*PyObject {
    return c.PyTuple_New(len) orelse return error.PythonError;
}

/// Set item in tuple. Steals a reference to value.
pub fn tupleSetItem(tuple: *PyObject, index: isize, value: *PyObject) PythonError!void {
    if (c.PyTuple_SetItem(tuple, index, value) != 0) return error.PythonError;
}

/// Set item in tuple, consuming an owned reference whether insertion succeeds or fails.
pub fn tupleSetItemTake(tuple: *PyObject, index: isize, value: OwnedPy) PythonError!void {
    if (c.PyTuple_SetItem(tuple, index, value.obj) != 0) return error.PythonError;
}

pub fn listSetItemTake(list: *PyObject, index: isize, value: OwnedPy) PythonError!void {
    if (c.PyList_SetItem(list, index, value.obj) != 0) return error.PythonError;
}

// ── Dict operations ─────────────────────────────────────────────────

pub fn dictNew() PythonError!*PyObject {
    return c.PyDict_New() orelse return error.PythonError;
}

pub fn dictSetItemString(dict: *PyObject, key: [*:0]const u8, value: *PyObject) PythonError!void {
    if (c.PyDict_SetItemString(dict, key, value) != 0) return error.PythonError;
}

/// Set a dict item using a PyObject key (avoids temporary string creation).
pub fn dictSetItem(dict: *PyObject, key: *PyObject, value: *PyObject) PythonError!void {
    if (c.PyDict_SetItem(dict, key, value) != 0) return error.PythonError;
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

/// Wrap a Zig function as a CPython METH_FASTCALL method definition.
/// The Zig function signature: fn([*c]PyObject, [*c]const [*c]PyObject, isize) callconv(.c) [*c]PyObject
pub fn wrapFastCall(
    comptime name: [*:0]const u8,
    comptime func: *const fn ([*c]PyObject, [*c]const [*c]PyObject, isize) callconv(.c) [*c]PyObject,
) c.PyMethodDef {
    return .{
        .ml_name = name,
        .ml_meth = @ptrCast(func),
        .ml_flags = c.METH_FASTCALL,
        .ml_doc = null,
    };
}

/// Wrap a Zig function as a METH_NOARGS method that receives the module object.
/// The Zig function must accept *PyObject (the module) and return PythonError!*PyObject.
/// Used with multi-phase init where self is the module with per-interpreter state.
pub fn wrapNoArgsModule(comptime name: [*:0]const u8, comptime func: fn (*PyObject) PythonError!*PyObject) c.PyMethodDef {
    return .{
        .ml_name = name,
        .ml_meth = &struct {
            fn wrapper(self: ?*PyObject, _: ?*PyObject) callconv(.c) ?*PyObject {
                return func(self.?) catch |err| {
                    c.PyErr_SetString(c.PyExc_RuntimeError, @errorName(err));
                    return null;
                };
            }
        }.wrapper,
        .ml_flags = c.METH_NOARGS,
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
    return c.PyObject_Str(obj) orelse error.PythonError;
}

/// Create a PyModuleDef with the given name and methods table.
/// The methods slice must be null-terminated (last entry all zeroes).
///
/// For single-phase init: pass m_size = -1, slots = null, no GC callbacks.
/// For multi-phase init (PEP 489): pass m_size = @sizeOf(State), slots = &slot_array,
///   and GC callbacks (traverse/clear/free) for any PyObject* in the state.
pub fn moduleDef(
    name: [*:0]const u8,
    methods: [*]c.PyMethodDef,
    m_size: isize,
    slots: ?[*]c.PyModuleDef_Slot,
    traverse: c.traverseproc,
    clear: c.inquiry,
    free: c.freefunc,
) c.PyModuleDef {
    return .{
        .m_base = std.mem.zeroes(c.PyModuleDef_Base),
        .m_name = name,
        .m_doc = null,
        .m_size = m_size,
        .m_methods = methods,
        .m_slots = slots,
        .m_traverse = traverse,
        .m_clear = clear,
        .m_free = free,
    };
}

/// Initialize a multi-phase module definition (PEP 489).
/// Returns a PyObject* that CPython uses to create the module per-interpreter.
pub fn moduleDefInit(def: *c.PyModuleDef) ?*PyObject {
    return c.PyModuleDef_Init(def);
}

/// Get the per-interpreter module state from a module object.
/// Returns null if the module has no state (m_size <= 0).
pub fn moduleGetState(mod: *PyObject) ?*anyopaque {
    return c.PyModule_GetState(mod);
}

/// Create a module from a PyModuleDef (single-phase init).
/// Caller must decref the result.
pub fn createModule(def: *c.PyModuleDef) PythonError!*PyObject {
    return c.PyModule_Create(def) orelse return error.PythonError;
}

// ── Tests ───────────────────────────────────────────────────────────

test "initialize and finalize python" {
    init();
    defer deinit();
    // If we get here without crashing, init/deinit works.
    try std.testing.expect(c.Py_IsInitialized() != 0);
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
    try std.testing.expect(span.len > 0);
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
    try std.testing.expectEqual(@as(c_long, 7), val);
}

test "python exception handling" {
    init();
    defer deinit();

    // PyRun_SimpleString returns -1 on exception
    const err = runString("raise ValueError('test error')");
    try std.testing.expectError(error.PythonError, err);
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
    try std.testing.expect(std.mem.eql(u8, span, "hello snek"));
}

test "float round-trip" {
    init();
    defer deinit();

    const obj = try floatFromDouble(3.14);
    defer decref(obj);

    const val = try floatAsDouble(obj);
    try std.testing.expect(@abs(val - 3.14) < 0.001);
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
    try std.testing.expect(got != null);
    const got_val = try longAsLong(got.?);
    try std.testing.expectEqual(@as(c_long, 42), got_val);
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
    try std.testing.expectEqual(@as(isize, 1), size);
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
    try std.testing.expectEqual(@as(isize, 2), size);
}

test "bool and none" {
    init();
    defer deinit();

    const t = boolFromBool(true);
    defer decref(t);
    const f = boolFromBool(false);
    defer decref(f);

    const none_obj = getNone();
    defer decref(none_obj);
    try std.testing.expect(c.Py_IsNone(none_obj) != 0);
}

test "error set and check" {
    init();
    defer deinit();

    try std.testing.expect(!errOccurred());
    errSetString(c.PyExc_RuntimeError, "test error");
    try std.testing.expect(errOccurred());
    errClear();
    try std.testing.expect(!errOccurred());
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

    var def = moduleDef("test_wrap", &methods, -1, null, null, null, null);
    const mod = try createModule(&def);
    defer decref(mod);

    const func = try getAttr(mod, "answer");
    defer decref(func);

    const result = try callObject(func, null);
    defer decref(result);

    const val = try longAsLong(result);
    try std.testing.expectEqual(@as(c_long, 42), val);
}
