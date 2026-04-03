//! SnekRow — zero-copy Python type for query results.
//!
//! SnekRow stores field offsets into a retained result lease.
//! For `return row`, SIMD JSON serialization bypasses Python entirely.
//! Field access lazily creates Python objects and caches them.
//! Raw access can export a memoryview without copying.
//!
//! Memory: PyObject header + SnekRowData.
//! Field data lives behind a ResultLease retained by the row object.

const std = @import("std");
const ffi = @import("ffi.zig");
const serialize = @import("../json/serialize.zig");
const StmtCache = @import("../db/stmt_cache.zig").StmtCache;
const result_lease = @import("../db/result_lease.zig");
const SlabPool = result_lease.SlabPool;
const ResultLease = result_lease.ResultLease;

const c = ffi.c;
const PyObject = ffi.PyObject;
const schema_allocator = std.heap.c_allocator;

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

const RowSchema = struct {
    field_count: u16 = 0,
    field_keys: [MAX_FIELDS]?*PyObject = .{null} ** MAX_FIELDS,
    field_strategies: [MAX_FIELDS]SerializeStrategy = .{.text_escape} ** MAX_FIELDS,
    json_keys: [2048]u8 = undefined,
    json_key_offsets: [MAX_FIELDS + 1]u16 = .{0} ** (MAX_FIELDS + 1),

    fn create(field_names: []const *PyObject, field_strategies: []const SerializeStrategy) !*RowSchema {
        const schema = try schema_allocator.create(RowSchema);
        schema.* = .{
            .field_count = @intCast(field_names.len),
        };
        errdefer schema.destroy();

        for (field_names, field_strategies, 0..) |field_name, strategy, i| {
            schema.field_keys[i] = ffi.increfBorrowed(field_name);
            schema.field_strategies[i] = strategy;
        }
        schema.buildJsonKeys();
        return schema;
    }

    fn destroy(self: *RowSchema) void {
        for (0..self.field_count) |i| {
            if (self.field_keys[i]) |key| ffi.decref(key);
        }
        schema_allocator.destroy(self);
    }

    fn lookupFieldIndex(self: *const RowSchema, name: *PyObject) ?usize {
        for (0..self.field_count) |i| {
            const key = self.field_keys[i] orelse continue;
            if (key == name or c.PyObject_RichCompareBool(name, key, c.Py_EQ) == 1) {
                return i;
            }
        }
        return null;
    }

    fn buildJsonKeys(self: *RowSchema) void {
        var pos: u16 = 0;
        for (0..self.field_count) |i| {
            self.json_key_offsets[i] = pos;
            const key = self.field_keys[i] orelse continue;
            const key_str = ffi.unicodeAsUTF8(key) catch continue;
            const key_span = std.mem.span(key_str);

            const prefix: u8 = if (i == 0) '{' else ',';
            if (pos + 1 + 1 + key_span.len + 2 > self.json_keys.len) break;
            self.json_keys[pos] = prefix;
            self.json_keys[pos + 1] = '"';
            @memcpy(self.json_keys[pos + 2 ..][0..key_span.len], key_span);
            self.json_keys[pos + 2 + key_span.len] = '"';
            self.json_keys[pos + 2 + key_span.len + 1] = ':';
            pos += @intCast(2 + key_span.len + 2);
        }
        self.json_key_offsets[self.field_count] = pos;
    }
};

// ── SnekRow data ────────────────────────────────────────────────────

/// Per-instance data sitting after the PyObject header.
/// Field data lives behind a retained result lease.
pub const SnekRowData = struct {
    stmt_cache: ?*StmtCache = null,
    stmt_idx: u16 = 0,
    field_count: u16 = 0,
    lease: ResultLease = .{},
    schema: ?*RowSchema = null,
    field_offsets: [MAX_FIELDS]u16 = .{0} ** MAX_FIELDS,
    field_lens: [MAX_FIELDS]u16 = .{NULL_LEN} ** MAX_FIELDS,
    field_cache: [MAX_FIELDS]?*PyObject = .{null} ** MAX_FIELDS,
};

