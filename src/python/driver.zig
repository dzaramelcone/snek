//! Python handler driver: bridge between Zig HTTP and Python handlers.
//!
//! Builds request dicts, invokes handlers, drives coroutines, converts responses.
//! GIL management is the caller's responsibility (each sub-interpreter owns its GIL).

const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;
const PyObject = ffi.PyObject;
const gil = @import("gil.zig");
const module = @import("module.zig");
const response_mod = @import("../http/response.zig");
const http1 = @import("../net/http1.zig");
const router_mod = @import("../http/router.zig");
const stmt_cache_mod = @import("../db/stmt_cache.zig");
const StmtCache = stmt_cache_mod.StmtCache;
const MAX_PG_STMTS = stmt_cache_mod.MAX_STMTS;

// ── Cached Python strings ────────────────────────────────────────────
// Pre-created PyObject strings for dict keys and HTTP method values.
// Created once per sub-interpreter (thread-local), reused for every request.
// Eliminates repeated PyUnicode_FromString calls in the hot path.

pub const StringCache = struct {
    // Dict keys — used as PyDict_SetItem keys
    key_method: *PyObject,
    key_path: *PyObject,
    key_headers: *PyObject,
    key_body: *PyObject,
    key_params: *PyObject,
    // HTTP method values
    val_GET: *PyObject,
    val_POST: *PyObject,
    val_PUT: *PyObject,
    val_DELETE: *PyObject,
    val_PATCH: *PyObject,
    val_HEAD: *PyObject,
    val_OPTIONS: *PyObject,
    val_CONNECT: *PyObject,
    val_TRACE: *PyObject,

    pub fn init() ffi.PythonError!StringCache {
        return .{
            .key_method = try ffi.unicodeFromString("method"),
            .key_path = try ffi.unicodeFromString("path"),
            .key_headers = try ffi.unicodeFromString("headers"),
            .key_body = try ffi.unicodeFromString("body"),
            .key_params = try ffi.unicodeFromString("params"),
            .val_GET = try ffi.unicodeFromString("GET"),
            .val_POST = try ffi.unicodeFromString("POST"),
            .val_PUT = try ffi.unicodeFromString("PUT"),
            .val_DELETE = try ffi.unicodeFromString("DELETE"),
            .val_PATCH = try ffi.unicodeFromString("PATCH"),
            .val_HEAD = try ffi.unicodeFromString("HEAD"),
            .val_OPTIONS = try ffi.unicodeFromString("OPTIONS"),
            .val_CONNECT = try ffi.unicodeFromString("CONNECT"),
            .val_TRACE = try ffi.unicodeFromString("TRACE"),
        };
    }

    pub fn methodObj(self: *const StringCache, method: ?http1.Method) *PyObject {
        return if (method) |m| switch (m) {
            .GET => self.val_GET,
            .POST => self.val_POST,
            .PUT => self.val_PUT,
            .DELETE => self.val_DELETE,
            .PATCH => self.val_PATCH,
            .HEAD => self.val_HEAD,
            .OPTIONS => self.val_OPTIONS,
            .CONNECT => self.val_CONNECT,
            .TRACE => self.val_TRACE,
        } else self.val_GET;
    }
};

threadlocal var tl_string_cache: ?StringCache = null;

/// Initialize the per-thread string cache. Must be called with GIL held.
pub fn initStringCache() !void {
    tl_string_cache = try StringCache.init();
}

// ── Request dict builder ────────────────────────────────────────────

