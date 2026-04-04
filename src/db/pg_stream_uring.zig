const std = @import("std");
const mem = std.mem;

const uring_recv_queue = @import("../aio/uring_recv_queue.zig");
const UringRecvQueue = uring_recv_queue.Queue;
const ffi = @import("../python/ffi.zig");
const stmt_cache_mod = @import("stmt_cache.zig");
const StmtCache = stmt_cache_mod.StmtCache;
const StmtEntry = stmt_cache_mod.Entry;
const result_lease = @import("result_lease.zig");
const SlabPool = result_lease.SlabPool;
const snek_row = @import("../python/snek_row.zig");
const wire = @import("wire.zig");

pub const ParseError = wire.WireError || ffi.PythonError || snek_row.CreateError || error{
    MessageTooLarge,
    OutOfMemory,
};

pub const MessageView = struct {
    header: wire.MessageHeader,
    payload_off: usize,
    payload_len: usize,
    total_len: usize,
};

const FieldSpan = struct {
    is_null: bool = false,
    logical_off: usize = 0,
    len: usize = 0,
};

pub fn nextMessage(queue: *const UringRecvQueue, logical_off: usize) ParseError!?MessageView {
    if (queue.remainingFrom(logical_off) < 5) return null;

    const header = if (queue.sliceIfContiguous(logical_off, 5)) |header_bytes|
        try wire.readMessageHeader(header_bytes)
    else blk: {
        var header_bytes: [5]u8 = undefined;
        queue.copyInto(logical_off, &header_bytes);
        break :blk try wire.readMessageHeader(&header_bytes);
    };
    const total_len = 1 + @as(usize, @intCast(header.length));
    if (total_len > queue.capacity()) return error.MessageTooLarge;
    if (queue.remainingFrom(logical_off) < total_len) return null;

    return .{
        .header = header,
        .payload_off = logical_off + 5,
        .payload_len = total_len - 5,
        .total_len = total_len,
    };
}

pub fn applyRowDescription(
    allocator: std.mem.Allocator,
    queue: *const UringRecvQueue,
    payload_off: usize,
    payload_len: usize,
    stmt_entry: *StmtEntry,
) ParseError!u16 {
    if (payload_len < 2) return error.ProtocolViolation;

    if (queue.sliceIfContiguous(payload_off, payload_len)) |payload| {
        var col_descs: [stmt_cache_mod.MAX_COLS]wire.ColumnDesc = undefined;
        const field_count = try wire.parseRowDescription(payload, &col_descs);
        if (!stmt_entry.described) {
            stmt_entry.col_count = field_count;
            for (0..field_count) |i| {
                stmt_entry.col_keys[i] = try ffi.unicodeFromSlice(col_descs[i].name.ptr, col_descs[i].name.len);
                stmt_entry.col_strategies[i] = snek_row.strategyForOid(col_descs[i].type_oid);
            }
            stmt_entry.described = true;
            stmt_entry.buildJsonKeys();
        }
        return field_count;
    }

    const field_count = readU16At(queue, payload_off);
    if (field_count > stmt_cache_mod.MAX_COLS) return error.ProtocolViolation;

    var pos = payload_off + 2;
    const payload_end = payload_off + payload_len;

    if (!stmt_entry.described) {
        stmt_entry.col_count = field_count;
    }

    for (0..field_count) |i| {
        const name_start = pos;
        while (pos < payload_end and queue.byteAt(pos) != 0) : (pos += 1) {}
        if (pos >= payload_end) return error.ProtocolViolation;
        const name_len = pos - name_start;
        pos += 1;

        if (pos + 18 > payload_end) return error.ProtocolViolation;

        const type_oid = readU32At(queue, pos + 6);
        if (!stmt_entry.described) {
            stmt_entry.col_keys[i] = try unicodeFromLogicalRange(allocator, queue, name_start, name_len);
            stmt_entry.col_strategies[i] = snek_row.strategyForOid(type_oid);
        }

        pos += 18;
    }

    if (!stmt_entry.described) {
        stmt_entry.described = true;
        stmt_entry.buildJsonKeys();
    }

    return field_count;
}

