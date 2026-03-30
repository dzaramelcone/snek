//! SnekRow — zero-copy Python type for PG query results.
//!
//! SnekRow stores field offsets into arena-allocated memory.
//! For `return row`, SIMD JSON serialization bypasses Python entirely.
//! Field access via tp_getattro lazily creates Python strings.
//!
//! Memory: PyObject header + SnekRowData (~144 bytes).
//! Field data lives in the per-request arena on Conn,
//! freed when the HTTP response is sent.

const std = @import("std");
const ffi = @import("ffi.zig");
const serialize = @import("../json/serialize.zig");
const StmtCache = @import("../db/stmt_cache.zig").StmtCache;

const c = ffi.c;
const PyObject = ffi.PyObject;

pub const MAX_FIELDS = 32;
pub const NULL_LEN: u16 = 0xFFFF;

/// How to serialize a PG column value to JSON.
pub const SerializeStrategy = enum(u8) {
    text_escape, // text, varchar — `"value"` with SIMD escape scan
    numeric, // int, float, numeric — raw digits, no quotes
    bool_convert, // bool — 't'→'true', 'f'→'false'
    quoted_raw, // timestamp, uuid, date — `"value"` raw memcpy
    json_raw, // json, jsonb — raw memcpy (already valid JSON)
};

/// Map PG type OID → serialization strategy.
pub fn strategyForOid(oid: u32) SerializeStrategy {
    return switch (oid) {
        16 => .bool_convert,
        20, 21, 23 => .numeric,
        26 => .numeric,
        700, 701 => .numeric,
        1700 => .numeric,
        25, 1042, 1043 => .text_escape,
        18 => .text_escape,
        19 => .text_escape,
        114, 3802 => .json_raw,
        1082, 1083, 1114, 1184 => .quoted_raw,
        1186 => .quoted_raw,
        2950 => .quoted_raw,
        17 => .quoted_raw,
        else => .text_escape,
    };
}

// ── SnekRow data ────────────────────────────────────────────────────

/// Per-instance data sitting after the PyObject header.
/// Field data lives in the per-request arena — SnekRow just points to it.
pub const SnekRowData = struct {
    stmt_cache: ?*StmtCache = null,
    stmt_idx: u16 = 0,
    field_count: u16 = 0,
    data_ptr: [*]const u8 = undefined, // arena-allocated field data
    field_offsets: [MAX_FIELDS]u16 = .{0} ** MAX_FIELDS,
    field_lens: [MAX_FIELDS]u16 = .{NULL_LEN} ** MAX_FIELDS,
};

fn getData(obj: *PyObject) *SnekRowData {
    const base: [*]u8 = @ptrCast(obj);
    return @ptrCast(@alignCast(base + py_object_size));
}

const py_object_size = @sizeOf(c.PyObject);

/// Get field value slice from arena data.
fn fieldSlice(data: *const SnekRowData, i: usize) []const u8 {
    return data.data_ptr[data.field_offsets[i]..][0..data.field_lens[i]];
}

// ── Type slots ──────────────────────────────────────────────────────

fn snekRowDealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const tp = c.Py_TYPE(obj);
    const free_fn = c.PyType_GetSlot(tp, c.Py_tp_free);
    if (free_fn) |f| {
        const free: *const fn (?*anyopaque) callconv(.c) void = @ptrCast(@alignCast(f));
        free(obj);
    }
    ffi.decref(@ptrCast(tp));
}

fn snekRowGetAttr(self_obj: ?*c.PyObject, name_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const obj = self_obj orelse return null;
    const name = name_obj orelse return null;
    const data = getData(obj);
    const cache = data.stmt_cache orelse return c.PyObject_GenericGetAttr(self_obj, name_obj);
    const entry = cache.get(data.stmt_idx);

    for (0..data.field_count) |i| {
        const key = entry.col_keys[i] orelse continue;
        if (c.PyObject_RichCompareBool(name, key, c.Py_EQ) == 1) {
            if (data.field_lens[i] == NULL_LEN) {
                return ffi.getNone();
            }
            const val = fieldSlice(data, i);
            return ffi.unicodeFromSlice(val.ptr, val.len) catch return null;
        }
    }

    return c.PyObject_GenericGetAttr(self_obj, name_obj);
}

fn snekRowRepr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const obj = self_obj orelse return null;
    const data = getData(obj);
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "Row({d} fields)", .{data.field_count}) catch
        return ffi.unicodeFromString("Row(?)") catch return null;
    return ffi.unicodeFromSlice(s.ptr, s.len) catch return null;
}

// ── Type creation ───────────────────────────────────────────────────

var type_slots = [_]c.PyType_Slot{
    .{ .slot = c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&snekRowDealloc)) },
    .{ .slot = c.Py_tp_getattro, .pfunc = @ptrCast(@constCast(&snekRowGetAttr)) },
    .{ .slot = c.Py_tp_repr, .pfunc = @ptrCast(@constCast(&snekRowRepr)) },
    .{ .slot = 0, .pfunc = null },
};

var type_spec = c.PyType_Spec{
    .name = "snek.Row",
    .basicsize = @intCast(py_object_size + @sizeOf(SnekRowData)),
    .itemsize = 0,
    .flags = c.Py_TPFLAGS_DEFAULT,
    .slots = &type_slots,
};

threadlocal var row_type: ?*PyObject = null;

pub fn initType() ffi.PythonError!void {
    if (row_type != null) return;
    row_type = c.PyType_FromSpec(&type_spec) orelse return error.PythonError;
}