/// Build a Python dict representing the HTTP request.
///
/// Returns a new dict: {"method": "GET", "path": "/", "headers": {...}, "body": "..."}
/// Caller must decref the returned dict.
/// Uses thread-local StringCache for dict keys and method values.
pub fn buildRequestDict(req: *const http1.Request, params: []const router_mod.PathParam) ffi.PythonError!*PyObject {
    const dict = try ffi.dictNew();

    // Use cached strings if available, fall back to per-request allocation
    if (tl_string_cache) |*sc| {
        // Method — cached PyObject, no allocation
        try ffi.dictSetItem(dict, sc.key_method, sc.methodObj(req.method));

        // Path — recv buffer → Python heap, one copy, no intermediate buffer
        const path = req.uri orelse "/";
        const path_obj = try ffi.unicodeFromSlice(path.ptr, path.len);
        defer ffi.decref(path_obj);
        try ffi.dictSetItem(dict, sc.key_path, path_obj);

        // Headers — each name/value goes straight from recv buffer to Python heap
        const headers_dict = try ffi.dictNew();
        defer ffi.decref(headers_dict);
        for (req.headers[0..req.header_count]) |h| {
            const name_obj = try ffi.unicodeFromSlice(h.name.ptr, h.name.len);
            defer ffi.decref(name_obj);
            const val_obj = try ffi.unicodeFromSlice(h.value.ptr, h.value.len);
            defer ffi.decref(val_obj);
            try ffi.dictSetItem(headers_dict, name_obj, val_obj);
        }
        try ffi.dictSetItem(dict, sc.key_headers, headers_dict);

        // Body — straight from recv buffer if present
        if (req.body) |body_slice| {
            const body_obj = try ffi.unicodeFromSlice(body_slice.ptr, body_slice.len);
            defer ffi.decref(body_obj);
            try ffi.dictSetItem(dict, sc.key_body, body_obj);
        } else {
            try ffi.dictSetItem(dict, sc.key_body, ffi.none());
        }

        // Params
        if (params.len > 0) {
            const params_dict = try buildParamsKwargs(params);
            defer ffi.decref(params_dict);
            try ffi.dictSetItem(dict, sc.key_params, params_dict);
        }

        return dict;
    }

    // Fallback: no cache (e.g. main interpreter, tests)
    return buildRequestDictUncached(dict, req, params);
}

/// Fallback dict builder without string cache.
fn buildRequestDictUncached(dict: *PyObject, req: *const http1.Request, params: []const router_mod.PathParam) ffi.PythonError!*PyObject {
    const method_str: [*:0]const u8 = if (req.method) |m| switch (m) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .HEAD => "HEAD",
        .OPTIONS => "OPTIONS",
        .CONNECT => "CONNECT",
        .TRACE => "TRACE",
    } else "GET";
    const method_obj = try ffi.unicodeFromString(method_str);
    defer ffi.decref(method_obj);
    try ffi.dictSetItemString(dict, "method", method_obj);

    const path = req.uri orelse "/";
    const path_obj = try ffi.unicodeFromSlice(path.ptr, path.len);
    defer ffi.decref(path_obj);
    try ffi.dictSetItemString(dict, "path", path_obj);

    const headers_dict = try ffi.dictNew();
    defer ffi.decref(headers_dict);
    for (req.headers[0..req.header_count]) |h| {
        const name_obj = try ffi.unicodeFromSlice(h.name.ptr, h.name.len);
        defer ffi.decref(name_obj);
        const val_obj = try ffi.unicodeFromSlice(h.value.ptr, h.value.len);
        defer ffi.decref(val_obj);
        try ffi.dictSetItem(headers_dict, name_obj, val_obj);
    }
    try ffi.dictSetItemString(dict, "headers", headers_dict);

    if (req.body) |body_slice| {
        const body_obj = try ffi.unicodeFromSlice(body_slice.ptr, body_slice.len);
        defer ffi.decref(body_obj);
        try ffi.dictSetItemString(dict, "body", body_obj);
    } else {
        try ffi.dictSetItemString(dict, "body", ffi.none());
    }

    if (params.len > 0) {
        const params_dict = try buildParamsKwargs(params);
        defer ffi.decref(params_dict);
        try ffi.dictSetItemString(dict, "params", params_dict);
    }

    return dict;
}

/// Build a kwargs dict from path params for direct injection.
/// Caller must decref the returned dict.
pub fn buildParamsKwargs(params: []const router_mod.PathParam) ffi.PythonError!*PyObject {
    const kwargs = try ffi.dictNew();
    for (params) |p| {
        const name_obj = try ffi.unicodeFromSlice(p.name.ptr, p.name.len);
        defer ffi.decref(name_obj);
        const val_obj = try ffi.unicodeFromSlice(p.value.ptr, p.value.len);
        defer ffi.decref(val_obj);
        try ffi.dictSetItem(kwargs, name_obj, val_obj);
    }
    return kwargs;
}

// ── Response conversion ─────────────────────────────────────────────

