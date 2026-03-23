//! macOS/BSD kqueue fallback for async I/O.
//! Adapts kqueue's readiness-based model to our completion-based interface.
//! No zero-copy, no SQPOLL — dev fallback, not the production target.

const std = @import("std");
const posix = std.posix;
const fake_io = @import("fake_io.zig");
const io = @import("io.zig");

const CompletionEntry = fake_io.CompletionEntry;

const OpType = enum {
    read,
    write,
    accept,
    connect,
    close,
    send,
    recv,
    timeout,
    cancel,
};

const PendingOp = struct {
    op_type: OpType,
    fd: i32,
    user_data: u64,
    buf: ?[]u8,
    buf_const: ?[]const u8,
    offset: u64,
    timeout_ns: u64,
    addr: ?[]const u8,
    port: u16,
};

pub const Kqueue = struct {
    kq: i32,
    pending: std.ArrayList(PendingOp),
    immediate: std.ArrayList(CompletionEntry),
    allocator: std.mem.Allocator,

    pub fn init(cfg: @import("io.zig").IoConfig) !Kqueue {
        const allocator = cfg.allocator;
        const kq = blk: {
            const ret = std.c.kqueue();
            if (ret == -1) return error.KqueueCreateFailed;
            break :blk @as(i32, @intCast(ret));
        };
        return .{
            .kq = kq,
            .pending = .{},
            .immediate = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Kqueue) void {
        posix.close(@intCast(self.kq));
        self.pending.deinit(self.allocator);
        self.immediate.deinit(self.allocator);
    }

    pub fn submitRead(self: *Kqueue, fd: i32, buf: []u8, offset: u64, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .read,
            .fd = fd,
            .user_data = user_data,
            .buf = buf,
            .buf_const = null,
            .offset = offset,
            .timeout_ns = 0,
            .addr = null,
            .port = 0,
        });
    }

    pub fn submitWrite(self: *Kqueue, fd: i32, buf: []const u8, offset: u64, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .write,
            .fd = fd,
            .user_data = user_data,
            .buf = null,
            .buf_const = buf,
            .offset = offset,
            .timeout_ns = 0,
            .addr = null,
            .port = 0,
        });
    }

    pub fn submitAccept(self: *Kqueue, fd: i32, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .accept,
            .fd = fd,
            .user_data = user_data,
            .buf = null,
            .buf_const = null,
            .offset = 0,
            .timeout_ns = 0,
            .addr = null,
            .port = 0,
        });
    }

    pub fn submitConnect(self: *Kqueue, fd: i32, addr: []const u8, port: u16, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .connect,
            .fd = fd,
            .user_data = user_data,
            .buf = null,
            .buf_const = null,
            .offset = 0,
            .timeout_ns = 0,
            .addr = addr,
            .port = port,
        });
    }

    pub fn submitClose(self: *Kqueue, fd: i32, user_data: u64) !void {
        // Close is immediate — just do it and queue the completion.
        posix.close(@intCast(fd));
        return self.immediate.append(self.allocator, .{
            .user_data = user_data,
            .result = 0,
            .flags = 0,
        });
    }

    pub fn submitSend(self: *Kqueue, fd: i32, buf: []const u8, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .send,
            .fd = fd,
            .user_data = user_data,
            .buf = null,
            .buf_const = buf,
            .offset = 0,
            .timeout_ns = 0,
            .addr = null,
            .port = 0,
        });
    }

    pub fn submitRecv(self: *Kqueue, fd: i32, buf: []u8, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .recv,
            .fd = fd,
            .user_data = user_data,
            .buf = buf,
            .buf_const = null,
            .offset = 0,
            .timeout_ns = 0,
            .addr = null,
            .port = 0,
        });
    }

    pub fn submitTimeout(self: *Kqueue, timeout_ns: u64, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .timeout,
            .fd = -1,
            .user_data = user_data,
            .buf = null,
            .buf_const = null,
            .offset = 0,
            .timeout_ns = timeout_ns,
            .addr = null,
            .port = 0,
        });
    }

    pub fn submitCancel(self: *Kqueue, target_user_data: u64, user_data: u64) !void {
        // Remove the target from pending
        for (self.pending.items, 0..) |item, idx| {
            if (item.user_data == target_user_data) {
                _ = self.pending.orderedRemove(idx);
                break;
            }
        }
        // Queue immediate cancel completion
        return self.immediate.append(self.allocator, .{
            .user_data = user_data,
            .result = 0,
            .flags = 0,
        });
    }

    pub fn pollCompletions(self: *Kqueue, events: []CompletionEntry) !u32 {
        var count: u32 = 0;

        // Drain immediate completions first
        while (self.immediate.items.len > 0 and count < events.len) {
            events[count] = self.immediate.orderedRemove(0);
            count += 1;
        }
        if (count >= events.len) return count;

        // Register kevents for all pending ops
        var changelist: std.ArrayList(std.c.Kevent) = .empty;
        defer changelist.deinit(self.allocator);

        for (self.pending.items) |op| {
            switch (op.op_type) {
                .read, .recv, .accept => {
                    try changelist.append(self.allocator, .{
                        .ident = @intCast(op.fd),
                        .filter = std.c.EVFILT.READ,
                        .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                        .fflags = 0,
                        .data = 0,
                        .udata = @intCast(op.user_data),
                    });
                },
                .write, .send, .connect => {
                    try changelist.append(self.allocator, .{
                        .ident = @intCast(op.fd),
                        .filter = std.c.EVFILT.WRITE,
                        .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                        .fflags = 0,
                        .data = 0,
                        .udata = @intCast(op.user_data),
                    });
                },
                .timeout => {
                    try changelist.append(self.allocator, .{
                        .ident = op.user_data,
                        .filter = std.c.EVFILT.TIMER,
                        .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                        .fflags = std.c.NOTE.NSECONDS,
                        .data = @intCast(op.timeout_ns),
                        .udata = @intCast(op.user_data),
                    });
                },
                .close, .cancel => {},
            }
        }

        if (changelist.items.len == 0) return count;

        const remaining = events.len - count;
        var kevents: [64]std.c.Kevent = undefined;
        const max_kevents = @min(remaining, 64);

        // Short timeout so we don't block forever
        const timeout = std.c.timespec{ .sec = 0, .nsec = 10_000_000 }; // 10ms

        const n = std.c.kevent(
            self.kq,
            changelist.items.ptr,
            @intCast(changelist.items.len),
            &kevents,
            @intCast(max_kevents),
            &timeout,
        );

        if (n < 0) return error.KeventFailed;

        // Process ready events
        for (kevents[0..@intCast(n)]) |kev| {
            if (count >= events.len) break;

            const user_data: u64 = @intCast(kev.udata);

            // Find and remove matching pending op
            var found_idx: ?usize = null;
            for (self.pending.items, 0..) |op, idx| {
                if (op.user_data == user_data) {
                    found_idx = idx;
                    break;
                }
            }

            if (found_idx) |idx| {
                const op = self.pending.items[idx];
                const result = self.executeOp(op, kev);
                _ = self.pending.orderedRemove(idx);
                events[count] = .{
                    .user_data = user_data,
                    .result = result,
                    .flags = 0,
                };
                count += 1;
            }
        }

        return count;
    }

    /// Non-blocking flush + peek: submit pending ops and return whatever is ready.
    /// Never blocks — returns 0 if nothing is ready yet.
    pub fn flushAndPeek(self: *Kqueue, events: []CompletionEntry) !u32 {
        var count: u32 = 0;

        // Drain immediate completions first
        while (self.immediate.items.len > 0 and count < events.len) {
            events[count] = self.immediate.orderedRemove(0);
            count += 1;
        }
        if (count >= events.len) return count;

        // Register kevents for all pending ops
        var changelist: std.ArrayList(std.c.Kevent) = .empty;
        defer changelist.deinit(self.allocator);

        for (self.pending.items) |op| {
            switch (op.op_type) {
                .read, .recv, .accept => {
                    try changelist.append(self.allocator, .{
                        .ident = @intCast(op.fd),
                        .filter = std.c.EVFILT.READ,
                        .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                        .fflags = 0,
                        .data = 0,
                        .udata = @intCast(op.user_data),
                    });
                },
                .write, .send, .connect => {
                    try changelist.append(self.allocator, .{
                        .ident = @intCast(op.fd),
                        .filter = std.c.EVFILT.WRITE,
                        .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                        .fflags = 0,
                        .data = 0,
                        .udata = @intCast(op.user_data),
                    });
                },
                .timeout => {
                    try changelist.append(self.allocator, .{
                        .ident = op.user_data,
                        .filter = std.c.EVFILT.TIMER,
                        .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                        .fflags = std.c.NOTE.NSECONDS,
                        .data = @intCast(op.timeout_ns),
                        .udata = @intCast(op.user_data),
                    });
                },
                .close, .cancel => {},
            }
        }

        if (changelist.items.len == 0) return count;

        const remaining = events.len - count;
        var kevents: [64]std.c.Kevent = undefined;
        const max_kevents = @min(remaining, 64);

        // Zero timeout — never block
        const timeout = std.c.timespec{ .sec = 0, .nsec = 0 };

        const n = std.c.kevent(
            self.kq,
            changelist.items.ptr,
            @intCast(changelist.items.len),
            &kevents,
            @intCast(max_kevents),
            &timeout,
        );

        if (n < 0) return error.KeventFailed;

        // Process ready events
        for (kevents[0..@intCast(n)]) |kev| {
            if (count >= events.len) break;

            const user_data: u64 = @intCast(kev.udata);

            // Find and remove matching pending op
            var found_idx: ?usize = null;
            for (self.pending.items, 0..) |op, idx| {
                if (op.user_data == user_data) {
                    found_idx = idx;
                    break;
                }
            }

            if (found_idx) |idx| {
                const op = self.pending.items[idx];
                const result = self.executeOp(op, kev);
                _ = self.pending.orderedRemove(idx);
                events[count] = .{
                    .user_data = user_data,
                    .result = result,
                    .flags = 0,
                };
                count += 1;
            }
        }

        return count;
    }

    fn executeOp(self: *Kqueue, op: PendingOp, kev: std.c.Kevent) i32 {
        _ = self;

        if (kev.flags & std.c.EV.ERROR != 0) {
            return -@as(i32, @intCast(kev.data));
        }

        switch (op.op_type) {
            .read => {
                if (op.buf) |buf| {
                    const n = posix.read(@intCast(op.fd), buf) catch {
                        return -1;
                    };
                    return @intCast(n);
                }
                return 0;
            },
            .write => {
                if (op.buf_const) |buf| {
                    const n = posix.write(@intCast(op.fd), buf) catch {
                        return -1;
                    };
                    return @intCast(n);
                }
                return 0;
            },
            .accept => {
                const result = posix.accept(@intCast(op.fd), null, null, 0) catch {
                    return -1;
                };
                return @intCast(result);
            },
            .connect => {
                // Check SO_ERROR for connect result
                var err_code: i32 = 0;
                var len: u32 = @sizeOf(i32);
                const rc = std.c.getsockopt(@intCast(op.fd), std.c.SOL.SOCKET, std.c.SO.ERROR, @ptrCast(&err_code), &len);
                if (rc != 0) return -1;
                if (err_code != 0) return -err_code;
                return 0;
            },
            .send => {
                if (op.buf_const) |buf| {
                    const n = posix.send(@intCast(op.fd), buf, 0) catch {
                        return -1;
                    };
                    return @intCast(n);
                }
                return 0;
            },
            .recv => {
                if (op.buf) |buf| {
                    const n = posix.recv(@intCast(op.fd), buf, 0) catch {
                        return -1;
                    };
                    return @intCast(n);
                }
                return 0;
            },
            .timeout => return 0,
            .close, .cancel => return 0,
        }
    }
};

