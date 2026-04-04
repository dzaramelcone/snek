//! SnekRequest — lazy Python view over retained HTTP request bytes.
//!
//! Raw request bytes live behind a retained slab lease detached from the
//! transport recv path. Python materializes typed attributes on demand and
//! caches them on the native request object.

const std = @import("std");
const ffi = @import("ffi.zig");
const http1 = @import("../net/http1.zig");
const router_mod = @import("../http/router.zig");
const result_lease = @import("../db/result_lease.zig");

const c = ffi.c;
const PyObject = ffi.PyObject;
const ResultLease = result_lease.ResultLease;
const SlabPool = result_lease.SlabPool;
const py_object_size = @sizeOf(c.PyObject);
const MAX_PARAMS = 8;

pub const Span = struct {
    offset: u32 = 0,
    len: u32 = 0,

    fn fromSlice(base: [*]const u8, bytes: []const u8) Span {
        return .{
            .offset = @intCast(@intFromPtr(bytes.ptr) - @intFromPtr(base)),
            .len = @intCast(bytes.len),
        };
    }

    fn slice(self: Span, bytes: []const u8) []const u8 {
        const start: usize = self.offset;
        const len: usize = self.len;
        return bytes[start..][0..len];
    }
};

pub const HeaderRef = struct {
    name: Span = .{},
    value: Span = .{},
};

pub const ParamRef = struct {
    name: []const u8 = &.{},
    value: Span = .{},
};

pub const Backing = struct {
    lease: ResultLease = .{},
    len: u32 = 0,
    method: Span = .{},
    path: Span = .{},
    body: ?Span = null,
    headers: [http1.MAX_HEADERS]HeaderRef = undefined,
    header_count: u16 = 0,
    params: [MAX_PARAMS]ParamRef = undefined,
    param_count: u8 = 0,
    keepalive: bool = true,

    pub fn deinit(self: *Backing) void {
        self.lease.release();
        self.* = .{};
    }

    pub fn fromParsed(lease: ResultLease, byte_len: usize, req: *const http1.Request, params: []const router_mod.PathParam) !Backing {
        if (req.method_bytes == null or req.uri == null) return error.MalformedRequest;
        if (params.len > MAX_PARAMS) return error.MalformedRequest;
        if (byte_len > std.math.maxInt(u32)) return error.BufferTooLarge;

        const all_bytes = lease.constBytes()[0..byte_len];
        const base = all_bytes.ptr;
        var backing = Backing{
            .lease = lease,
            .len = @intCast(byte_len),
            .method = Span.fromSlice(base, req.method_bytes.?),
            .path = Span.fromSlice(base, req.uri.?),
            .header_count = @intCast(req.header_count),
            .param_count = @intCast(params.len),
            .keepalive = req.keepalive,
        };

        if (req.body) |body| {
            backing.body = Span.fromSlice(base, body);
        }
        for (req.headers[0..req.header_count], 0..) |header, i| {
            backing.headers[i] = .{
                .name = Span.fromSlice(base, header.name),
                .value = Span.fromSlice(base, header.value),
            };
        }
        for (params, 0..) |param, i| {
            backing.params[i] = .{
                .name = param.name,
                .value = Span.fromSlice(base, param.value),
            };
        }
        return backing;
    }
};

pub const SnekRequestData = struct {
    backing: Backing = .{},
    method_obj: ?*PyObject = null,
    path_obj: ?*PyObject = null,
    body_obj: ?*PyObject = null,
    headers_obj: ?*PyObject = null,
    params_obj: ?*PyObject = null,
};

fn getData(obj: *PyObject) *SnekRequestData {
    const base: [*]u8 = @ptrCast(obj);
    return @ptrCast(@alignCast(base + py_object_size));
}

fn requestBytes(data: *const SnekRequestData) []const u8 {
    return data.backing.lease.constBytes()[0..@as(usize, data.backing.len)];
}

fn methodSlice(data: *const SnekRequestData) []const u8 {
    return data.backing.method.slice(requestBytes(data));
}

fn pathSlice(data: *const SnekRequestData) []const u8 {
    return data.backing.path.slice(requestBytes(data));
}

fn bodySlice(data: *const SnekRequestData) ?[]const u8 {
    return if (data.backing.body) |body| body.slice(requestBytes(data)) else null;
}