/// Convert a Python return value to an HTTP response.
///
/// Supported return types:
///   - dict → serialize to JSON, 200 OK, application/json
///   - str  → send as text/plain, 200 OK
///   - tuple (status_code, body) → send with that status
///   - None → 204 No Content
pub fn convertPythonResponse(py_result: *PyObject, resp_body_buf: []u8) ffi.PythonError!response_mod.Response {
    // None → 204
    if (c.Py_IsNone(py_result) != 0) {
        return response_mod.Response.init(204);
    }

    // Tuple → (status, body)
    if (ffi.isTuple(py_result)) {
        const size = ffi.tupleSize(py_result);
        if (size >= 2) {
            const status_obj = ffi.tupleGetItem(py_result, 0) orelse return error.ConversionError;
            const body_obj = ffi.tupleGetItem(py_result, 1) orelse return error.ConversionError;

            const status_long = try ffi.longAsLong(status_obj);
            if (status_long < 100 or status_long > 599) return error.ConversionError;
            const status: u16 = @intCast(status_long);

            // Convert body to string
            const body_str = try pyObjToString(body_obj, resp_body_buf);
            var resp = response_mod.Response.init(status);
            _ = resp.setContentType("text/plain");
            _ = resp.setBody(body_str);
            return resp;
        }
    }

    // Dict → JSON response
    if (ffi.isDict(py_result)) {
        const json_str = try pyDictToJson(py_result, resp_body_buf);
        return response_mod.Response.json(json_str);
    }

    // String → text/plain
    if (ffi.isString(py_result)) {
        const text = try pyObjToString(py_result, resp_body_buf);
        return response_mod.Response.text(text);
    }

    // Fallback: str() the object
    const str_result = try ffi.objectStr(py_result);
    defer ffi.decref(str_result);
    const text = try pyObjToString(str_result, resp_body_buf);
    return response_mod.Response.text(text);
}

/// Convert a Python str object to a Zig slice, copying into the provided buffer.
fn pyObjToString(obj: *PyObject, buf: []u8) ffi.PythonError![]const u8 {
    if (ffi.isString(obj)) {
        const s = try ffi.unicodeAsUTF8(obj);
        const span = std.mem.span(s);
        if (span.len > buf.len) return error.ConversionError;
        @memcpy(buf[0..span.len], span);
        return buf[0..span.len];
    }
    // Not a string — try str()
    const str_obj = try ffi.objectStr(obj);
    defer ffi.decref(str_obj);
    const s = try ffi.unicodeAsUTF8(str_obj);
    const span = std.mem.span(s);
    if (span.len > buf.len) return error.ConversionError;
    @memcpy(buf[0..span.len], span);
    return buf[0..span.len];
}

/// Minimal JSON serialization for Python dicts.
/// Handles nested dicts, lists, strings, ints, floats, bools, None.
fn pyDictToJson(dict: *PyObject, buf: []u8) ffi.PythonError![]const u8 {
    var pos: usize = 0;
    try writeJsonValue(dict, buf, &pos);
    return buf[0..pos];
}

