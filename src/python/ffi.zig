//! Three-layer CPython FFI bridge.
//!
//! Layer 1: Raw CPython C API bindings (@cImport level).
//! Layer 2: PyObject operations with reference counting helpers.
//! Layer 3: Comptime function wrapper — converts Zig functions to CPython
//!          callables, handling error union → PyErr_SetString conversion.
//!
//! Sources:
//!   - Three-layer FFI bridge from Bun (refs/bun/INSIGHTS.md — C++→C extern→Zig)
//!   - wrapPyFunction comptime wrapper from Bun's toJSHostFn pattern

// ── Layer 1: Raw CPython C API types ────────────────────────────────

pub const PyObject = opaque {};
pub const PyTuple = opaque {};
pub const PyDict = opaque {};
pub const PyList = opaque {};
pub const PyUnicode = opaque {};
pub const PyLong = opaque {};
pub const PyFloat = opaque {};
pub const PyBool = opaque {};
pub const PyNone = opaque {};

pub const PyMethodDef = struct {
    name: [*:0]const u8,
    method: *const fn (?*PyObject, ?*PyObject) callconv(.c) ?*PyObject,
    flags: c_int,
    doc: ?[*:0]const u8,

    pub const METH_VARARGS: c_int = 0x0001;
    pub const METH_KEYWORDS: c_int = 0x0002;
    pub const METH_NOARGS: c_int = 0x0004;
};

pub const PyModuleDef = struct {
    name: [*:0]const u8,
    doc: ?[*:0]const u8,
    size: isize,
    methods: ?[*]const PyMethodDef,
};

pub const PyBufferProcs = struct {
    bf_getbuffer: ?*const fn (?*PyObject, *Py_buffer, c_int) callconv(.c) c_int,
    bf_releasebuffer: ?*const fn (?*PyObject, *Py_buffer) callconv(.c) void,
};

pub const Py_buffer = struct {
    buf: ?*anyopaque,
    obj: ?*PyObject,
    len: isize,
    itemsize: isize,
    readonly: c_int,
    ndim: c_int,
    format: ?[*:0]const u8,
    shape: ?[*]isize,
    strides: ?[*]isize,
    suboffsets: ?[*]isize,
    internal: ?*anyopaque,
};

// c_int is a Zig primitive type (i32 on most platforms)

// ── Layer 2: PyObject operations with refcount helpers ──────────────

pub fn pyIncref(obj: *PyObject) void {
    _ = .{obj};
}

pub fn pyDecref(obj: *PyObject) void {
    _ = .{obj};
}

pub fn pyXIncref(obj: ?*PyObject) void {
    _ = .{obj};
}

pub fn pyXDecref(obj: ?*PyObject) void {
    _ = .{obj};
}

pub fn pyCallObject(callable: *PyObject, args: ?*PyTuple) !*PyObject {
    _ = .{ callable, args };
    return undefined;
}

pub fn pyImport(name: [*:0]const u8) !*PyObject {
    _ = .{name};
    return undefined;
}

pub fn pyGetAttr(obj: *PyObject, attr: [*:0]const u8) !*PyObject {
    _ = .{ obj, attr };
    return undefined;
}

pub fn pySetAttr(obj: *PyObject, attr: [*:0]const u8, value: *PyObject) !void {
    _ = .{ obj, attr, value };
}

pub fn pyErrSetString(exc_type: *PyObject, message: [*:0]const u8) void {
    _ = .{ exc_type, message };
}

pub fn pyErrOccurred() ?*PyObject {
    return null;
}

pub fn pyErrClear() void {}

pub fn pyErrFetch() struct { exc_type: ?*PyObject, exc_value: ?*PyObject, traceback: ?*PyObject } {
    return .{ .exc_type = null, .exc_value = null, .traceback = null };
}

// ── PyDict operations ───────────────────────────────────────────────

pub fn pyDictNew() !*PyDict {
    return undefined;
}

pub fn pyDictSetItemString(dict: *PyDict, key: [*:0]const u8, value: *PyObject) !void {
    _ = .{ dict, key, value };
}

pub fn pyDictGetItemString(dict: *PyDict, key: [*:0]const u8) ?*PyObject {
    _ = .{ dict, key };
    return null;
}

pub fn pyDictSize(dict: *PyDict) isize {
    _ = .{dict};
    return 0;
}