fn headerName(data: *const SnekRequestData, index: usize) []const u8 {
    return data.backing.headers[index].name.slice(requestBytes(data));
}

fn headerValue(data: *const SnekRequestData, index: usize) []const u8 {
    return data.backing.headers[index].value.slice(requestBytes(data));
}

fn paramValue(data: *const SnekRequestData, index: usize) []const u8 {
    return data.backing.params[index].value.slice(requestBytes(data));
}

fn increfCached(obj: ?*PyObject) ?*PyObject {
    if (obj) |value| {
        ffi.incref(value);
        return value;
    }
    return null;
}

fn bytesFromSlice(bytes: []const u8) ffi.PythonError!*PyObject {
    const obj = try ffi.bytesNew(@intCast(bytes.len));
    @memcpy(ffi.bytesAsSlice(obj, bytes.len)[0..bytes.len], bytes);
    return obj;
}

fn lowercaseUnicode(slice: []const u8) ffi.PythonError!*PyObject {
    const name_obj = try ffi.unicodeFromSlice(slice.ptr, slice.len);
    defer ffi.decref(name_obj);
    return try ffi.callMethodNoArgs(name_obj, "lower");
}

fn buildHeadersMapping(data: *const SnekRequestData) ffi.PythonError!*PyObject {
    const dict = try ffi.dictNew();
    errdefer ffi.decref(dict);
    for (0..data.backing.header_count) |i| {
        const key = try lowercaseUnicode(headerName(data, i));
        defer ffi.decref(key);
        const value = try ffi.unicodeFromSlice(headerValue(data, i).ptr, headerValue(data, i).len);
        defer ffi.decref(value);
        try ffi.dictSetItem(dict, key, value);
    }
    const proxy = c.PyDictProxy_New(dict) orelse return error.PythonError;
    ffi.decref(dict);
    return proxy;
}

fn buildParamsMapping(data: *const SnekRequestData) ffi.PythonError!*PyObject {
    const dict = try ffi.dictNew();
    errdefer ffi.decref(dict);
    for (0..data.backing.param_count) |i| {
        const key = try ffi.unicodeFromSlice(data.backing.params[i].name.ptr, data.backing.params[i].name.len);
        defer ffi.decref(key);
        const value = try ffi.unicodeFromSlice(paramValue(data, i).ptr, paramValue(data, i).len);
        defer ffi.decref(value);
        try ffi.dictSetItem(dict, key, value);
    }
    const proxy = c.PyDictProxy_New(dict) orelse return error.PythonError;
    ffi.decref(dict);
    return proxy;
}

fn attributeKey(name_obj: *PyObject) ?[]const u8 {
    if (!ffi.isString(name_obj)) return null;
    const name = ffi.unicodeAsUTF8(name_obj) catch return null;
    return std.mem.span(name);
}

fn getKnownField(_: *PyObject, data: *SnekRequestData, name: []const u8) ffi.PythonError!?*PyObject {
    if (std.mem.eql(u8, name, "method")) {
        if (increfCached(data.method_obj)) |cached| return cached;
        const obj = try ffi.unicodeFromSlice(methodSlice(data).ptr, methodSlice(data).len);
        data.method_obj = obj;
        ffi.incref(obj);
        return obj;
    }
    if (std.mem.eql(u8, name, "path")) {
        if (increfCached(data.path_obj)) |cached| return cached;
        const obj = try ffi.unicodeFromSlice(pathSlice(data).ptr, pathSlice(data).len);
        data.path_obj = obj;
        ffi.incref(obj);
        return obj;
    }
    if (std.mem.eql(u8, name, "body")) {
        if (increfCached(data.body_obj)) |cached| return cached;
        const obj = if (bodySlice(data)) |body|
            try bytesFromSlice(body)
        else
            ffi.getNone();
        data.body_obj = obj;
        ffi.incref(obj);
        return obj;
    }
    if (std.mem.eql(u8, name, "headers")) {
        if (increfCached(data.headers_obj)) |cached| return cached;
        const mapping = try buildHeadersMapping(data);
        data.headers_obj = mapping;
        ffi.incref(mapping);
        return mapping;
    }
    if (std.mem.eql(u8, name, "params")) {
        if (increfCached(data.params_obj)) |cached| return cached;
        const mapping = try buildParamsMapping(data);
        data.params_obj = mapping;
        ffi.incref(mapping);
        return mapping;
    }
    if (std.mem.eql(u8, name, "keepalive")) {
        return ffi.boolFromBool(data.backing.keepalive);
    }
    return null;
}

