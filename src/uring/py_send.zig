const std = @import("std");
const ffi = @import("../python/ffi.zig");
const PyObject = ffi.PyObject;
const response_mod = @import("../http/response.zig");
const result_lease = @import("../db/result_lease.zig");
const ResultLease = result_lease.ResultLease;
const SlabPool = result_lease.SlabPool;
const py_json = @import("../python/py_json.zig");

pub const PyBodyHold = struct {
    owner: ?*PyObject = null,
    buffer: ?ffi.BufferView = null,

    pub fn deinit(self: *PyBodyHold) void {
        if (self.buffer) |*view| ffi.releaseBuffer(view);
        ffi.xdecref(self.owner);
        self.* = .{};
    }
};

pub const Prepared = struct {
    response: response_mod.Response,
    body_lease: ResultLease = .{},
    py_body: PyBodyHold = .{},

    pub fn fromResponse(response: response_mod.Response) Prepared {
        return .{ .response = response };
    }

    pub fn deinit(self: *Prepared) void {
        self.body_lease.release();
        self.py_body.deinit();
        self.* = undefined;
    }
};

pub const PrepareError = ffi.PythonError || error{
    UnsupportedReturnType,
    BufferTooSmall,
    SlabPoolClosed,
    SlabPoolExhausted,
    OutOfMemory,
};

fn prepareBinary(py_result: *PyObject) PrepareError!Prepared {
    if (ffi.isBytes(py_result)) {
        var resp = response_mod.Response.init(.ok);
        _ = resp.setBody(ffi.bytesData(py_result));
        return .{
            .response = resp,
            .py_body = .{ .owner = ffi.increfBorrowed(py_result) },
        };
    }

    if (ffi.isMemoryView(py_result)) {
        var view = try ffi.getReadOnlyBuffer(py_result);
        errdefer ffi.releaseBuffer(&view);
        if (!ffi.bufferIsReadOnly(&view)) return error.UnsupportedReturnType;
        var resp = response_mod.Response.init(.ok);
        _ = resp.setBody(ffi.bufferData(&view));
        return .{
            .response = resp,
            .py_body = .{
                .owner = ffi.increfBorrowed(py_result),
                .buffer = view,
            },
        };
    }

    return error.UnsupportedReturnType;
}

fn prepareText(py_result: *PyObject) PrepareError!Prepared {
    if (!ffi.isString(py_result)) return error.UnsupportedReturnType;
    const s = try ffi.unicodeAsUTF8(py_result);
    return .{
        .response = response_mod.Response.text(std.mem.span(s)),
        .py_body = .{ .owner = ffi.increfBorrowed(py_result) },
    };
}

fn prepareJson(py_result: *PyObject, body_buf: []u8, pool: *SlabPool) PrepareError!Prepared {
    var pos: usize = 0;
    const wrote = py_json.tryWrite(py_result, body_buf, &pos) catch |err| switch (err) {
        error.BufferTooSmall => {
            var lease = try ResultLease.initOwned(pool);
            errdefer lease.release();
            var lease_pos: usize = 0;
            const lease_wrote = try py_json.tryWrite(py_result, lease.bytes(), &lease_pos);
            if (!lease_wrote) return error.UnsupportedReturnType;
            return .{
                .response = response_mod.Response.json(lease.constBytes()[0..lease_pos]),
                .body_lease = lease,
            };
        },
        else => return err,
    };
    if (!wrote) return error.UnsupportedReturnType;
    return Prepared.fromResponse(response_mod.Response.json(body_buf[0..pos]));
}

pub fn prepare(
    py_result: *PyObject,
    body_buf: []u8,
    pool: *SlabPool,
) PrepareError!Prepared {
    if (ffi.isNone(py_result)) {
        return Prepared.fromResponse(response_mod.Response.init(.no_content));
    }

    if (prepareBinary(py_result)) |prepared| {
        return prepared;
    } else |err| switch (err) {
        error.UnsupportedReturnType => {},
        else => return err,
    }

    if (prepareText(py_result)) |prepared| {
        return prepared;
    } else |err| switch (err) {
        error.UnsupportedReturnType => {},
        else => return err,
    }

    if (prepareJson(py_result, body_buf, pool)) |prepared| {
        return prepared;
    } else |err| switch (err) {
        error.UnsupportedReturnType => {},
        else => return err,
    }

    return error.UnsupportedReturnType;
}