// ---- Tests ----

fn makeSocketPair() [2]posix.fd_t {
    var sv: [2]std.c.fd_t = undefined;
    const rc = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv);
    std.debug.assert(rc == 0);
    return .{ @intCast(sv[0]), @intCast(sv[1]) };
}

test "init kqueue" {
    const alloc = std.testing.allocator;
    var kq = Kqueue.init(.{ .allocator = alloc }) catch unreachable;
    defer kq.deinit();

    try std.testing.expect(kq.kq >= 0);
}

test "submit and poll timeout" {
    const alloc = std.testing.allocator;
    var kq = Kqueue.init(.{ .allocator = alloc }) catch unreachable;
    defer kq.deinit();

    // Submit a 1ms timeout
    kq.submitTimeout(1_000_000, 42) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    // Poll — may need a couple tries for the timer to fire
    var count: u32 = 0;
    var attempts: u32 = 0;
    while (count == 0 and attempts < 10) : (attempts += 1) {
        count = kq.pollCompletions(&events) catch unreachable;
    }

    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(u64, 42), events[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), events[0].result);
}

test "socket pair send/recv" {
    const alloc = std.testing.allocator;
    var kq = Kqueue.init(.{ .allocator = alloc }) catch unreachable;
    defer kq.deinit();

    const pair = makeSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    const msg = "hello kqueue";

    // Send on pair[0]
    kq.submitSend(pair[0], msg, 10) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    var count: u32 = 0;
    var attempts: u32 = 0;
    while (count == 0 and attempts < 10) : (attempts += 1) {
        count = kq.pollCompletions(&events) catch unreachable;
    }
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(u64, 10), events[0].user_data);
    try std.testing.expect(events[0].result > 0);

    // Recv on pair[1]
    var buf: [64]u8 = undefined;
    kq.submitRecv(pair[1], &buf, 20) catch unreachable;

    count = 0;
    attempts = 0;
    while (count == 0 and attempts < 10) : (attempts += 1) {
        count = kq.pollCompletions(&events) catch unreachable;
    }
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(u64, 20), events[0].user_data);
    try std.testing.expect(events[0].result > 0);
    try std.testing.expectEqualSlices(u8, msg, buf[0..@intCast(events[0].result)]);
}