fn getData(obj: *PyObject) *SnekRowData {
    const base: [*]u8 = @ptrCast(obj);
    return @ptrCast(@alignCast(base + py_object_size));
}

const py_object_size = @sizeOf(c.PyObject);

/// Get field value slice from the retained lease backing.
fn fieldSlice(data: *const SnekRowData, i: usize) []const u8 {
    const bytes = data.lease.constBytes();
    return bytes[data.field_offsets[i]..][0..data.field_lens[i]];
}

fn lookupFieldIndex(data: *const SnekRowData, name: *PyObject) ?usize {
    if (data.schema) |schema| return schema.lookupFieldIndex(name);

    const cache = data.stmt_cache orelse return null;
    const entry = cache.get(data.stmt_idx);

    for (0..data.field_count) |i| {
        const key = entry.col_keys[i] orelse continue;
        if (key == name or c.PyObject_RichCompareBool(name, key, c.Py_EQ) == 1) {
            return i;
        }
    }

    return null;
}

fn fieldStrategy(data: *const SnekRowData, i: usize) SerializeStrategy {
    if (data.schema) |schema| return schema.field_strategies[i];
    const cache = data.stmt_cache orelse return .text_escape;
    return cache.get(data.stmt_idx).col_strategies[i];
}

fn jsonKeyFragment(data: *const SnekRowData, i: usize) []const u8 {
    if (data.schema) |schema| {
        const key_start = schema.json_key_offsets[i];
        const key_end = schema.json_key_offsets[i + 1];
        return schema.json_keys[key_start..key_end];
    }

    const cache = data.stmt_cache orelse return &.{};
    const entry = cache.get(data.stmt_idx);
    const key_start = entry.json_key_offsets[i];
    const key_end = entry.json_key_offsets[i + 1];
    return entry.json_keys[key_start..key_end];
}

fn writeFieldValue(data: *const SnekRowData, i: usize, buf: []u8, pos: *usize) SerializeError!void {
    if (data.field_lens[i] == NULL_LEN) {
        if (pos.* + 4 >= buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos.*..][0..4], "null");
        pos.* += 4;
        return;
    }

    const val = fieldSlice(data, i);
    switch (fieldStrategy(data, i)) {
        .text_escape => {
            if (pos.* + 2 >= buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            pos.* += 1;
            const written = serialize.writeJsonEscaped(buf[pos.*..], val) catch
                return error.BufferTooSmall;
            pos.* += written;
            if (pos.* >= buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            pos.* += 1;
        },
        .numeric => {
            if (pos.* + val.len >= buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos.*..][0..val.len], val);
            pos.* += val.len;
        },
        .bool_convert => {
            if (val.len > 0 and val[0] == 't') {
                if (pos.* + 4 >= buf.len) return error.BufferTooSmall;
                @memcpy(buf[pos.*..][0..4], "true");
                pos.* += 4;
            } else {
                if (pos.* + 5 >= buf.len) return error.BufferTooSmall;
                @memcpy(buf[pos.*..][0..5], "false");
                pos.* += 5;
            }
        },
        .quoted_raw => {
            if (pos.* + val.len + 2 >= buf.len) return error.BufferTooSmall;
            buf[pos.*] = '"';
            @memcpy(buf[pos.* + 1 ..][0..val.len], val);
            buf[pos.* + 1 + val.len] = '"';
            pos.* += val.len + 2;
        },
        .json_raw => {
            if (pos.* + val.len >= buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos.*..][0..val.len], val);
            pos.* += val.len;
        },
    }
}

fn cachedFieldValue(data: *SnekRowData, i: usize) ffi.PythonError!*PyObject {
    if (data.field_cache[i]) |cached| {
        ffi.incref(cached);
        return cached;
    }

    const value = if (data.field_lens[i] == NULL_LEN)
        ffi.getNone()
    else blk: {
        const val = fieldSlice(data, i);
        break :blk try ffi.unicodeFromSlice(val.ptr, val.len);
    };
    data.field_cache[i] = value;
    ffi.incref(value);
    return value;
}

