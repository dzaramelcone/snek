const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;
const PyObject = ffi.PyObject;
const json_serialize = @import("../json/serialize.zig");
const snek_row = @import("snek_row.zig");

const ModelKeys = struct {
    row: *PyObject,
    root: *PyObject,
    attached_row: *PyObject,
};

threadlocal var model_keys: ?ModelKeys = null;

fn ensureModelKeys() ffi.PythonError!*const ModelKeys {
    if (model_keys == null) {
        model_keys = .{
            .row = c.PyUnicode_InternFromString("_snek_row") orelse return error.PythonError,
            .root = c.PyUnicode_InternFromString("_snek_root") orelse return error.PythonError,
            .attached_row = c.PyUnicode_InternFromString("_snek_attached_row") orelse return error.PythonError,
        };
    }
    return &model_keys.?;
}

fn instanceDictItem(obj: *PyObject, key: *PyObject) ?*PyObject {
    const dict_ptr = c._PyObject_GetDictPtr(obj) orelse return null;
    const dict = dict_ptr.* orelse return null;
    return ffi.dictGetItem(dict, key);
}

const NestedLayout = struct {
    field_order: *PyObject,
    nested: *PyObject,
    scalar_indexes: *PyObject,

    fn deinit(self: NestedLayout) void {
        ffi.decref(self.field_order);
        ffi.decref(self.nested);
        ffi.decref(self.scalar_indexes);
    }
};

fn getBackingRow(obj: *PyObject) ffi.PythonError!?*PyObject {
    if (snek_row.isSnekRow(obj)) return ffi.increfBorrowed(obj);

    const keys = try ensureModelKeys();
    const root = instanceDictItem(obj, keys.root) orelse obj;
    const root_backing = instanceDictItem(root, keys.attached_row) orelse return null;
    if (!snek_row.isSnekRow(root_backing)) return null;
    const backing = instanceDictItem(obj, keys.row) orelse return null;
    if (!snek_row.isSnekRow(backing)) return null;
    return ffi.increfBorrowed(backing);
}

fn getNestedLayout(obj: *PyObject) ffi.PythonError!?NestedLayout {
    const nested = try ffi.getAttrOptional(obj, "__snek_nested__");
    if (nested == null) return null;
    errdefer ffi.xdecref(nested);
    if (!ffi.isDict(nested.?) or ffi.dictSize(nested.?) == 0) {
        ffi.decref(nested.?);
        return null;
    }

    const field_order = try ffi.getAttrOptional(obj, "__snek_field_order__");
    if (field_order == null) {
        ffi.decref(nested.?);
        return null;
    }
    errdefer ffi.xdecref(field_order);
    if (!ffi.isTuple(field_order.?)) {
        ffi.decref(field_order.?);
        ffi.decref(nested.?);
        return null;
    }

    const scalar_indexes = try ffi.getAttrOptional(obj, "__snek_scalar_indexes__");
    if (scalar_indexes == null) {
        ffi.decref(field_order.?);
        ffi.decref(nested.?);
        return null;
    }
    if (!ffi.isDict(scalar_indexes.?)) {
        ffi.decref(scalar_indexes.?);
        ffi.decref(field_order.?);
        ffi.decref(nested.?);
        return null;
    }

    return .{
        .field_order = field_order.?,
        .nested = nested.?,
        .scalar_indexes = scalar_indexes.?,
    };
}

const WriteError = ffi.PythonError || error{BufferTooSmall};

fn writeJsonObjectKey(name_obj: *PyObject, first: bool, buf: []u8, pos: *usize) (WriteError || snek_row.SerializeError)!void {
    if (!first) {
        if (pos.* >= buf.len) return error.BufferTooSmall;
        buf[pos.*] = ',';
        pos.* += 1;
    }
    if (pos.* >= buf.len) return error.BufferTooSmall;
    buf[pos.*] = '"';
    pos.* += 1;

    const key = try ffi.unicodeAsUTF8(name_obj);
    const span = std.mem.span(key);
    const written = json_serialize.writeJsonEscaped(buf[pos.*..], span) catch
        return error.BufferTooSmall;
    pos.* += written;

    if (pos.* + 2 > buf.len) return error.BufferTooSmall;
    buf[pos.*] = '"';
    buf[pos.* + 1] = ':';
    pos.* += 2;
}

fn serializeNestedModel(row: *PyObject, layout: NestedLayout, buf: []u8) (WriteError || snek_row.SerializeError)!usize {
    var pos: usize = 0;
    if (pos >= buf.len) return error.BufferTooSmall;
    buf[pos] = '{';
    pos += 1;

    const field_count = ffi.tupleSize(layout.field_order);
    var i: isize = 0;
    while (i < field_count) : (i += 1) {
        const field_name = ffi.tupleGetItem(layout.field_order, i) orelse return error.ConversionError;
        try writeJsonObjectKey(field_name, i == 0, buf, &pos);

        if (ffi.dictGetItem(layout.nested, field_name)) |nested_entry| {
            if (!ffi.isTuple(nested_entry) or ffi.tupleSize(nested_entry) != 4) return error.ConversionError;

            const nullable_obj = ffi.tupleGetItem(nested_entry, 1) orelse return error.ConversionError;
            const field_names_obj = ffi.tupleGetItem(nested_entry, 2) orelse return error.ConversionError;
            const indexes_obj = ffi.tupleGetItem(nested_entry, 3) orelse return error.ConversionError;
            const nullable = try ffi.objectIsTrue(nullable_obj);
            const child = try snek_row.createSubrow(row, field_names_obj, indexes_obj, nullable);
            if (child == null) return error.ConversionError;
            defer ffi.decref(child.?);

            if (ffi.isNone(child.?)) {
                if (pos + 4 > buf.len) return error.BufferTooSmall;
                @memcpy(buf[pos..][0..4], "null");
                pos += 4;
            } else {
                const written = try snek_row.serializeOne(child.?, buf[pos..]);
                pos += written;
            }
            continue;
        }

        const scalar_index_obj = ffi.dictGetItem(layout.scalar_indexes, field_name) orelse return error.ConversionError;
        const scalar_index_long = try ffi.longAsLong(scalar_index_obj);
        if (scalar_index_long < 0) return error.ConversionError;
        const written = try snek_row.serializeFieldValue(row, @intCast(scalar_index_long), buf[pos..]);
        pos += written;
    }

    if (pos >= buf.len) return error.BufferTooSmall;
    buf[pos] = '}';
    pos += 1;
    return pos;
}

pub fn tryWrite(obj: *PyObject, buf: []u8, pos: *usize) WriteError!bool {
    const backing = try getBackingRow(obj);
    if (backing == null) return false;
    defer ffi.decref(backing.?);

    const layout = try getNestedLayout(obj);
    if (layout != null) {
        defer layout.?.deinit();

        const written = serializeNestedModel(backing.?, layout.?, buf[pos.*..]) catch |err| switch (err) {
            error.BufferTooSmall => return error.BufferTooSmall,
            else => {
                if (ffi.errOccurred()) ffi.errClear();
                return false;
            },
        };
        pos.* += written;
        return true;
    }

    const written = snek_row.serializeOne(backing.?, buf[pos.*..]) catch return error.BufferTooSmall;
    pos.* += written;
    return true;
}