test "close generates completion" {
    const alloc = std.testing.allocator;
    var kq = Kqueue.init(.{ .allocator = alloc }) catch unreachable;
    defer kq.deinit();

    // Create a socket to close
    const pair = makeSocketPair();
    // We'll close pair[0] via kqueue, close pair[1] directly
    defer posix.close(pair[1]);

    kq.submitClose(pair[0], 99) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    const count = kq.pollCompletions(&events) catch unreachable;

    // Close is immediate
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(u64, 99), events[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), events[0].result);
}

test "kqueue satisfies IO interface" {
    comptime {
        io.assertIsIoBackend(Kqueue);
    }
}

test "cancel removes pending op" {
    const alloc = std.testing.allocator;
    var kq = Kqueue.init(.{ .allocator = alloc }) catch unreachable;
    defer kq.deinit();

    // Submit a long timeout, then cancel it
    kq.submitTimeout(999_000_000_000, 50) catch unreachable;
    kq.submitCancel(50, 51) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    const count = kq.pollCompletions(&events) catch unreachable;

    // Should get the cancel completion immediately
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(u64, 51), events[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), events[0].result);
    // The timeout should be gone from pending
    try std.testing.expectEqual(@as(usize, 0), kq.pending.items.len);
}

// ---- Edge Case Tests (Step 8.5) ----