fn snekRequestDealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const obj = self_obj orelse return;
    const data = getData(obj);
    ffi.xdecref(data.method_obj);
    ffi.xdecref(data.path_obj);
    ffi.xdecref(data.body_obj);
    ffi.xdecref(data.headers_obj);
    ffi.xdecref(data.params_obj);
    data.backing.deinit();

    const tp = c.Py_TYPE(obj);
    const free_fn = c.PyType_GetSlot(tp, c.Py_tp_free);
    if (free_fn) |f| {
        const free: *const fn (?*anyopaque) callconv(.c) void = @ptrCast(@alignCast(f));
        free(obj);
    }
    ffi.decref(@ptrCast(tp));
}

fn snekRequestGetAttr(self_obj: ?*c.PyObject, name_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const obj = self_obj orelse return null;
    const name = name_obj orelse return null;
    const key = attributeKey(name) orelse return c.PyObject_GenericGetAttr(self_obj, name_obj);
    const data = getData(obj);
    return getKnownField(obj, data, key) catch return null orelse c.PyObject_GenericGetAttr(self_obj, name_obj);
}

fn snekRequestSubscript(self_obj: ?*c.PyObject, key_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const obj = self_obj orelse return null;
    const key = key_obj orelse return null;
    const name = attributeKey(key) orelse {
        ffi.errSetString(c.PyExc_KeyError, "request keys must be strings");
        return null;
    };
    const data = getData(obj);
    return getKnownField(obj, data, name) catch return null orelse blk: {
        ffi.errSetString(c.PyExc_KeyError, "unknown request key");
        break :blk null;
    };
}

fn snekRequestRepr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const obj = self_obj orelse return null;
    const data = getData(obj);
    var buf: [192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "Request({s} {s})", .{
        methodSlice(data),
        pathSlice(data),
    }) catch return ffi.unicodeFromString("Request(?)") catch return null;
    return ffi.unicodeFromSlice(s.ptr, s.len) catch return null;
}

var type_slots = [_]c.PyType_Slot{
    .{ .slot = c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&snekRequestDealloc)) },
    .{ .slot = c.Py_tp_getattro, .pfunc = @ptrCast(@constCast(&snekRequestGetAttr)) },
    .{ .slot = c.Py_mp_subscript, .pfunc = @ptrCast(@constCast(&snekRequestSubscript)) },
    .{ .slot = c.Py_tp_repr, .pfunc = @ptrCast(@constCast(&snekRequestRepr)) },
    .{ .slot = 0, .pfunc = null },
};

var type_spec = c.PyType_Spec{
    .name = "snek.Request",
    .basicsize = @intCast(py_object_size + @sizeOf(SnekRequestData)),
    .itemsize = 0,
    .flags = c.Py_TPFLAGS_DEFAULT,
    .slots = &type_slots,
};

threadlocal var request_type: ?*PyObject = null;

pub fn initType() ffi.PythonError!void {
    if (request_type != null) return;
    request_type = c.PyType_FromSpec(&type_spec) orelse return error.PythonError;
}

pub fn resetTypeForTesting() void {
    request_type = null;
}

pub fn create(backing: Backing) ffi.PythonError!*PyObject {
    var owned_backing = backing;
    errdefer owned_backing.deinit();
    const tp = request_type orelse return error.PythonError;
    const tp_obj: *c.PyTypeObject = @ptrCast(@alignCast(tp));
    const obj: *PyObject = c.PyType_GenericAlloc(tp_obj, 0) orelse return error.PythonError;
    getData(obj).* = .{ .backing = owned_backing };
    return obj;
}