fn writeJsonValue(obj: *PyObject, buf: []u8, pos: *usize) ffi.PythonError!void {
    // None
    if (c.Py_IsNone(obj) != 0) {
        const s = "null";
        if (pos.* + s.len > buf.len) return error.ConversionError;
        @memcpy(buf[pos.*..][0..s.len], s);
        pos.* += s.len;
        return;
    }

    // Bool (must check before int — bool is subclass of int in Python)
    if (c.PyBool_Check(obj) != 0) {
        const val = c.PyObject_IsTrue(obj);
        const s: []const u8 = if (val != 0) "true" else "false";
        if (pos.* + s.len > buf.len) return error.ConversionError;
        @memcpy(buf[pos.*..][0..s.len], s);
        pos.* += s.len;
        return;
    }

    // Int
    if (c.PyLong_Check(obj) != 0) {
        const val = try ffi.longAsLong(obj);
        var int_buf: [32]u8 = undefined;
        const int_slice = std.fmt.bufPrint(&int_buf, "{d}", .{val}) catch return error.ConversionError;
        if (pos.* + int_slice.len > buf.len) return error.ConversionError;
        @memcpy(buf[pos.*..][0..int_slice.len], int_slice);
        pos.* += int_slice.len;
        return;
    }

    // Float
    if (c.PyFloat_Check(obj) != 0) {
        const val = try ffi.floatAsDouble(obj);
        var float_buf: [64]u8 = undefined;
        const float_slice = std.fmt.bufPrint(&float_buf, "{d}", .{val}) catch return error.ConversionError;
        if (pos.* + float_slice.len > buf.len) return error.ConversionError;
        @memcpy(buf[pos.*..][0..float_slice.len], float_slice);
        pos.* += float_slice.len;
        return;
    }

    // String
    if (ffi.isString(obj)) {
        const s = try ffi.unicodeAsUTF8(obj);
        const span = std.mem.span(s);
        // Write quoted string with minimal escaping
        if (pos.* + span.len + 2 > buf.len) return error.ConversionError;
        buf[pos.*] = '"';
        pos.* += 1;
        for (span) |ch| {
            if (pos.* >= buf.len) return error.ConversionError;
            switch (ch) {
                '"' => {
                    if (pos.* + 2 > buf.len) return error.ConversionError;
                    buf[pos.*] = '\\';
                    buf[pos.* + 1] = '"';
                    pos.* += 2;
                },
                '\\' => {
                    if (pos.* + 2 > buf.len) return error.ConversionError;
                    buf[pos.*] = '\\';
                    buf[pos.* + 1] = '\\';
                    pos.* += 2;
                },
                '\n' => {
                    if (pos.* + 2 > buf.len) return error.ConversionError;
                    buf[pos.*] = '\\';
                    buf[pos.* + 1] = 'n';
                    pos.* += 2;
                },
                '\r' => {
                    if (pos.* + 2 > buf.len) return error.ConversionError;
                    buf[pos.*] = '\\';
                    buf[pos.* + 1] = 'r';
                    pos.* += 2;
                },
                '\t' => {
                    if (pos.* + 2 > buf.len) return error.ConversionError;
                    buf[pos.*] = '\\';
                    buf[pos.* + 1] = 't';
                    pos.* += 2;
                },
                else => {
                    buf[pos.*] = ch;
                    pos.* += 1;
                },
            }
        }
        buf[pos.*] = '"';
        pos.* += 1;
        return;
    }

    // Dict
    if (ffi.isDict(obj)) {
        if (pos.* >= buf.len) return error.ConversionError;
        buf[pos.*] = '{';
        pos.* += 1;

        var iter_pos: isize = 0;
        var key: ?*PyObject = null;
        var value: ?*PyObject = null;
        var first = true;

        while (ffi.dictNext(obj, &iter_pos, &key, &value)) {
            if (!first) {
                if (pos.* + 2 > buf.len) return error.ConversionError;
                buf[pos.*] = ',';
                buf[pos.* + 1] = ' ';
                pos.* += 2;
            }
            first = false;

            // Key must be string
            if (key) |k| {
                try writeJsonValue(k, buf, pos);
            }
            if (pos.* >= buf.len) return error.ConversionError;
            buf[pos.*] = ':';
            pos.* += 1;
            if (pos.* >= buf.len) return error.ConversionError;
            buf[pos.*] = ' ';
            pos.* += 1;

            if (value) |v| {
                try writeJsonValue(v, buf, pos);
            }
        }

        if (pos.* >= buf.len) return error.ConversionError;
        buf[pos.*] = '}';
        pos.* += 1;
        return;
    }

    // List
    if (c.PyList_Check(obj) != 0) {
        if (pos.* >= buf.len) return error.ConversionError;
        buf[pos.*] = '[';
        pos.* += 1;

        const size = c.PyList_Size(obj);
        var i: isize = 0;
        while (i < size) : (i += 1) {
            if (i > 0) {
                if (pos.* + 2 > buf.len) return error.ConversionError;
                buf[pos.*] = ',';
                buf[pos.* + 1] = ' ';
                pos.* += 2;
            }
            const item = c.PyList_GetItem(obj, i); // borrowed
            if (item) |it| {
                try writeJsonValue(it, buf, pos);
            }
        }

        if (pos.* >= buf.len) return error.ConversionError;
        buf[pos.*] = ']';
        pos.* += 1;
        return;
    }

    // Fallback: str() then quote
    const str_obj = try ffi.objectStr(obj);
    defer ffi.decref(str_obj);
    try writeJsonValue(str_obj, buf, pos);
}

// ── Python handler invocation ───────────────────────────────────────

/// Result of invoking a Python handler — either completed or needs async I/O.
pub const InvokeResult = union(enum) {
    /// Handler completed synchronously — response is ready.
    response: response_mod.Response,
    /// Handler yielded a redis sentinel — needs async I/O.
    /// py_coro is owned by caller. RESP written directly into send buffer.
    redis_yield: RedisYield,
    /// Handler yielded a postgres sentinel — needs async I/O.
    /// py_coro is owned by caller. SQL wire message written directly into send buffer.
    pg_yield: PgYield,

    pub const RedisYield = struct {
        py_coro: *PyObject,
        bytes_written: usize,
    };

    pub const PgYield = struct {
        py_coro: *PyObject,
        bytes_written: usize,
        cmd: PgCmd,
        stmt_idx: u16,
    };
};