fn fieldMemoryView(self_obj: *PyObject, data: *const SnekRowData, i: usize) ?*PyObject {
    if (data.field_lens[i] == NULL_LEN) return ffi.getNone();

    const val = fieldSlice(data, i);
    var view = std.mem.zeroes(c.Py_buffer);
    view.buf = @ptrCast(@constCast(val.ptr));
    view.obj = self_obj;
    view.len = @intCast(val.len);
    view.itemsize = 1;
    view.readonly = 1;
    view.ndim = 1;
    return c.PyMemoryView_FromBuffer(&view);
}

// ── Type slots ──────────────────────────────────────────────────────

fn snekRowDealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const data = getData(obj);
    for (data.field_cache) |cached| {
        if (cached) |value| ffi.decref(value);
    }
    if (data.schema) |schema| schema.destroy();
    data.lease.release();
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
    if (lookupFieldIndex(data, name)) |i| {
        return cachedFieldValue(data, i) catch return null;
    }

    return c.PyObject_GenericGetAttr(self_obj, name_obj);
}

fn snekRowRaw(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const obj = self_obj orelse return null;
    const tuple = args orelse return null;
    if (!ffi.isTuple(tuple) or ffi.tupleSize(tuple) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "raw(name) takes exactly one field name");
        return null;
    }

    const name = ffi.tupleGetItem(tuple, 0) orelse return null;
    if (!ffi.isString(name)) {
        c.PyErr_SetString(c.PyExc_TypeError, "raw(name) requires a string field name");
        return null;
    }

    const data = getData(obj);
    const index = lookupFieldIndex(data, name) orelse {
        c.PyErr_SetString(c.PyExc_AttributeError, "unknown field");
        return null;
    };
    return fieldMemoryView(obj, data, index);
}

pub fn createSubrow(
    obj: *PyObject,
    field_names_obj: *PyObject,
    indexes_obj: *PyObject,
    nullable: bool,
) ffi.PythonError!?*PyObject {
    if (!ffi.isTuple(field_names_obj) or !ffi.isTuple(indexes_obj)) {
        ffi.errSetString(c.PyExc_TypeError, "subrow metadata requires tuples for field names and indexes");
        return error.TypeError;
    }

    const field_count = ffi.tupleSize(field_names_obj);
    if (field_count != ffi.tupleSize(indexes_obj) or field_count < 0 or field_count > MAX_FIELDS) {
        ffi.errSetString(c.PyExc_ValueError, "subrow metadata requires matching field names and index counts");
        return error.ConversionError;
    }

    const data = getData(obj);
    if (data.lease.isEmpty()) {
        ffi.errSetString(c.PyExc_RuntimeError, "row backing lease is missing");
        return error.PythonError;
    }

    var field_names: [MAX_FIELDS]*PyObject = undefined;
    var field_strategies: [MAX_FIELDS]SerializeStrategy = undefined;
    var selected_indexes: [MAX_FIELDS]usize = undefined;
    var all_null = field_count > 0;
    for (0..@intCast(field_count)) |i| {
        const field_name = ffi.tupleGetItem(field_names_obj, @intCast(i)) orelse {
            ffi.errSetString(c.PyExc_RuntimeError, "subrow metadata field name lookup failed");
            return error.PythonError;
        };
        const index_obj = ffi.tupleGetItem(indexes_obj, @intCast(i)) orelse {
            ffi.errSetString(c.PyExc_RuntimeError, "subrow metadata index lookup failed");
            return error.PythonError;
        };
        if (!ffi.isString(field_name)) {
            ffi.errSetString(c.PyExc_TypeError, "subrow metadata field names must be strings");
            return error.TypeError;
        }

        const field_index_long = ffi.longAsLong(index_obj) catch {
            ffi.errSetString(c.PyExc_TypeError, "subrow metadata indexes must be integers");
            return error.TypeError;
        };
        if (field_index_long < 0 or field_index_long >= data.field_count) {
            ffi.errSetString(c.PyExc_IndexError, "subrow metadata index out of range");
            return error.ConversionError;
        }

        const parent_index: usize = @intCast(field_index_long);
        field_names[i] = field_name;
        selected_indexes[i] = parent_index;
        field_strategies[i] = fieldStrategy(data, parent_index);
        if (data.field_lens[parent_index] != NULL_LEN) all_null = false;
    }

    if (nullable and all_null) {
        return ffi.getNone();
    }

    const schema = RowSchema.create(field_names[0..@intCast(field_count)], field_strategies[0..@intCast(field_count)]) catch
        return error.PythonError;
    errdefer schema.destroy();

    const tp = row_type orelse {
        ffi.errSetString(c.PyExc_RuntimeError, "snek.Row type is not initialized");
        return error.PythonError;
    };
    const tp_obj: *c.PyTypeObject = @ptrCast(@alignCast(tp));
    const child: *PyObject = c.PyType_GenericAlloc(tp_obj, 0) orelse {
        schema.destroy();
        return error.PythonError;
    };
    errdefer ffi.decref(child);

    const child_data = getData(child);
    child_data.* = .{
        .field_count = @intCast(field_count),
        .lease = data.lease.retain(),
        .schema = schema,
    };

    for (0..@intCast(field_count)) |i| {
        const parent_index = selected_indexes[i];
        child_data.field_offsets[i] = data.field_offsets[parent_index];
        child_data.field_lens[i] = data.field_lens[parent_index];
    }

    return child;
}

