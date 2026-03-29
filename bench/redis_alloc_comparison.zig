//! Redis allocation strategy benchmark: accumulate vs stream.
//!
//! A) Accumulate: heap-grow until full response, then PyBytes_FromStringAndSize(data, len)
//! B) Stream: parse RESP framing, PyBytes_FromStringAndSize(NULL, len), recv into PyBytes buffer
//!
//! Both create a real CPython bytes object. Measures the full path including Python allocation.

const std = @import("std");
const posix = std.posix;
const ffi = @import("ffi");
const c = ffi.c;

fn tcpConnect() !posix.socket_t {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 6379);
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    try posix.connect(sock, &addr.any, addr.getOsSockLen());
    return sock;
}

fn sendAll(sock: posix.socket_t, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        sent += try posix.write(sock, data[sent..]);
    }
}

fn seedKey(sock: posix.socket_t, allocator: std.mem.Allocator, key: []const u8, val_size: usize) !void {
    var cmd: std.ArrayList(u8) = .{};
    defer cmd.deinit(allocator);
    const w = cmd.writer(allocator);
    try w.print("*3\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n", .{ key.len, key, val_size });
    try cmd.appendNTimes(allocator, 'x', val_size);
    try cmd.appendSlice(allocator, "\r\n");
    try sendAll(sock, cmd.items);
    var buf: [64]u8 = undefined;
    _ = try posix.read(sock, &buf);
}

fn buildGetCmd(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var cmd: std.ArrayList(u8) = .{};
    const w = cmd.writer(allocator);
    try w.print("*2\r\n$3\r\nGET\r\n${d}\r\n{s}\r\n", .{ key.len, key });
    return try cmd.toOwnedSlice(allocator);
}

// ─── A) Accumulate → PyBytes_FromStringAndSize(data, len) ───────────
//
// Read into growing ArrayList until complete.
// Then create Python bytes by copying the payload out.

fn benchAccumulate(sock: posix.socket_t, get_cmd: []const u8, iterations: usize) !u64 {
    const allocator = std.heap.smp_allocator;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        try sendAll(sock, get_cmd);

        var accum: std.ArrayList(u8) = .{};
        defer accum.deinit(allocator);

        var read_buf: [65536]u8 = undefined;
        while (true) {
            const n = try posix.read(sock, &read_buf);
            if (n == 0) return error.ConnectionClosed;
            try accum.appendSlice(allocator, read_buf[0..n]);

            if (accum.items.len < 4) continue;
            if (accum.items[0] != '$') return error.UnexpectedResponse;
            const crlf = std.mem.indexOf(u8, accum.items, "\r\n") orelse continue;
            const len = std.fmt.parseInt(usize, accum.items[1..crlf], 10) catch return error.BadLength;
            const frame_end = crlf + 2 + len + 2;
            if (accum.items.len < frame_end) continue;

            const payload = accum.items[crlf + 2 ..][0..len];

            // Create Python bytes object — copies payload into Python's heap
            const py_bytes = c.PyBytes_FromStringAndSize(payload.ptr, @intCast(len)) orelse
                return error.PythonAlloc;
            c.Py_DECREF(py_bytes);
            break;
        }
    }

    return timer.read() / std.time.ns_per_ms;
}

// ─── B) Stream → PyBytes_FromStringAndSize(NULL, len), recv into it ─
//
// Parse RESP framing from small buffer to get payload length.
// Pre-allocate Python bytes object, recv payload directly into its buffer.

fn benchStream(sock: posix.socket_t, get_cmd: []const u8, iterations: usize) !u64 {
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        try sendAll(sock, get_cmd);

        var frame_buf: [64]u8 = undefined;
        var frame_len: usize = 0;
        var payload_len: usize = 0;
        var payload_start: usize = 0;

        while (true) {
            const n = try posix.read(sock, frame_buf[frame_len..]);
            if (n == 0) return error.ConnectionClosed;
            frame_len += n;

            if (frame_buf[0] != '$') return error.UnexpectedResponse;
            if (std.mem.indexOf(u8, frame_buf[0..frame_len], "\r\n")) |crlf| {
                payload_len = std.fmt.parseInt(usize, frame_buf[1..crlf], 10) catch return error.BadLength;
                payload_start = crlf + 2;
                break;
            }
        }

        // Pre-allocate Python bytes — uninitialized buffer we can write into
        const py_bytes = c.PyBytes_FromStringAndSize(null, @intCast(payload_len)) orelse
            return error.PythonAlloc;
        defer c.Py_DECREF(py_bytes);
        const dest: [*]u8 = @ptrCast(c.PyBytes_AS_STRING(py_bytes));

        // Copy any payload bytes already read with framing
        const already = @min(frame_len - payload_start, payload_len);
        @memcpy(dest[0..already], frame_buf[payload_start..][0..already]);

        // Recv remaining payload directly into Python's buffer
        var filled = already;
        while (filled < payload_len) {
            const n = try posix.read(sock, dest[filled..payload_len]);
            if (n == 0) return error.ConnectionClosed;
            filled += n;
        }

        // Drain trailing \r\n
        const overshoot = (frame_len - payload_start) -| payload_len;
        var trail_read = overshoot;
        var trail_buf: [2]u8 = undefined;
        while (trail_read < 2) {
            const n = try posix.read(sock, trail_buf[trail_read..]);
            trail_read += n;
        }
    }

    return timer.read() / std.time.ns_per_ms;
}

// ─── Main ───────────────────────────────────────────────────────────

pub fn main() !void {
    // Initialize CPython
    c.Py_Initialize();
    defer c.Py_Finalize();

    const allocator = std.heap.smp_allocator;
    const ITERS = 1000;
    const sizes = [_]struct { size: usize, label: []const u8 }{
        .{ .size = 43, .label = "43B" },
        .{ .size = 1024, .label = "1KB" },
        .{ .size = 64 * 1024, .label = "64KB" },
        .{ .size = 1024 * 1024, .label = "1MB" },
        .{ .size = 20 * 1024 * 1024, .label = "20MB" },
    };

    std.debug.print("Redis → Python bytes: {d} round-trips per size\n\n", .{ITERS});

    for (sizes) |s| {
        const key = "snek:bench:alloc";
        const sock_seed = try tcpConnect();
        try seedKey(sock_seed, allocator, key, s.size);
        posix.close(sock_seed);

        const get_cmd = try buildGetCmd(allocator, key);
        defer allocator.free(get_cmd);

        const sock_a = try tcpConnect();
        defer posix.close(sock_a);
        const sock_b = try tcpConnect();
        defer posix.close(sock_b);

        const ms_a = try benchAccumulate(sock_a, get_cmd, ITERS);
        const ms_b = try benchStream(sock_b, get_cmd, ITERS);

        const us_a = @as(f64, @floatFromInt(ms_a)) * 1000.0 / @as(f64, @floatFromInt(ITERS));
        const us_b = @as(f64, @floatFromInt(ms_b)) * 1000.0 / @as(f64, @floatFromInt(ITERS));
        const speedup = us_a / @max(us_b, 0.001);
        std.debug.print("{s: >5}  accum={d: >8.1}µs  stream={d: >8.1}µs  {d:.2}x\n", .{
            s.label, us_a, us_b, speedup,
        });
    }
}