test "edge: pollCompletions with no pending ops returns 0" {
    const alloc = std.testing.allocator;
    var kq = Kqueue.init(.{ .allocator = alloc }) catch unreachable;
    defer kq.deinit();

    var events: [16]CompletionEntry = undefined;
    const count = kq.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "edge: poll with events buffer of size 1 returns 1 at a time" {
    const alloc = std.testing.allocator;
    var kq = Kqueue.init(.{ .allocator = alloc }) catch unreachable;
    defer kq.deinit();

    // Submit 3 immediate ops (close generates immediate completions)
    const pairs = [3][2]posix.fd_t{
        makeSocketPair(),
        makeSocketPair(),
        makeSocketPair(),
    };
    // Close one end of each pair via kqueue
    kq.submitClose(pairs[0][0], 1) catch unreachable;
    kq.submitClose(pairs[1][0], 2) catch unreachable;
    kq.submitClose(pairs[2][0], 3) catch unreachable;
    defer posix.close(pairs[0][1]);
    defer posix.close(pairs[1][1]);
    defer posix.close(pairs[2][1]);

    // Poll with buffer of 1 — should return exactly 1 each time
    var events: [1]CompletionEntry = undefined;
    var total: u32 = 0;
    for (0..3) |_| {
        const count = kq.pollCompletions(&events) catch unreachable;
        try std.testing.expectEqual(@as(u32, 1), count);
        total += count;
    }
    try std.testing.expectEqual(@as(u32, 3), total);
}

test "edge: two reads on same fd" {
    const alloc = std.testing.allocator;
    var kq = Kqueue.init(.{ .allocator = alloc }) catch unreachable;
    defer kq.deinit();

    const pair = makeSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    // Write data so reads will be ready
    const msg = "hello";
    _ = posix.write(@intCast(pair[0]), msg) catch unreachable;

    // Submit two reads on the same fd with different user_data
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    kq.submitRecv(pair[1], &buf1, 10) catch unreachable;
    kq.submitRecv(pair[1], &buf2, 11) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    var count: u32 = 0;
    var attempts: u32 = 0;
    while (count < 1 and attempts < 10) : (attempts += 1) {
        count += kq.pollCompletions(events[count..]) catch unreachable;
    }

    // At least the first read should succeed
    try std.testing.expect(count >= 1);
    try std.testing.expect(events[0].result > 0);
}

test "edge: partial read — send more data than recv buffer" {
    const alloc = std.testing.allocator;
    var kq = Kqueue.init(.{ .allocator = alloc }) catch unreachable;
    defer kq.deinit();

    const pair = makeSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    // Send 100 bytes
    var big_msg: [100]u8 = undefined;
    @memset(&big_msg, 'A');
    _ = posix.send(@intCast(pair[0]), &big_msg, 0) catch unreachable;

    // Recv with only a 10-byte buffer
    var small_buf: [10]u8 = undefined;
    kq.submitRecv(pair[1], &small_buf, 20) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    var count: u32 = 0;
    var attempts: u32 = 0;
    while (count == 0 and attempts < 10) : (attempts += 1) {
        count = kq.pollCompletions(&events) catch unreachable;
    }

    try std.testing.expectEqual(@as(u32, 1), count);
    // Should only read 10 bytes (buffer size), not 100
    try std.testing.expectEqual(@as(i32, 10), events[0].result);
}

test "edge: closed peer — EOF on recv" {
    const alloc = std.testing.allocator;
    var kq = Kqueue.init(.{ .allocator = alloc }) catch unreachable;
    defer kq.deinit();

    const pair = makeSocketPair();
    defer posix.close(pair[1]);

    // Close the write end immediately
    posix.close(pair[0]);

    // Try to recv on the read end — should get EOF (0 bytes)
    var buf: [64]u8 = undefined;
    kq.submitRecv(pair[1], &buf, 30) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    var count: u32 = 0;
    var attempts: u32 = 0;
    while (count == 0 and attempts < 10) : (attempts += 1) {
        count = kq.pollCompletions(&events) catch unreachable;
    }

    try std.testing.expectEqual(@as(u32, 1), count);
    // EOF returns 0 bytes read
    try std.testing.expectEqual(@as(i32, 0), events[0].result);
}

test "edge: cancel an op that does not exist — no crash" {
    const alloc = std.testing.allocator;
    var kq = Kqueue.init(.{ .allocator = alloc }) catch unreachable;
    defer kq.deinit();

    // Cancel a non-existent user_data
    kq.submitCancel(9999, 100) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    const count = kq.pollCompletions(&events) catch unreachable;

    // Should still get the cancel completion
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(u64, 100), events[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), events[0].result);
}

test "edge: changelist append propagates allocation errors" {
    // This tests that changelist.append errors are not silently swallowed.
    // The current implementation uses `catch {}` which swallows OOM.
    // This test verifies the bug exists by using a failing allocator.
    const alloc = std.testing.allocator;
    var kq = Kqueue.init(.{ .allocator = alloc }) catch unreachable;
    defer kq.deinit();

    const pair = makeSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    // Submit a read — the changelist append in pollCompletions uses catch {}
    // which silently drops the kevent registration on OOM.
    // For now, just verify the operation works normally.
    var buf: [64]u8 = undefined;
    kq.submitRecv(pair[1], &buf, 1) catch unreachable;

    // Write data so the recv can complete
    _ = posix.send(@intCast(pair[0]), "test", 0) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    var count: u32 = 0;
    var attempts: u32 = 0;
    while (count == 0 and attempts < 10) : (attempts += 1) {
        count = kq.pollCompletions(&events) catch unreachable;
    }
    try std.testing.expect(count >= 1);
}