/// Invoke a Python handler. Caller must hold the GIL and provide the _snek module.
/// On redis/pg yield, writes protocol bytes directly into the provided send buffers.
/// Returns InvokeResult — either a response or a lightweight yield descriptor.
pub fn invokePythonHandler(
    mod: *PyObject,
    handler_id: u32,
    req: *const http1.Request,
    params: []const router_mod.PathParam,
    resp_body_buf: []u8,
    redis_send_buf: ?[]u8,
    pg_send_buf: ?[]u8,
    pg_stmt_cache: ?*StmtCache,
    pg_conn_prepared: ?*[MAX_PG_STMTS]bool,
) !InvokeResult {
    const handler = module.getHandler(mod, handler_id) orelse
        return .{ .response = response_mod.Response.init(500) };
    const flags = module.getHandlerFlags(mod, handler_id);

    const call_result = if (flags.no_args) blk: {
        break :blk ffi.vectorcallNoArgs(handler) catch {
            if (ffi.errOccurred()) ffi.errPrint();
            return .{ .response = response_mod.Response.init(500) };
        };
    } else if (flags.needs_params) blk: {
        if (params.len > 0) {
            const kwargs = buildParamsKwargs(params) catch return .{ .response = response_mod.Response.init(500) };
            defer ffi.decref(kwargs);
            const empty_args = ffi.tupleNew(0) catch return .{ .response = response_mod.Response.init(500) };
            defer ffi.decref(empty_args);
            break :blk ffi.callObjectKwargs(handler, empty_args, kwargs) catch {
                if (ffi.errOccurred()) ffi.errPrint();
                return .{ .response = response_mod.Response.init(500) };
            };
        } else {
            break :blk ffi.vectorcallNoArgs(handler) catch {
                if (ffi.errOccurred()) ffi.errPrint();
                return .{ .response = response_mod.Response.init(500) };
            };
        }
    } else blk: {
        const req_dict = buildRequestDict(req, params) catch return .{ .response = response_mod.Response.init(500) };
        defer ffi.decref(req_dict);
        break :blk ffi.vectorcallOneArg(handler, req_dict) catch {
            if (ffi.errOccurred()) ffi.errPrint();
            return .{ .response = response_mod.Response.init(500) };
        };
    };

    // Drive coroutines (async def) — first yield may require async I/O.
    // Uses PyIter_Send for fast path: no method lookup, no args tuple,
    // no StopIteration exception on return.
    if (ffi.isCoroutine(call_result)) {
        const send = ffi.iterSend(call_result, ffi.none());
        switch (send.status) {
            .next => {
                // Coroutine yielded — classify as redis or postgres
                const sentinel = send.result.?;
                defer ffi.decref(sentinel);

                const yield = classifySentinel(sentinel, call_result, redis_send_buf, pg_send_buf, pg_stmt_cache, pg_conn_prepared) catch {
                    ffi.coroutineClose(call_result);
                    ffi.decref(call_result);
                    return .{ .response = response_mod.Response.init(503) };
                };
                return switch (yield) {
                    .redis => |ry| .{ .redis_yield = ry },
                    .pg => |pg| .{ .pg_yield = pg },
                };
            },
            .@"return" => {
                // Coroutine returned immediately (async def with no await)
                ffi.decref(call_result);
                const result = send.result orelse return .{ .response = response_mod.Response.init(500) };
                defer ffi.decref(result);
                return .{ .response = convertPythonResponse(result, resp_body_buf) catch response_mod.Response.init(500) };
            },
            .@"error" => {
                ffi.decref(call_result);
                if (ffi.errOccurred()) ffi.errPrint();
                return .{ .response = response_mod.Response.init(500) };
            },
        }
    }

    // Sync handler — not a coroutine
    defer ffi.decref(call_result);
    return .{ .response = convertPythonResponse(call_result, resp_body_buf) catch response_mod.Response.init(500) };
}