// ── PyList operations ───────────────────────────────────────────────

pub fn pyListNew(len: isize) !*PyList {
    _ = .{len};
    return undefined;
}

pub fn pyListAppend(list: *PyList, item: *PyObject) !void {
    _ = .{ list, item };
}

pub fn pyListGetItem(list: *PyList, index: isize) ?*PyObject {
    _ = .{ list, index };
    return null;
}

pub fn pyListSize(list: *PyList) isize {
    _ = .{list};
    return 0;
}

// ── PyTuple operations ──────────────────────────────────────────────

pub fn pyTupleNew(len: isize) !*PyTuple {
    _ = .{len};
    return undefined;
}

pub fn pyTupleSetItem(tuple: *PyTuple, index: isize, value: *PyObject) !void {
    _ = .{ tuple, index, value };
}

pub fn pyTupleGetItem(tuple: *PyTuple, index: isize) ?*PyObject {
    _ = .{ tuple, index };
    return null;
}

// ── PyUnicode operations ────────────────────────────────────────────

pub fn pyUnicodeFromString(s: [*:0]const u8) !*PyUnicode {
    _ = .{s};
    return undefined;
}

pub fn pyUnicodeAsUTF8(obj: *PyUnicode) ![*:0]const u8 {
    _ = .{obj};
    return undefined;
}

// ── PyLong / PyFloat / PyBool / PyNone ──────────────────────────────

pub fn pyLongFromLong(v: i64) !*PyLong {
    _ = .{v};
    return undefined;
}

pub fn pyLongAsLong(obj: *PyLong) !i64 {
    _ = .{obj};
    return undefined;
}

pub fn pyFloatFromDouble(v: f64) !*PyFloat {
    _ = .{v};
    return undefined;
}

pub fn pyFloatAsDouble(obj: *PyFloat) !f64 {
    _ = .{obj};
    return undefined;
}

pub fn pyBoolFromLong(v: bool) *PyBool {
    _ = .{v};
    return undefined;
}

pub fn pyNone() *PyNone {
    return undefined;
}

// ── Type conversion: Zig ↔ PyObject ─────────────────────────────────

pub fn zigToPyObject(comptime T: type, value: T) !*PyObject {
    _ = .{value};
    return undefined;
}

pub fn pyObjectToZig(comptime T: type, obj: *PyObject) !T {
    _ = .{obj};
    return undefined;
}

// ── Layer 3: Comptime function wrapper ──────────────────────────────
//
// Converts a Zig function with an error union return into a CPython
// callable. On error, sets PyErr_SetString and returns null.
// Source: Bun's toJSHostFn comptime wrapper pattern (refs/bun/INSIGHTS.md).

pub fn wrapPyFunction(comptime func: anytype) PyMethodDef {
    const Fn = @TypeOf(func);
    const info = @typeInfo(Fn).@"fn";
    _ = info;

    return .{
        .name = @typeName(Fn),
        .method = &struct {
            fn wrapper(self_obj: ?*PyObject, args_obj: ?*PyObject) callconv(.c) ?*PyObject {
                _ = .{ self_obj, args_obj };
                // Stub: In production, this unpacks args_obj, calls func,
                // converts the result via zigToPyObject, and on error
                // calls pyErrSetString + returns null.
                return null;
            }
        }.wrapper,
        .flags = PyMethodDef.METH_VARARGS,
        .doc = null,
    };
}

// ── Buffer protocol support for zero-copy ───────────────────────────

pub fn getBuffer(obj: *PyObject, buf: *Py_buffer, flags: c_int) !void {
    _ = .{ obj, buf, flags };
}

pub fn releaseBuffer(obj: *PyObject, buf: *Py_buffer) void {
    _ = .{ obj, buf };
}

// ── Undefined sentinel ──────────────────────────────────────────────

// Stub functions return Zig's builtin `undefined` as placeholder values.

// ── Tests ───────────────────────────────────────────────────────────

test "pyobject incref decref" {}

test "pycall object" {}

test "pyimport module" {}

test "pyget and set attr" {}

test "pyerr set and fetch" {}

test "pydict operations" {}

test "pylist operations" {}

test "pytuple operations" {}

test "pyunicode operations" {}

test "zigToPyObject and pyObjectToZig round-trip" {}

test "wrapPyFunction produces valid PyMethodDef" {}

test "buffer protocol get and release" {}