fn expectBufferEq(obj: *PyObject, expected: []const u8) !void {
    var view = std.mem.zeroes(c.Py_buffer);
    try std.testing.expectEqual(@as(c_int, 0), c.PyObject_GetBuffer(obj, &view, c.PyBUF_SIMPLE));
    defer c.PyBuffer_Release(&view);
    const ptr: [*]const u8 = @ptrCast(@alignCast(view.buf));
    try std.testing.expectEqualSlices(u8, expected, ptr[0..@intCast(view.len)]);
}

fn expectUnicodeEq(obj: *PyObject, expected: []const u8) !void {
    const s = try ffi.unicodeAsUTF8(obj);
    try std.testing.expectEqualStrings(expected, std.mem.span(s));
}

fn expectBytesEq(obj: *PyObject, expected: []const u8) !void {
    try std.testing.expect(ffi.isBytes(obj));
    try std.testing.expectEqualSlices(u8, expected, ffi.bytesData(obj));
}

fn makeBacking(raw: []const u8, params: []const router_mod.PathParam) !Backing {
    var pool = try SlabPool.init(std.testing.allocator, 1, 1);
    errdefer pool.deinit();

    var lease = try ResultLease.initOwned(&pool);
    errdefer lease.release();
    if (raw.len > lease.bytes().len) return error.BufferTooSmall;
    @memcpy(lease.bytes()[0..raw.len], raw);
    const req = try http1.Request.parse(lease.constBytes()[0..raw.len]);

    const backing = try Backing.fromParsed(lease, raw.len, &req, params);
    pool.deinit();
    return backing;
}

test "request view exposes lazy typed attributes" {
    resetTypeForTesting();
    ffi.init();
    defer ffi.deinit();
    try initType();

    const raw = "POST /users/42 HTTP/1.1\r\nHost: localhost\r\nX-Test: value\r\nContent-Length: 5\r\n\r\nhello";
    var pool = try SlabPool.init(std.testing.allocator, 1, 1);
    defer pool.deinit();

    var lease = try ResultLease.initOwned(&pool);
    errdefer lease.release();
    @memcpy(lease.bytes()[0..raw.len], raw);
    const req_parsed = try http1.Request.parse(lease.constBytes()[0..raw.len]);
    const req_path = req_parsed.uri.?;
    const params = [_]router_mod.PathParam{
        .{ .name = "id", .value = req_path["/users/".len..] },
    };
    const backing = try Backing.fromParsed(lease, raw.len, &req_parsed, &params);
    const req = try create(backing);
    defer ffi.decref(req);

    const method = try ffi.getAttr(req, "method");
    defer ffi.decref(method);
    try expectUnicodeEq(method, "POST");

    const path = try ffi.getAttr(req, "path");
    defer ffi.decref(path);
    try expectUnicodeEq(path, "/users/42");

    const body = try ffi.getAttr(req, "body");
    defer ffi.decref(body);
    try expectBytesEq(body, "hello");

    const headers = try ffi.getAttr(req, "headers");
    defer ffi.decref(headers);
    const host_key = try ffi.unicodeFromString("host");
    defer ffi.decref(host_key);
    const x_test_key = try ffi.unicodeFromString("x-test");
    defer ffi.decref(x_test_key);
    const host = c.PyObject_GetItem(headers, host_key) orelse return error.PythonError;
    defer ffi.decref(host);
    const x_test = c.PyObject_GetItem(headers, x_test_key) orelse return error.PythonError;
    defer ffi.decref(x_test);
    try expectUnicodeEq(host, "localhost");
    try expectUnicodeEq(x_test, "value");

    const params_dict = try ffi.getAttr(req, "params");
    defer ffi.decref(params_dict);
    const id_key = try ffi.unicodeFromString("id");
    defer ffi.decref(id_key);
    const id_value = c.PyObject_GetItem(params_dict, id_key) orelse return error.PythonError;
    defer ffi.decref(id_value);
    try expectUnicodeEq(id_value, "42");
}

test "request view supports mapping access" {
    resetTypeForTesting();
    ffi.init();
    defer ffi.deinit();
    try initType();

    const backing = try makeBacking("GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n", &.{});
    const req = try create(backing);
    defer ffi.decref(req);

    const key = try ffi.unicodeFromString("method");
    defer ffi.decref(key);
    const method = c.PyObject_GetItem(req, key) orelse return error.PythonError;
    defer ffi.decref(method);
    try expectUnicodeEq(method, "GET");
}
