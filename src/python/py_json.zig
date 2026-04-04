const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;
const PyObject = ffi.PyObject;
const json_serialize = @import("../json/serialize.zig");
const row_json = @import("row_json.zig");

pub const WriteError = ffi.PythonError || error{BufferTooSmall};
const InternalError = WriteError || error{UnsupportedType};
const Serializer = json_serialize.Serializer;

inline fn exactType(obj: *PyObject, tp: *c.PyTypeObject) bool {
    return c.Py_TYPE(obj) == tp;
}

fn writeString(s: *Serializer, obj: *PyObject) InternalError!void {
    const utf8 = try ffi.unicodeAsUTF8(obj);
    s.string(std.mem.span(utf8)) catch return error.BufferTooSmall;
}

fn writeInt(s: *Serializer, obj: *PyObject) InternalError!void {
    const signed = c.PyLong_AsLongLong(obj);
    if (!(signed == -1 and c.PyErr_Occurred() != null)) {
        s.integer(signed) catch return error.BufferTooSmall;
        return;
    }
    c.PyErr_Clear();

    const unsigned = c.PyLong_AsUnsignedLongLong(obj);
    if (unsigned == std.math.maxInt(c_ulonglong) and c.PyErr_Occurred() != null) {
        return error.ConversionError;
    }
    s.unsigned(unsigned) catch return error.BufferTooSmall;
}

fn writeFloat(s: *Serializer, obj: *PyObject) InternalError!void {
    const value = try ffi.floatAsDouble(obj);
    if (!std.math.isFinite(value)) {
        s.null_() catch return error.BufferTooSmall;
        return;
    }
    s.float(value) catch return error.BufferTooSmall;
}

fn writeArrayLike(
    s: *Serializer,
    obj: *PyObject,
    len: isize,
    getItem: *const fn (*PyObject, isize) ?*PyObject,
) InternalError!void {
    s.beginArray() catch return error.BufferTooSmall;
    var i: isize = 0;
    while (i < len) : (i += 1) {
        const item = getItem(obj, i) orelse return error.ConversionError;
        try writeValue(s, item);
    }
    s.endArray() catch return error.BufferTooSmall;
}

fn listGetItem(list: *PyObject, index: isize) ?*PyObject {
    return c.PyList_GetItem(list, index);
}

fn tupleGetItem(tuple: *PyObject, index: isize) ?*PyObject {
    return ffi.tupleGetItem(tuple, index);
}

fn writeDict(s: *Serializer, obj: *PyObject) InternalError!void {
    s.beginObject() catch return error.BufferTooSmall;
    var iter_pos: c.Py_ssize_t = 0;
    var key: ?*PyObject = null;
    var value: ?*PyObject = null;
    while (c.PyDict_Next(obj, &iter_pos, &key, &value) != 0) {
        const key_obj = key orelse return error.ConversionError;
        if (!ffi.isString(key_obj)) return error.UnsupportedType;
        const key_utf8 = try ffi.unicodeAsUTF8(key_obj);
        s.key(std.mem.span(key_utf8)) catch return error.BufferTooSmall;
        try writeValue(s, value.?);
    }
    s.endObject() catch return error.BufferTooSmall;
}

fn tryWriteRowLike(s: *Serializer, obj: *PyObject) InternalError!bool {
    const start = s.beginValue() catch return error.BufferTooSmall;
    if (try row_json.tryWrite(obj, s.buf, &s.pos)) {
        s.finishValue();
        return true;
    }
    s.rewind(start);
    return false;
}

fn tryWriteModelDump(s: *Serializer, obj: *PyObject) InternalError!bool {
    const callable = try ffi.getAttrOptional(obj, "model_dump");
    if (callable == null) return false;
    defer ffi.decref(callable.?);

    const dumped = try ffi.callNoArgs(callable.?);
    defer ffi.decref(dumped);
    try writeValue(s, dumped);
    return true;
}

fn writeExactValue(s: *Serializer, obj: *PyObject) InternalError!bool {
    if (ffi.isNone(obj)) {
        s.null_() catch return error.BufferTooSmall;
        return true;
    }

    if (exactType(obj, &c.PyLong_Type)) {
        try writeInt(s, obj);
        return true;
    }
    if (exactType(obj, &c.PyBool_Type)) {
        s.boolean(try ffi.objectIsTrue(obj)) catch return error.BufferTooSmall;
        return true;
    }
    if (exactType(obj, &c.PyFloat_Type)) {
        try writeFloat(s, obj);
        return true;
    }
    if (exactType(obj, &c.PyUnicode_Type)) {
        try writeString(s, obj);
        return true;
    }
    if (exactType(obj, &c.PyList_Type)) {
        const len = c.PyList_Size(obj);
        if (len < 0) return error.ConversionError;
        try writeArrayLike(s, obj, len, &listGetItem);
        return true;
    }
    if (exactType(obj, &c.PyDict_Type)) {
        try writeDict(s, obj);
        return true;
    }
    if (exactType(obj, &c.PyTuple_Type)) {
        const len = ffi.tupleSize(obj);
        if (len < 0) return error.ConversionError;
        try writeArrayLike(s, obj, len, &tupleGetItem);
        return true;
    }
    return false;
}

fn writeFallbackValue(s: *Serializer, obj: *PyObject) InternalError!bool {
    if (c.PyBool_Check(obj) != 0) {
        s.boolean(try ffi.objectIsTrue(obj)) catch return error.BufferTooSmall;
        return true;
    }
    if (c.PyLong_Check(obj) != 0) {
        try writeInt(s, obj);
        return true;
    }
    if (c.PyFloat_Check(obj) != 0) {
        try writeFloat(s, obj);
        return true;
    }
    if (ffi.isString(obj)) {
        try writeString(s, obj);
        return true;
    }
    if (c.PyList_Check(obj) != 0) {
        const len = c.PyList_Size(obj);
        if (len < 0) return error.ConversionError;
        try writeArrayLike(s, obj, len, &listGetItem);
        return true;
    }
    if (ffi.isDict(obj)) {
        try writeDict(s, obj);
        return true;
    }
    if (ffi.isTuple(obj)) {
        const len = ffi.tupleSize(obj);
        if (len < 0) return error.ConversionError;
        try writeArrayLike(s, obj, len, &tupleGetItem);
        return true;
    }
    return false;
}

fn writeValue(s: *Serializer, obj: *PyObject) InternalError!void {
    if (try writeExactValue(s, obj)) return;
    if (try tryWriteRowLike(s, obj)) return;
    if (try tryWriteModelDump(s, obj)) return;
    if (try writeFallbackValue(s, obj)) return;
    return error.UnsupportedType;
}

pub fn tryWrite(obj: *PyObject, buf: []u8, pos: *usize) WriteError!bool {
    var serializer = Serializer.init(buf);
    serializer.pos = pos.*;
    writeValue(&serializer, obj) catch |err| switch (err) {
        error.UnsupportedType => return false,
        else => return @errorCast(err),
    };
    pos.* = serializer.pos;
    return true;
}