/// Redis command IDs — must match _Cmd in app.py.
pub const RedisCmd = enum(u8) {
    GET, SET, DEL, INCR, EXPIRE, TTL, EXISTS, PING, SETEX,

    pub fn name(self: RedisCmd) []const u8 {
        return switch (self) {
            .GET => "GET", .SET => "SET", .DEL => "DEL",
            .INCR => "INCR", .EXPIRE => "EXPIRE", .TTL => "TTL",
            .EXISTS => "EXISTS", .PING => "PING", .SETEX => "SETEX",
        };
    }
};

/// Postgres command IDs — must match _DbCmd in app.py.
pub const PgCmd = enum(u8) {
    EXECUTE = 100,
    FETCH_ONE = 101,
    FETCH_ALL = 102,
};

/// Classified sentinel — either redis or postgres.
pub const SentinelYield = union(enum) {
    redis: InvokeResult.RedisYield,
    pg: InvokeResult.PgYield,
};

/// Classify a coroutine sentinel and write protocol bytes directly into the
/// destination buffer. Returns lightweight metadata (py_coro + bytes_written).
pub fn classifySentinel(
    sentinel: *PyObject,
    py_coro: *PyObject,
    redis_buf: ?[]u8,
    pg_buf: ?[]u8,
    pg_stmt_cache: ?*StmtCache,
    pg_conn_prepared: ?*[MAX_PG_STMTS]bool,
) !SentinelYield {
    if (!ffi.isTuple(sentinel)) return error.SentinelNotTuple;
    const size = ffi.tupleSize(sentinel);
    if (size < 1) return error.SentinelEmpty;

    const id_obj = ffi.tupleGetItem(sentinel, 0) orelse return error.SentinelMissingId;
    if (c.PyLong_Check(id_obj) == 0) return error.SentinelIdNotInt;
    const id = try ffi.longAsLong(id_obj);

    // Redis: command IDs 0-8
    if (id >= 0 and id <= @intFromEnum(RedisCmd.SETEX)) {
        const buf = redis_buf orelse return error.NoRedisBuffer;
        const cmd_info = try checkRedisSentinel(sentinel);
        const n = writeResp(buf, cmd_info.args[0..cmd_info.arg_count]);
        if (n == 0) return error.RespBufferOverflow;
        return .{ .redis = .{ .py_coro = py_coro, .bytes_written = n } };
    }

    // Postgres: command IDs 100-102
    // Sentinel format: (cmd_id, sql_string, param1, param2, ...)
    if (id >= 100 and id <= 102) {
        const buf = pg_buf orelse return error.NoPgBuffer;
        const cache = pg_stmt_cache orelse return error.NoPgStmtCache;
        const cmd: PgCmd = @enumFromInt(@as(u8, @intCast(id)));
        if (size < 2) return error.SentinelMissingSql;
        const sql_obj = ffi.tupleGetItem(sentinel, 1) orelse return error.SentinelMissingSql;
        if (!ffi.isString(sql_obj)) return error.SentinelSqlNotString;
        const sql_str = try ffi.unicodeAsUTF8(sql_obj);
        const sql = std.mem.span(sql_str);

        // Extract params from tuple indices 2..size
        const num_params: usize = @intCast(size - 2);
        var param_bufs: [StmtCache.MAX_PARAMS]?[]const u8 = .{null} ** StmtCache.MAX_PARAMS;
        // Backing storage for str() conversions of non-string params
        var str_bufs: [StmtCache.MAX_PARAMS][64]u8 = undefined;

        for (0..num_params) |pi| {
            const param_obj = ffi.tupleGetItem(sentinel, @intCast(pi + 2)) orelse continue;
            if (ffi.isNone(param_obj)) {
                param_bufs[pi] = null; // SQL NULL
            } else if (ffi.isString(param_obj)) {
                const s = try ffi.unicodeAsUTF8(param_obj);
                param_bufs[pi] = std.mem.span(s);
            } else {
                // Convert non-string params (int, float, bool) to text via Python str()
                const str_obj = ffi.objectStr(param_obj) catch return error.ParamConvertFailed;
                defer ffi.decref(str_obj);
                const s = try ffi.unicodeAsUTF8(str_obj);
                const span = std.mem.span(s);
                if (span.len <= str_bufs[pi].len) {
                    @memcpy(str_bufs[pi][0..span.len], span);
                    param_bufs[pi] = str_bufs[pi][0..span.len];
                } else {
                    return error.ParamTooLong;
                }
            }
        }

        const prepared = pg_conn_prepared orelse return error.NoPgConnPrepared;
        const result = try cache.encodeExtendedWithParams(buf, sql, prepared, param_bufs[0..num_params]);
        return .{ .pg = .{ .py_coro = py_coro, .bytes_written = result.bytes_written, .cmd = cmd, .stmt_idx = result.stmt_idx } };
    }

    return error.UnknownSentinelId;
}

