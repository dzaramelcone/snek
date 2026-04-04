const std = @import("std");
const ffi = @import("../ffi.zig");
const objects_mod = @import("objects.zig");
const runtime_mod = @import("runtime.zig");

const PyObject = ffi.PyObject;
const TypeState = objects_mod.TypeState;
const FutureObject = objects_mod.FutureObject;
const SubmittedYield = objects_mod.SubmittedYield;

const MAX_REDIS_ARGS = 7;

pub const RedisFutureObject = struct {
    future: FutureObject,
    cmd: []const u8 = "",
    arg_count: u8 = 0,
    args: [MAX_REDIS_ARGS]?*PyObject = [_]?*PyObject{null} ** MAX_REDIS_ARGS,
};

pub fn clearRedisExtra(base: *FutureObject) void {
    const self: *RedisFutureObject = @fieldParentPtr("future", base);
    var i: usize = 0;
    while (i < self.arg_count) : (i += 1) {
        runtime_mod.clearOptional(&self.args[i]);
    }
    self.arg_count = 0;
}

pub fn traverseRedisExtra(base: *FutureObject, visit: objects_mod.c.visitproc, arg: ?*anyopaque) c_int {
    const self: *RedisFutureObject = @fieldParentPtr("future", base);
    var i: usize = 0;
    while (i < self.arg_count) : (i += 1) {
        if (self.args[i]) |owned| {
            const rc = visit.?(@ptrCast(@constCast(owned)), arg);
            if (rc != 0) return rc;
        }
    }
    return 0;
}

fn writeResp(buf: []u8, args: []const []const u8) usize {
    var pos: usize = 0;
    if (pos >= buf.len) return 0;
    buf[pos] = '*';
    pos += 1;

    const count = std.fmt.bufPrint(buf[pos..], "{d}\r\n", .{args.len}) catch return 0;
    pos += count.len;

    for (args) |arg| {
        if (pos >= buf.len) return 0;
        buf[pos] = '$';
        pos += 1;
        const len_text = std.fmt.bufPrint(buf[pos..], "{d}\r\n", .{arg.len}) catch return 0;
        pos += len_text.len;
        if (pos + arg.len + 2 > buf.len) return 0;
        @memcpy(buf[pos .. pos + arg.len], arg);
        pos += arg.len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
    }
    return pos;
}

fn writeRedisCommand(buf: []u8, cmd: []const u8, args: []const ?*PyObject) !usize {
    if (args.len + 1 > 8) return error.TypeError;

    var parts: [8][]const u8 = undefined;
    parts[0] = cmd;
    var count: usize = 1;
    for (args) |arg_opt| {
        const arg = arg_opt orelse return error.InvalidState;
        if (!ffi.isString(arg)) return error.TypeError;
        const text = try ffi.unicodeAsUTF8(arg);
        parts[count] = std.mem.span(text);
        count += 1;
    }

    const written = writeResp(buf, parts[0..count]);
    if (written == 0) return error.RespBufferOverflow;
    return written;
}

fn submitRedis(
    base: *FutureObject,
    py_coro: *PyObject,
    py_future: *PyObject,
    redis_buf: ?[]u8,
    _: ?[]u8,
    _: ?*objects_mod.StmtCache,
    _: ?*[objects_mod.MAX_PG_STMTS]bool,
) !SubmittedYield {
    const buf = redis_buf orelse return error.NoRedisBuffer;
    const self: *RedisFutureObject = @fieldParentPtr("future", base);
    const written = try writeRedisCommand(buf, self.cmd, self.args[0..self.arg_count]);
    return .{ .redis = .{ .py_coro = py_coro, .py_future = ffi.increfBorrowed(py_future), .bytes_written = written } };
}

pub fn createRedisFuture(comptime cmd: []const u8, type_state: *TypeState, args: []const *PyObject) ffi.PythonError!*PyObject {
    const type_obj = type_state.redis_future_type orelse return error.PythonError;
    if (args.len > MAX_REDIS_ARGS) return error.TypeError;
    const self = try runtime_mod.allocFutureLike(RedisFutureObject, type_obj, type_state);
    self.future.type_state = type_state;
    self.future.traverse_extra_fn = traverseRedisExtra;
    self.future.clear_extra_fn = clearRedisExtra;
    self.future.submit_fn = &submitRedis;
    self.cmd = cmd;
    self.arg_count = @intCast(args.len);
    for (args, 0..) |arg, i| {
        self.args[i] = ffi.increfBorrowed(arg);
    }
    return @ptrCast(&self.future);
}