fn snekRowSubrow(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const obj = self_obj orelse return null;
    const tuple = args orelse return null;
    const argc = ffi.tupleSize(tuple);
    if (!ffi.isTuple(tuple) or (argc != 2 and argc != 3)) {
        ffi.errSetString(c.PyExc_TypeError, "subrow(field_names, indexes, nullable=False)");
        return null;
    }

    const field_names_obj = ffi.tupleGetItem(tuple, 0) orelse return null;
    const indexes_obj = ffi.tupleGetItem(tuple, 1) orelse return null;
    const nullable = if (argc == 3) blk: {
        const flag_obj = ffi.tupleGetItem(tuple, 2) orelse return null;
        break :blk ffi.objectIsTrue(flag_obj) catch return null;
    } else false;

    return createSubrow(obj, field_names_obj, indexes_obj, nullable) catch return null;
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

var row_methods = [_]c.PyMethodDef{
    ffi.wrapVarArgs("raw", &snekRowRaw),
    ffi.wrapVarArgs("subrow", &snekRowSubrow),
    std.mem.zeroes(c.PyMethodDef),
};

var type_slots = [_]c.PyType_Slot{
    .{ .slot = c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&snekRowDealloc)) },
    .{ .slot = c.Py_tp_getattro, .pfunc = @ptrCast(@constCast(&snekRowGetAttr)) },
    .{ .slot = c.Py_tp_repr, .pfunc = @ptrCast(@constCast(&snekRowRepr)) },
    .{ .slot = c.Py_tp_methods, .pfunc = &row_methods },
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

pub fn resetTypeForTesting() void {
    row_type = null;
}

pub fn isSnekRow(obj: *PyObject) bool {
    const tp = row_type orelse return false;
    return c.Py_TYPE(obj) == @as(*c.PyTypeObject, @ptrCast(@alignCast(tp)));
}

fn createWithLease(
    cache: ?*StmtCache,
    stmt_idx: u16,
    field_count: u16,
    values: []const ?[]const u8,
    lease: ResultLease,
) ffi.PythonError!*PyObject {
    var owned_lease = lease;
    errdefer owned_lease.release();

    const tp = row_type orelse return error.PythonError;
    const count = @min(field_count, MAX_FIELDS);
    const lease_base = @intFromPtr(owned_lease.constBytes().ptr);

    const tp_obj: *c.PyTypeObject = @ptrCast(@alignCast(tp));
    const obj: *PyObject = c.PyType_GenericAlloc(tp_obj, 0) orelse return error.PythonError;

    const data = getData(obj);
    data.* = .{
        .stmt_cache = cache,
        .stmt_idx = stmt_idx,
        .field_count = @intCast(count),
        .lease = owned_lease,
    };

    for (0..count) |i| {
        if (values[i]) |v| {
            const offset = @intFromPtr(v.ptr) - lease_base;
            std.debug.assert(offset + v.len <= data.lease.constBytes().len);
            data.field_offsets[i] = @intCast(offset);
            data.field_lens[i] = @intCast(v.len);
        } else {
            data.field_offsets[i] = 0;
            data.field_lens[i] = NULL_LEN;
        }
    }

    return obj;
}

