const std = @import("std");
const ffi = @import("ffi.zig");
const PyObject = ffi.PyObject;
const json_serialize = @import("../json/serialize.zig");
const snek_row = @import("snek_row.zig");

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

fn modelIsClean(obj: *PyObject) ffi.PythonError!bool {
    const clean = try ffi.callOptionalNoArgs(obj, "_snek_is_clean");
    if (clean == null) return true;
    defer ffi.decref(clean.?);
    return try ffi.objectIsTrue(clean.?);
}

fn getBackingRow(obj: *PyObject) ffi.PythonError!?*PyObject {
    if (snek_row.isSnekRow(obj)) return ffi.increfBorrowed(obj);

    const backing = try ffi.getAttrOptional(obj, "_snek_row");
    if (backing == null) return null;
    if (!try modelIsClean(obj)) {
        ffi.decref(backing.?);
        return null;
    }
    if (!snek_row.isSnekRow(backing.?)) {
        ffi.decref(backing.?);
        return null;
    }
    return backing.?;
}

fn hasNestedShape(obj: *PyObject) ffi.PythonError!bool {
    const nested = try ffi.getAttrOptional(obj, "__snek_nested__");
    if (nested == null) return false;
    defer ffi.decref(nested.?);
    return ffi.isDict(nested.?) and ffi.dictSize(nested.?) > 0;
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

    if (try hasNestedShape(obj)) {
        const layout = try getNestedLayout(obj);
        if (layout == null) return false;
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