pub fn materializeDataRow(
    allocator: std.mem.Allocator,
    queue: *const UringRecvQueue,
    payload_off: usize,
    payload_len: usize,
    stmt_cache: *StmtCache,
    stmt_idx: u16,
    stmt_entry: *const StmtEntry,
    col_count: u16,
    pool: *SlabPool,
) ParseError!*ffi.PyObject {
    if (queue.sliceIfContiguous(payload_off, payload_len)) |payload| {
        var values: [stmt_cache_mod.MAX_COLS]?[]const u8 = undefined;
        const field_count = try wire.parseDataRow(payload, &values);
        const render_count = @min(col_count, field_count);

        if (snek_row.create(stmt_cache, stmt_idx, render_count, values[0..render_count], pool) catch null) |row| {
            return row;
        }

        const dict = try ffi.dictNew();
        errdefer ffi.decref(dict);

        for (0..render_count) |i| {
            const name = stmt_entry.col_keys[i] orelse continue;
            if (values[i]) |val| {
                const value_obj = try ffi.unicodeFromSlice(val.ptr, val.len);
                defer ffi.decref(value_obj);
                try ffi.dictSetItem(dict, name, value_obj);
            } else {
                try ffi.dictSetItem(dict, name, ffi.none());
            }
        }

        return dict;
    }

    var spans: [stmt_cache_mod.MAX_COLS]FieldSpan = undefined;
    const field_count = try parseDataRowSpans(queue, payload_off, payload_len, &spans);
    const render_count = @min(col_count, field_count);

    const SpanCopyCtx = struct {
        queue: *const UringRecvQueue,
        spans: []const FieldSpan,
    };

    const spanFieldLen = struct {
        fn f(ctx: SpanCopyCtx, idx: usize) ?usize {
            const span = ctx.spans[idx];
            return if (span.is_null) null else span.len;
        }
    }.f;

    const copySpanField = struct {
        fn f(ctx: SpanCopyCtx, idx: usize, dest: []u8) void {
            ctx.queue.copyInto(ctx.spans[idx].logical_off, dest);
        }
    }.f;

    const row_obj = snek_row.createCopied(
        SpanCopyCtx,
        stmt_cache,
        stmt_idx,
        render_count,
        pool,
        .{ .queue = queue, .spans = spans[0..render_count] },
        spanFieldLen,
        copySpanField,
    ) catch null;
    if (row_obj) |row| return row;

    const dict = try ffi.dictNew();
    errdefer ffi.decref(dict);

    for (0..render_count) |i| {
        const name = stmt_entry.col_keys[i] orelse continue;
        if (spans[i].is_null) {
            try ffi.dictSetItem(dict, name, ffi.none());
            continue;
        }

        const value_obj = try unicodeFromLogicalRange(allocator, queue, spans[i].logical_off, spans[i].len);
        defer ffi.decref(value_obj);
        try ffi.dictSetItem(dict, name, value_obj);
    }

    return dict;
}

pub fn parseCommandCompleteCount(queue: *const UringRecvQueue, payload_off: usize, payload_len: usize) i64 {
    if (queue.sliceIfContiguous(payload_off, payload_len)) |payload| {
        return parseCommandCompleteTagCount(wire.parseCommandComplete(payload));
    }

    var end = payload_len;
    while (end > 0 and queue.byteAt(payload_off + end - 1) == 0) {
        end -= 1;
    }
    if (end == 0) return 0;

    var start = end;
    while (start > 0 and queue.byteAt(payload_off + start - 1) != ' ') {
        start -= 1;
    }
    if (start >= end) return 0;

    var value: i64 = 0;
    for (start..end) |logical_idx| {
        const ch = queue.byteAt(payload_off + logical_idx);
        if (ch < '0' or ch > '9') return 0;
        value = value * 10 + (ch - '0');
    }
    return value;
}

fn parseCommandCompleteTagCount(tag: []const u8) i64 {
    if (tag.len == 0) return 0;
    if (std.mem.lastIndexOfScalar(u8, tag, ' ')) |space| {
        return std.fmt.parseInt(i64, tag[space + 1 ..], 10) catch 0;
    }
    return 0;
}

fn parseDataRowSpans(
    queue: *const UringRecvQueue,
    payload_off: usize,
    payload_len: usize,
    spans_out: []FieldSpan,
) ParseError!u16 {
    if (payload_len < 2) return error.ProtocolViolation;

    const field_count = readU16At(queue, payload_off);
    if (field_count > spans_out.len) return error.ProtocolViolation;

    var pos = payload_off + 2;
    const payload_end = payload_off + payload_len;

    for (0..field_count) |i| {
        if (pos + 4 > payload_end) return error.ProtocolViolation;
        const val_len = readI32At(queue, pos);
        pos += 4;

        if (val_len == -1) {
            spans_out[i] = .{ .is_null = true };
            continue;
        }

        if (val_len < 0) return error.ProtocolViolation;
        const len: usize = @intCast(val_len);
        if (pos + len > payload_end) return error.ProtocolViolation;
        spans_out[i] = .{
            .is_null = false,
            .logical_off = pos,
            .len = len,
        };
        pos += len;
    }

    return field_count;
}

fn unicodeFromLogicalRange(
    allocator: std.mem.Allocator,
    queue: *const UringRecvQueue,
    logical_off: usize,
    len: usize,
) ParseError!*ffi.PyObject {
    if (queue.sliceIfContiguous(logical_off, len)) |slice| {
        return ffi.unicodeFromSlice(slice.ptr, slice.len);
    }

    const bytes = try allocator.alloc(u8, len);
    defer allocator.free(bytes);
    queue.copyInto(logical_off, bytes);
    return ffi.unicodeFromSlice(bytes.ptr, bytes.len);
}

fn readU16At(queue: *const UringRecvQueue, logical_off: usize) u16 {
    var bytes: [2]u8 = undefined;
    queue.copyInto(logical_off, &bytes);
    return mem.bigToNative(u16, mem.bytesToValue(u16, &bytes));
}

fn readU32At(queue: *const UringRecvQueue, logical_off: usize) u32 {
    var bytes: [4]u8 = undefined;
    queue.copyInto(logical_off, &bytes);
    return mem.bigToNative(u32, mem.bytesToValue(u32, &bytes));
}

fn readI32At(queue: *const UringRecvQueue, logical_off: usize) i32 {
    return @bitCast(readU32At(queue, logical_off));
}