/// Check if a sentinel is a redis command: (cmd_id, *args).
/// cmd_id is an integer index into REDIS_CMDS.
/// Extracts command name + args as string slices (valid while GIL held).
pub const RedisSentinel = struct {
    args: [8][]const u8, // args[0] = command name from REDIS_CMDS, rest = user args
    arg_count: u8,
};

pub fn checkRedisSentinel(sentinel: *PyObject) ffi.PythonError!RedisSentinel {
    if (!ffi.isTuple(sentinel)) return error.PythonError;
    const size = ffi.tupleSize(sentinel);
    if (size < 1) return error.PythonError;

    const cmd_obj = ffi.tupleGetItem(sentinel, 0) orelse return error.PythonError;
    if (c.PyLong_Check(cmd_obj) == 0) return error.PythonError;
    const cmd_id = try ffi.longAsLong(cmd_obj);
    const cmd: RedisCmd = @enumFromInt(@as(u8, @intCast(cmd_id)));

    var result = RedisSentinel{ .args = undefined, .arg_count = 0 };
    result.args[0] = cmd.name();
    result.arg_count = 1;
    var i: isize = 1;
    while (i < size and result.arg_count < 8) : (i += 1) {
        const arg_obj = ffi.tupleGetItem(sentinel, i) orelse return error.PythonError;
        if (!ffi.isString(arg_obj)) return error.TypeError;
        const s = try ffi.unicodeAsUTF8(arg_obj);
        result.args[result.arg_count] = std.mem.span(s);
        result.arg_count += 1;
    }
    return result;
}

/// Build RESP protocol into a buffer from command args.
/// Returns bytes written, or 0 if buffer too small.
pub fn writeResp(buf: []u8, args: []const []const u8) usize {
    var pos: usize = 0;
    if (pos >= buf.len) return 0;
    buf[pos] = '*';
    pos += 1;
    const n_str = std.fmt.bufPrint(buf[pos..], "{d}\r\n", .{args.len}) catch return 0;
    pos += n_str.len;
    for (args) |arg| {
        if (pos >= buf.len) return 0;
        buf[pos] = '$';
        pos += 1;
        const l_str = std.fmt.bufPrint(buf[pos..], "{d}\r\n", .{arg.len}) catch return 0;
        pos += l_str.len;
        if (pos + arg.len + 2 > buf.len) return 0;
        @memcpy(buf[pos..][0..arg.len], arg);
        pos += arg.len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
    }
    return pos;
}

// ── Server startup ──────────────────────────────────────────────────

const server_mod = @import("../server.zig");
const posix = std.posix;

fn shutdownSignalHandler(_: c_int) callconv(.c) void {
    // Crash-fast: skip atexit handlers entirely. The OS reclaims everything.
    std.posix.exit(0);
}

fn installShutdownSignals() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = shutdownSignalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.INT, &act, null);
}

const drv_log = std.log.scoped(.@"snek/driver");

pub fn startServer(host: []const u8, port: u16, threads: usize, backlog: u16) !void {
    drv_log.info("startServer called host={s} port={d} threads={d} backlog={d}", .{ host, port, threads, backlog });
    const mod = module.getCurrentModule() orelse return error.ModuleNotSet;
    const state = module.getState(mod) orelse return error.ModuleNotSet;

    installShutdownSignals();

    var server = server_mod.Server.init(std.heap.smp_allocator, host, port);
    defer server.deinit();
    server.num_threads = threads;
    server.backlog = @intCast(backlog);

    if (module.getModuleRef(mod)) |ref| server.setModuleRef(ref);

    var i: u32 = 0;
    while (i < state.py_handler_count) : (i += 1) {
        const entry = state.route_entries[i];
        const method = router_mod.Method.fromString(entry.method[0..entry.method_len]) orelse continue;
        server.addPythonRoute(method, entry.path[0..entry.path_len], i) catch continue;
    }

    _ = gil.PyEval_SaveThread();
    try server_mod.runPipeline(std.heap.smp_allocator, &server);
}

// ── Tests ───────────────────────────────────────────────────────────

