//! Async Redis connection using tardy's Socket.
//!
//! Each tardy thread owns one connection. Commands yield to the tardy scheduler
//! during I/O, allowing other coroutines to run. Bulk string responses are read
//! directly into PyBytes objects (zero-copy from socket to Python).

const std = @import("std");
const tardy = @import("../vendor/tardy/lib.zig");
const Socket = tardy.Socket;
const Runtime = tardy.Runtime;
const ffi = @import("../python/ffi.zig");
const c = ffi.c;
const protocol = @import("protocol.zig");

pub const Client = struct {
    socket: Socket,

    pub fn connect(rt: *Runtime, host: []const u8, port: u16) !Client {
        const sock = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
        try sock.connect(rt);
        return .{ .socket = sock };
    }

    /// Send a RESP command encoded into a stack buffer. No heap allocation.
    pub fn sendCommand(self: *Client, rt: *Runtime, args: []const []const u8) !void {
        var buf: [4096]u8 = undefined;
        const len = encodeInto(&buf, args);
        _ = try self.socket.send_all(rt, buf[0..len]);
    }

    /// Read a RESP response and return the value as a Python object.
    /// Bulk strings are received directly into PyBytes (zero-copy).
    /// Simple strings become PyUnicode, integers become PyLong, null becomes Py_None.
    pub fn readPythonResponse(self: *Client, rt: *Runtime) !*ffi.PyObject {
        var frame_buf: [256]u8 = undefined;
        var frame_len: usize = 0;

        // Read at least the type byte and first \r\n
        while (true) {
            const n = try self.socket.recv(rt, frame_buf[frame_len..]);
            if (n == 0) return error.ConnectionClosed;
            frame_len += n;
            if (std.mem.indexOf(u8, frame_buf[0..frame_len], "\r\n") != null) break;
        }

        const type_byte = frame_buf[0];
        const crlf = std.mem.indexOf(u8, frame_buf[0..frame_len], "\r\n").?;
        const line = frame_buf[1..crlf];

        switch (type_byte) {
            // +OK\r\n → PyUnicode
            '+' => return ffi.unicodeFromString(toSentinel(&frame_buf, 1, crlf)),

            // -ERR message\r\n → raise Python exception, return error
            '-' => {
                c.PyErr_SetString(c.PyExc_RuntimeError, toSentinel(&frame_buf, 1, crlf));
                return error.PythonError;
            },

            // :42\r\n → PyLong
            ':' => {
                const val = std.fmt.parseInt(i64, line, 10) catch return error.InvalidInteger;
                return ffi.longFromLong(val);
            },

            // _\r\n → Py_None
            '_' => return ffi.getNone(),

            // $-1\r\n → Py_None, $N\r\n<N bytes>\r\n → PyBytes (zero-copy recv)
            '$' => {
                const len_val = std.fmt.parseInt(i64, line, 10) catch return error.InvalidLength;
                if (len_val < 0) return ffi.getNone();
                const payload_len: usize = @intCast(len_val);

                // Pre-allocate Python bytes with uninitialized buffer
                const py_bytes = c.PyBytes_FromStringAndSize(null, @intCast(payload_len)) orelse
                    return error.PythonError;
                errdefer c.Py_DECREF(py_bytes);
                const dest: [*]u8 = @ptrCast(c.PyBytes_AS_STRING(py_bytes));

                // Some payload bytes may already be in frame_buf after the \r\n
                const payload_start = crlf + 2;
                const already = @min(frame_len - payload_start, payload_len);
                if (already > 0)
                    @memcpy(dest[0..already], frame_buf[payload_start..][0..already]);

                // Recv remaining payload directly into Python's buffer
                var filled = already;
                while (filled < payload_len) {
                    const n = try self.socket.recv(rt, dest[filled..payload_len]);
                    if (n == 0) return error.ConnectionClosed;
                    filled += n;
                }

                // Drain trailing \r\n
                const overshoot = (frame_len - payload_start) -| payload_len;
                var trail_read = overshoot;
                var trail_buf: [2]u8 = undefined;
                while (trail_read < 2) {
                    const n = try self.socket.recv(rt, trail_buf[trail_read..]);
                    trail_read += n;
                }

                return py_bytes;
            },

            // *N\r\n → PyList of recursively-read elements
            '*' => {
                const count_val = std.fmt.parseInt(i64, line, 10) catch return error.InvalidLength;
                if (count_val < 0) return ffi.getNone();
                const count: usize = @intCast(count_val);

                const py_list = c.PyList_New(@intCast(count)) orelse return error.PythonError;
                errdefer c.Py_DECREF(py_list);

                for (0..count) |i| {
                    const item = try self.readPythonResponse(rt);
                    // PyList_SET_ITEM steals the reference
                    c.PyList_SET_ITEM(py_list, @intCast(i), item);
                }

                return py_list;
            },

            else => return error.UnknownRespType,
        }
    }

    pub fn close(self: *Client) void {
        self.socket.close_blocking();
    }
};

// ── RESP encoding into a fixed buffer (no allocator) ────────────────

fn encodeInto(buf: []u8, args: []const []const u8) usize {
    var pos: usize = 0;

    buf[pos] = '*';
    pos += 1;
    pos += writeUsize(buf[pos..], args.len);
    buf[pos] = '\r';
    buf[pos + 1] = '\n';
    pos += 2;

    for (args) |arg| {
        buf[pos] = '$';
        pos += 1;
        pos += writeUsize(buf[pos..], arg.len);
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
        @memcpy(buf[pos..][0..arg.len], arg);
        pos += arg.len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
    }

    return pos;
}

fn writeUsize(buf: []u8, n: usize) usize {
    if (n == 0) {
        buf[0] = '0';
        return 1;
    }
    var digits: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) digits += 1;
    v = n;
    var i = digits;
    while (i > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    return digits;
}

/// Null-terminate a slice in frame_buf for C string APIs.
fn toSentinel(buf: *[256]u8, start: usize, end: usize) [*:0]const u8 {
    buf[end] = 0;
    return buf[start..end :0];
}
