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

// ── Request dict builder ────────────────────────────────────────────

/// Build a Python dict representing the HTTP request.
///
/// Returns a new dict: {"method": "GET", "path": "/", "headers": {...}, "body": "..."}
/// Caller must decref the returned dict.
/// Safe to call from any interpreter (main or sub-interpreter).
pub fn buildRequestDict(parser: *const http1.Parser, params: []const router_mod.PathParam) ffi.PythonError!*PyObject {
    const dict = try ffi.dictNew();

    // Method
    const method_str: [*:0]const u8 = if (parser.method) |m| switch (m) {
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

    // Path
    const path = parser.uri orelse "/";
    var path_buf: [8192:0]u8 = undefined;
    if (path.len >= path_buf.len) return error.PythonError;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_obj = try ffi.unicodeFromString(path_buf[0..path.len :0]);
    defer ffi.decref(path_obj);
    try ffi.dictSetItemString(dict, "path", path_obj);

    // Headers dict
    const headers_dict = try ffi.dictNew();
    defer ffi.decref(headers_dict);
    for (parser.headers[0..parser.header_count]) |h| {
        var name_buf: [256:0]u8 = undefined;
        if (h.name.len >= name_buf.len) continue;
        @memcpy(name_buf[0..h.name.len], h.name);
        name_buf[h.name.len] = 0;

        var val_buf: [4096:0]u8 = undefined;
        if (h.value.len >= val_buf.len) continue;
        @memcpy(val_buf[0..h.value.len], h.value);
        val_buf[h.value.len] = 0;

        const val_obj = try ffi.unicodeFromString(val_buf[0..h.value.len :0]);
        defer ffi.decref(val_obj);
        try ffi.dictSetItemString(headers_dict, name_buf[0..h.name.len :0], val_obj);
    }
    try ffi.dictSetItemString(dict, "headers", headers_dict);

    // Body (if present)
    if (parser.body()) |body_slice| {
        var body_buf: [8192:0]u8 = undefined;
        if (body_slice.len < body_buf.len) {
            @memcpy(body_buf[0..body_slice.len], body_slice);
            body_buf[body_slice.len] = 0;
            const body_obj = try ffi.unicodeFromString(body_buf[0..body_slice.len :0]);
            defer ffi.decref(body_obj);
            try ffi.dictSetItemString(dict, "body", body_obj);
        }
    } else {
        const none = ffi.getNone();
        defer ffi.decref(none);
        try ffi.dictSetItemString(dict, "body", none);
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
        var pname_buf: [256:0]u8 = undefined;
        if (p.name.len >= pname_buf.len) continue;
        @memcpy(pname_buf[0..p.name.len], p.name);
        pname_buf[p.name.len] = 0;

        var pval_buf: [1024:0]u8 = undefined;
        if (p.value.len >= pval_buf.len) continue;
        @memcpy(pval_buf[0..p.value.len], p.value);
        pval_buf[p.value.len] = 0;

        const pval_obj = try ffi.unicodeFromString(pval_buf[0..p.value.len :0]);
        defer ffi.decref(pval_obj);
        try ffi.dictSetItemString(kwargs, pname_buf[0..p.name.len :0], pval_obj);
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

/// Invoke a Python handler. Caller must hold the GIL and provide the _snek module.
pub fn invokePythonHandler(
    mod: *PyObject,
    handler_id: u32,
    parser: *const http1.Parser,
    params: []const router_mod.PathParam,
    resp_body_buf: []u8,
) response_mod.Response {
    const handler = module.getHandler(mod, handler_id) orelse
        return response_mod.Response.init(500);
    const flags = module.getHandlerFlags(mod, handler_id);

    const call_result = if (flags.no_args) blk: {
        break :blk ffi.callObject(handler, null) catch {
            if (ffi.errOccurred()) ffi.errPrint();
            return response_mod.Response.init(500);
        };
    } else if (flags.needs_params) blk: {
        const empty_args = ffi.tupleNew(0) catch return response_mod.Response.init(500);
        defer ffi.decref(empty_args);

        if (params.len > 0) {
            const kwargs = buildParamsKwargs(params) catch return response_mod.Response.init(500);
            defer ffi.decref(kwargs);
            break :blk ffi.callObjectKwargs(handler, empty_args, kwargs) catch {
                if (ffi.errOccurred()) ffi.errPrint();
                return response_mod.Response.init(500);
            };
        } else {
            break :blk ffi.callObject(handler, empty_args) catch {
                if (ffi.errOccurred()) ffi.errPrint();
                return response_mod.Response.init(500);
            };
        }
    } else blk: {
        const req_dict = buildRequestDict(parser, params) catch return response_mod.Response.init(500);
        defer ffi.decref(req_dict);
        const call_args = ffi.tupleNew(1) catch return response_mod.Response.init(500);
        ffi.incref(req_dict);
        ffi.tupleSetItem(call_args, 0, req_dict) catch {
            ffi.decref(call_args);
            return response_mod.Response.init(500);
        };
        const result = ffi.callObject(handler, call_args) catch {
            ffi.decref(call_args);
            if (ffi.errOccurred()) ffi.errPrint();
            return response_mod.Response.init(500);
        };
        ffi.decref(call_args);
        break :blk result;
    };

    // Drive coroutines (async def) to completion
    const py_result = if (ffi.isCoroutine(call_result)) blk: {
        const none = ffi.getNone();
        defer ffi.decref(none);
        if (ffi.callMethod1(call_result, "send", none)) |unexpected| {
            ffi.decref(unexpected);
            ffi.decref(call_result);
            return response_mod.Response.init(501);
        } else |_| {
            const exc = ffi.errFetch();
            defer {
                if (exc.exc_type) |t| ffi.decref(t);
                if (exc.exc_tb) |tb| ffi.decref(tb);
            }
            ffi.decref(call_result);
            if (exc.exc_value) |val| {
                const result = ffi.stopIterationValue(val) orelse val;
                if (result != val) ffi.decref(val);
                break :blk result;
            }
            return response_mod.Response.init(500);
        }
    } else call_result;
    defer ffi.decref(py_result);

    return convertPythonResponse(py_result, resp_body_buf) catch response_mod.Response.init(500);
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

pub fn startServer(host: []const u8, port: u16) !void {
    const mod = module.getCurrentModule() orelse return error.ModuleNotSet;

    var srv = server_mod.Server.init(std.heap.smp_allocator, .{
        .host = host,
        .port = port,
    });
    defer srv.deinit();

    var i: u32 = 0;
    while (i < module.getHandlerCount(mod)) : (i += 1) {
        const entry = module.getRouteEntry(mod, i) orelse continue;
        const method_slice = entry.method[0..entry.method_len];
        const method = router_mod.Method.fromString(method_slice) orelse continue;
        const path_slice = entry.path[0..entry.path_len];
        try srv.addPythonRoute(method, path_slice, i);
    }

    if (module.getModuleRef(mod)) |ref| {
        srv.setModuleRef(ref);
    }

    installShutdownSignals();

    // Release main GIL. Each tardy thread creates its own sub-interpreter.
    // srv.run() blocks until exit(0) from signal handler — no cleanup needed.
    _ = gil.PyEval_SaveThread();
    try srv.run();
}

// ── Tests ───────────────────────────────────────────────────────────

test "build request dict" {
    ffi.init();

    defer ffi.deinit();

    var parse_buf: [8192]u8 = undefined;
    var parser = http1.Parser.init(&parse_buf);
    _ = try parser.feed("GET /hello HTTP/1.1\r\nHost: localhost\r\nX-Test: value\r\n\r\n");

    const empty_params: [0]router_mod.PathParam = .{};
    const dict = try buildRequestDict(&parser, &empty_params);
    defer ffi.decref(dict);

    // Verify method
    const method = ffi.dictGetItemString(dict, "method") orelse unreachable;
    const method_str = try ffi.unicodeAsUTF8(method);
    std.testing.expect(std.mem.eql(u8, std.mem.span(method_str), "GET")) catch unreachable;

    // Verify path
    const path = ffi.dictGetItemString(dict, "path") orelse unreachable;
    const path_str = try ffi.unicodeAsUTF8(path);
    std.testing.expect(std.mem.eql(u8, std.mem.span(path_str), "/hello")) catch unreachable;

    // Verify headers
    const headers = ffi.dictGetItemString(dict, "headers") orelse unreachable;
    std.testing.expect(ffi.isDict(headers)) catch unreachable;
}

test "build request dict with params" {
    ffi.init();

    defer ffi.deinit();

    var parse_buf: [8192]u8 = undefined;
    var parser = http1.Parser.init(&parse_buf);
    _ = try parser.feed("GET /users/42 HTTP/1.1\r\nHost: h\r\n\r\n");

    const params = [_]router_mod.PathParam{
        .{ .name = "id", .value = "42" },
    };
    const dict = try buildRequestDict(&parser, &params);
    defer ffi.decref(dict);

    const params_dict = ffi.dictGetItemString(dict, "params") orelse unreachable;
    std.testing.expect(ffi.isDict(params_dict)) catch unreachable;
    const id_val = ffi.dictGetItemString(params_dict, "id") orelse unreachable;
    const id_str = try ffi.unicodeAsUTF8(id_val);
    std.testing.expect(std.mem.eql(u8, std.mem.span(id_str), "42")) catch unreachable;
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

    std.testing.expectEqual(@as(u16, 200), resp.status) catch unreachable;
    std.testing.expect(resp.body != null) catch unreachable;
    // Should contain "message" and "hello" in JSON
    std.testing.expect(std.mem.indexOf(u8, resp.body.?, "message") != null) catch unreachable;
    std.testing.expect(std.mem.indexOf(u8, resp.body.?, "hello") != null) catch unreachable;
}

test "convert string response" {
    ffi.init();
    defer ffi.deinit();

    const s = try ffi.unicodeFromString("plain text");
    defer ffi.decref(s);

    var body_buf: [4096]u8 = undefined;
    const resp = try convertPythonResponse(s, &body_buf);

    std.testing.expectEqual(@as(u16, 200), resp.status) catch unreachable;
    std.testing.expect(std.mem.eql(u8, resp.body.?, "plain text")) catch unreachable;
}

test "convert none response" {
    ffi.init();
    defer ffi.deinit();

    const none = ffi.getNone();
    defer ffi.decref(none);

    var body_buf: [4096]u8 = undefined;
    const resp = try convertPythonResponse(none, &body_buf);

    std.testing.expectEqual(@as(u16, 204), resp.status) catch unreachable;
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

    std.testing.expectEqual(@as(u16, 201), resp.status) catch unreachable;
    std.testing.expect(std.mem.eql(u8, resp.body.?, "created")) catch unreachable;
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
    std.testing.expect(std.mem.indexOf(u8, json_str, "\"user\"") != null) catch unreachable;
    std.testing.expect(std.mem.indexOf(u8, json_str, "\"name\"") != null) catch unreachable;
    std.testing.expect(std.mem.indexOf(u8, json_str, "\"snek\"") != null) catch unreachable;
    std.testing.expect(std.mem.indexOf(u8, json_str, "42") != null) catch unreachable;
    std.testing.expect(std.mem.indexOf(u8, json_str, "true") != null) catch unreachable;
}