test "build request dict" {
    ffi.init();

    defer ffi.deinit();

    const req = try http1.Request.parse("GET /hello HTTP/1.1\r\nHost: localhost\r\nX-Test: value\r\n\r\n");

    const empty_params: [0]router_mod.PathParam = .{};
    const dict = try buildRequestDict(&req, &empty_params);
    defer ffi.decref(dict);

    // Verify method
    const method = ffi.dictGetItemString(dict, "method") orelse unreachable;
    const method_str = try ffi.unicodeAsUTF8(method);
    try std.testing.expect(std.mem.eql(u8, std.mem.span(method_str), "GET"));

    // Verify path
    const path = ffi.dictGetItemString(dict, "path") orelse unreachable;
    const path_str = try ffi.unicodeAsUTF8(path);
    try std.testing.expect(std.mem.eql(u8, std.mem.span(path_str), "/hello"));

    // Verify headers
    const headers = ffi.dictGetItemString(dict, "headers") orelse unreachable;
    try std.testing.expect(ffi.isDict(headers));
}

test "build request dict with params" {
    ffi.init();

    defer ffi.deinit();

    const req = try http1.Request.parse("GET /users/42 HTTP/1.1\r\nHost: h\r\n\r\n");

    const params = [_]router_mod.PathParam{
        .{ .name = "id", .value = "42" },
    };
    const dict = try buildRequestDict(&req, &params);
    defer ffi.decref(dict);

    const params_dict = ffi.dictGetItemString(dict, "params") orelse unreachable;
    try std.testing.expect(ffi.isDict(params_dict));
    const id_val = ffi.dictGetItemString(params_dict, "id") orelse unreachable;
    const id_str = try ffi.unicodeAsUTF8(id_val);
    try std.testing.expect(std.mem.eql(u8, std.mem.span(id_str), "42"));
}

test "convert dict response" {
    ffi.init();
    defer ffi.deinit();

    const dict = try ffi.dictNew();
    defer ffi.decref(dict);
    const val = try ffi.unicodeFromString("hello");
    defer ffi.decref(val);
    try ffi.dictSetItemString(dict, "message", val);

    var body_buf: [4096]u8 = undefined;
    const resp = try convertPythonResponse(dict, &body_buf);

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(resp.body != null);
    // Should contain "message" and "hello" in JSON
    try std.testing.expect(std.mem.indexOf(u8, resp.body.?, "message") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body.?, "hello") != null);
}

test "convert string response" {
    ffi.init();
    defer ffi.deinit();

    const s = try ffi.unicodeFromString("plain text");
    defer ffi.decref(s);

    var body_buf: [4096]u8 = undefined;
    const resp = try convertPythonResponse(s, &body_buf);

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.eql(u8, resp.body.?, "plain text"));
}

test "convert none response" {
    ffi.init();
    defer ffi.deinit();

    const none = ffi.getNone();
    defer ffi.decref(none);

    var body_buf: [4096]u8 = undefined;
    const resp = try convertPythonResponse(none, &body_buf);

    try std.testing.expectEqual(@as(u16, 204), resp.status);
}

test "convert tuple response" {
    ffi.init();
    defer ffi.deinit();

    const tuple = try ffi.tupleNew(2);
    try ffi.tupleSetItem(tuple, 0, try ffi.longFromLong(201));
    const body = try ffi.unicodeFromString("created");
    try ffi.tupleSetItem(tuple, 1, body);

    var body_buf: [4096]u8 = undefined;
    const resp = try convertPythonResponse(tuple, &body_buf);
    defer ffi.decref(tuple);

    try std.testing.expectEqual(@as(u16, 201), resp.status);
    try std.testing.expect(std.mem.eql(u8, resp.body.?, "created"));
}

test "json serialization of nested dict" {
    ffi.init();
    defer ffi.deinit();

    // Build {"user": {"name": "snek", "active": true}, "count": 42}
    try ffi.runString(
        \\import json
        \\test_dict = {"user": {"name": "snek", "active": True}, "count": 42}
    );

    const main_mod = try ffi.importModule("__main__");
    defer ffi.decref(main_mod);
    const test_dict = try ffi.getAttr(main_mod, "test_dict");
    defer ffi.decref(test_dict);

    var body_buf: [4096]u8 = undefined;
    const json_str = try pyDictToJson(test_dict, &body_buf);

    // Verify key parts are present
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"snek\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "true") != null);
}