pub fn isSnekRow(obj: *PyObject) bool {
    const tp = row_type orelse return false;
    return c.Py_TYPE(obj) == @as(*c.PyTypeObject, @ptrCast(@alignCast(tp)));
}

// ── Construction ────────────────────────────────────────────────────

/// Create a SnekRow. Field data is copied into the arena allocator.
/// Returns null if arena allocation fails (caller falls back to dict).
pub fn create(
    cache: *StmtCache,
    stmt_idx: u16,
    field_count: u16,
    values: []const ?[]const u8,
    allocator: std.mem.Allocator,
) ffi.PythonError!?*PyObject {
    const tp = row_type orelse return error.PythonError;
    const count = @min(field_count, MAX_FIELDS);

    var total: usize = 0;
    for (0..count) |i| {
        if (values[i]) |v| total += v.len;
    }

    const arena_data = allocator.alloc(u8, total) catch return null;

    const tp_obj: *c.PyTypeObject = @ptrCast(@alignCast(tp));
    const obj: *PyObject = c.PyType_GenericAlloc(tp_obj, 0) orelse return error.PythonError;

    const data = getData(obj);
    data.* = .{
        .stmt_cache = cache,
        .stmt_idx = stmt_idx,
        .field_count = @intCast(count),
        .data_ptr = arena_data.ptr,
    };

    var offset: u16 = 0;
    for (0..count) |i| {
        if (values[i]) |v| {
            const len: u16 = @intCast(v.len);
            @memcpy(arena_data[offset..][0..len], v);
            data.field_offsets[i] = offset;
            data.field_lens[i] = len;
            offset += len;
        } else {
            data.field_offsets[i] = 0;
            data.field_lens[i] = NULL_LEN;
        }
    }

    return obj;
}

// ── SIMD JSON serialization ─────────────────────────────────────────

pub const SerializeError = error{BufferTooSmall};

/// Serialize a single SnekRow to JSON.
pub fn serializeOne(obj: *PyObject, buf: []u8) SerializeError!usize {
    const data = getData(obj);
    const cache = data.stmt_cache orelse return error.BufferTooSmall;
    const entry = cache.get(data.stmt_idx);

    var pos: usize = 0;

    for (0..data.field_count) |i| {
        const key_start = entry.json_key_offsets[i];
        const key_end = entry.json_key_offsets[i + 1];
        const key_frag = entry.json_keys[key_start..key_end];
        if (pos + key_frag.len >= buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..key_frag.len], key_frag);
        pos += key_frag.len;

        if (data.field_lens[i] == NULL_LEN) {
            if (pos + 4 >= buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos..][0..4], "null");
            pos += 4;
        } else {
            const val = fieldSlice(data, i);

            switch (entry.col_strategies[i]) {
                .text_escape => {
                    if (pos + 2 >= buf.len) return error.BufferTooSmall;
                    buf[pos] = '"';
                    pos += 1;
                    const written = serialize.writeJsonEscaped(buf[pos..], val) catch
                        return error.BufferTooSmall;
                    pos += written;
                    if (pos >= buf.len) return error.BufferTooSmall;
                    buf[pos] = '"';
                    pos += 1;
                },
                .numeric => {
                    if (pos + val.len >= buf.len) return error.BufferTooSmall;
                    @memcpy(buf[pos..][0..val.len], val);
                    pos += val.len;
                },
                .bool_convert => {
                    if (val.len > 0 and val[0] == 't') {
                        if (pos + 4 >= buf.len) return error.BufferTooSmall;
                        @memcpy(buf[pos..][0..4], "true");
                        pos += 4;
                    } else {
                        if (pos + 5 >= buf.len) return error.BufferTooSmall;
                        @memcpy(buf[pos..][0..5], "false");
                        pos += 5;
                    }
                },
                .quoted_raw => {
                    if (pos + val.len + 2 >= buf.len) return error.BufferTooSmall;
                    buf[pos] = '"';
                    @memcpy(buf[pos + 1 ..][0..val.len], val);
                    buf[pos + 1 + val.len] = '"';
                    pos += val.len + 2;
                },
                .json_raw => {
                    if (pos + val.len >= buf.len) return error.BufferTooSmall;
                    @memcpy(buf[pos..][0..val.len], val);
                    pos += val.len;
                },
            }
        }
    }

    if (pos >= buf.len) return error.BufferTooSmall;
    buf[pos] = '}';
    pos += 1;
    return pos;
}

/// Serialize a Python list of SnekRow objects to a JSON array.
pub fn serializeList(list: *PyObject, buf: []u8) SerializeError!usize {
    const len = c.PyList_Size(list);
    if (len < 0) return error.BufferTooSmall;
    var pos: usize = 0;
    if (pos >= buf.len) return error.BufferTooSmall;
    buf[pos] = '[';
    pos += 1;

    var i: isize = 0;
    while (i < len) : (i += 1) {
        if (i > 0) {
            if (pos >= buf.len) return error.BufferTooSmall;
            buf[pos] = ',';
            pos += 1;
        }
        const item = c.PyList_GetItem(list, i) orelse return error.BufferTooSmall;
        if (isSnekRow(item)) {
            const written = serializeOne(item, buf[pos..]) catch return error.BufferTooSmall;
            pos += written;
        } else {
            return error.BufferTooSmall;
        }
    }

    if (pos >= buf.len) return error.BufferTooSmall;
    buf[pos] = ']';
    pos += 1;
    return pos;
}