// ── Construction ────────────────────────────────────────────────────

pub fn createCopied(
    comptime CopyCtx: type,
    cache: *StmtCache,
    stmt_idx: u16,
    field_count: u16,
    pool: *SlabPool,
    ctx: CopyCtx,
    comptime fieldLenFn: fn (CopyCtx, usize) ?usize,
    comptime copyFieldFn: fn (CopyCtx, usize, []u8) void,
) CreateError!*PyObject {
    const count = @min(field_count, MAX_FIELDS);

    var total: usize = 0;
    for (0..count) |i| {
        if (fieldLenFn(ctx, i)) |len| {
            if (len > std.math.maxInt(u16)) return error.RowTooLarge;
            total += len;
            if (total > result_lease.CAPACITY) return error.RowTooLarge;
        }
    }

    var lease = try ResultLease.initOwned(pool);
    errdefer lease.release();

    var copied_values: [MAX_FIELDS]?[]const u8 = .{null} ** MAX_FIELDS;
    var offset: usize = 0;
    for (0..count) |i| {
        if (fieldLenFn(ctx, i)) |len| {
            const dest = lease.bytes()[offset..][0..len];
            copyFieldFn(ctx, i, dest);
            copied_values[i] = lease.constBytes()[offset..][0..len];
            offset += len;
        }
    }

    return createWithLease(cache, stmt_idx, count, copied_values[0..count], lease);
}

/// Create a SnekRow by copying field data into a dedicated slab.
pub const CreateError = ffi.PythonError || error{
    OutOfMemory,
    SlabPoolClosed,
    SlabPoolExhausted,
    RowTooLarge,
};

pub fn create(
    cache: *StmtCache,
    stmt_idx: u16,
    field_count: u16,
    values: []const ?[]const u8,
    pool: *SlabPool,
) CreateError!*PyObject {
    const SliceCopyCtx = struct {
        values: []const ?[]const u8,
    };

    const sliceFieldLen = struct {
        fn f(ctx: SliceCopyCtx, idx: usize) ?usize {
            return if (ctx.values[idx]) |v| v.len else null;
        }
    }.f;

    const copySliceField = struct {
        fn f(ctx: SliceCopyCtx, idx: usize, dest: []u8) void {
            @memcpy(dest, ctx.values[idx].?);
        }
    }.f;

    return createCopied(SliceCopyCtx, cache, stmt_idx, field_count, pool, .{ .values = values }, sliceFieldLen, copySliceField);
}

// ── SIMD JSON serialization ─────────────────────────────────────────

pub const SerializeError = error{BufferTooSmall};

pub fn serializeFieldValue(obj: *PyObject, field_index: usize, buf: []u8) SerializeError!usize {
    const data = getData(obj);
    if (field_index >= data.field_count) return error.BufferTooSmall;

    var pos: usize = 0;
    try writeFieldValue(data, field_index, buf, &pos);
    return pos;
}

/// Serialize a single SnekRow to JSON.
pub fn serializeOne(obj: *PyObject, buf: []u8) SerializeError!usize {
    const data = getData(obj);
    if (data.schema == null and data.stmt_cache == null) return error.BufferTooSmall;

    var pos: usize = 0;

    for (0..data.field_count) |i| {
        const key_frag = jsonKeyFragment(data, i);
        if (pos + key_frag.len >= buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..key_frag.len], key_frag);
        pos += key_frag.len;
        try writeFieldValue(data, i, buf, &pos);
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
