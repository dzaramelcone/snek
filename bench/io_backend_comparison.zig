//! Benchmark: Kqueue adapter vs FakeIO backend comparison
//!
//! Measures adapter overhead vs the zero-overhead FakeIO baseline.
//! Since io_uring requires Linux, this runs kqueue + FakeIO on macOS.
//! For io_uring comparison, run in Docker (see note below).
//!
//! Scenario 1: Submit+poll cycle — socketpair send/recv (kqueue) vs fake submit+poll (FakeIO)
//! Scenario 2: Multiple outstanding ops — submit 10, poll all
//! Scenario 3: Timeout — real wait (kqueue) vs advance time (FakeIO)
//!
//! Run: zig build-exe -OReleaseFast bench/io_backend_comparison.zig -femit-bin=bench/io_backend_comparison && ./bench/io_backend_comparison

const std = @import("std");
const posix = std.posix;

// ── Helpers ──────────────────────────────────────────────────────────

fn makeSocketPair() [2]posix.fd_t {
    var sv: [2]std.c.fd_t = undefined;
    const rc = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv);
    std.debug.assert(rc == 0);
    return .{ @intCast(sv[0]), @intCast(sv[1]) };
}

fn closeSocketPair(pair: [2]posix.fd_t) void {
    posix.close(pair[0]);
    posix.close(pair[1]);
}

fn nsPerOp(total_ns: u64, ops: u64) f64 {
    return @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(ops));
}

// ── Inlined CompletionEntry ──────────────────────────────────────────

const CompletionEntry = struct {
    user_data: u64,
    result: i32,
    flags: u32,
};

// ── Inlined legacy kqueue adapter ────────────────────────────────────

const KqOpType = enum { read, write, accept, connect, close, send, recv, timeout, cancel };

const KqPendingOp = struct {
    op_type: KqOpType,
    fd: i32,
    user_data: u64,
    buf: ?[]u8,
    buf_const: ?[]const u8,
    offset: u64,
    timeout_ns: u64,
    addr: ?[]const u8,
    port: u16,
};

const Kqueue = struct {
    kq: i32,
    pending: std.ArrayList(KqPendingOp),
    immediate: std.ArrayList(CompletionEntry),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Kqueue {
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

    fn deinit(self: *Kqueue) void {
        posix.close(@intCast(self.kq));
        self.pending.deinit(self.allocator);
        self.immediate.deinit(self.allocator);
    }

    fn submitSend(self: *Kqueue, fd: i32, buf: []const u8, user_data: u64) !void {
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

    fn submitRecv(self: *Kqueue, fd: i32, buf: []u8, user_data: u64) !void {
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

    fn submitTimeout(self: *Kqueue, timeout_ns: u64, user_data: u64) !void {
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

    fn pollCompletions(self: *Kqueue, events: []CompletionEntry) !u32 {
        var count: u32 = 0;

        while (self.immediate.items.len > 0 and count < events.len) {
            events[count] = self.immediate.orderedRemove(0);
            count += 1;
        }
        if (count >= events.len) return count;

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
        var kevents: [256]std.c.Kevent = undefined;
        const max_kevents = @min(remaining, 256);

        const timeout = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };

        const n = std.c.kevent(
            self.kq,
            changelist.items.ptr,
            @intCast(changelist.items.len),
            &kevents,
            @intCast(max_kevents),
            &timeout,
        );

        if (n < 0) return error.KeventFailed;

        for (kevents[0..@intCast(n)]) |kev| {
            if (count >= events.len) break;

            const user_data: u64 = @intCast(kev.udata);

            var found_idx: ?usize = null;
            for (self.pending.items, 0..) |op, idx| {
                if (op.user_data == user_data) {
                    found_idx = idx;
                    break;
                }
            }

            if (found_idx) |idx| {
                const op = self.pending.items[idx];
                const result = executeOp(op, kev);
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

    fn executeOp(op: KqPendingOp, kev: std.c.Kevent) i32 {
        if (kev.flags & std.c.EV.ERROR != 0) {
            return -@as(i32, @intCast(kev.data));
        }

        switch (op.op_type) {
            .send => {
                if (op.buf_const) |buf| {
                    const n = posix.send(@intCast(op.fd), buf, 0) catch return -1;
                    return @intCast(n);
                }
                return 0;
            },
            .recv => {
                if (op.buf) |buf| {
                    const n = posix.recv(@intCast(op.fd), buf, 0) catch return -1;
                    return @intCast(n);
                }
                return 0;
            },
            .timeout => return 0,
            else => return 0,
        }
    }
};

// ── Inlined FakeIO (from src/core/fake_io.zig) ──────────────────────

const FakeIoOp = enum { read, write, accept, connect, close, send, recv, send_zc, timeout, cancel };

const FakePendingOp = struct {
    op_type: FakeIoOp,
    fd: i32,
    user_data: u64,
    deadline_ns: ?u64,
    buf: ?[]u8,
    buf_len: u32,
};

const FakeIO = struct {
    prng: std.Random.DefaultPrng,
    current_time_ns: u64,
    pending: std.ArrayList(FakePendingOp),
    next_fake_fd: i32,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, seed: u64) FakeIO {
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .current_time_ns = 0,
            .pending = .{},
            .next_fake_fd = 100,
            .allocator = allocator,
        };
    }

    fn deinit(self: *FakeIO) void {
        self.pending.deinit(self.allocator);
    }

    fn submitSend(self: *FakeIO, fd: i32, buf: []const u8, user_data: u64) !void {
        _ = buf;
        return self.pending.append(self.allocator, .{
            .op_type = .send,
            .fd = fd,
            .user_data = user_data,
            .deadline_ns = null,
            .buf = null,
            .buf_len = 0,
        });
    }

    fn submitRecv(self: *FakeIO, fd: i32, buf: []u8, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .recv,
            .fd = fd,
            .user_data = user_data,
            .deadline_ns = null,
            .buf = buf,
            .buf_len = @intCast(buf.len),
        });
    }

    fn submitTimeout(self: *FakeIO, timeout_ns: u64, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .timeout,
            .fd = -1,
            .user_data = user_data,
            .deadline_ns = self.current_time_ns + timeout_ns,
            .buf = null,
            .buf_len = 0,
        });
    }

    fn advanceTime(self: *FakeIO, ns: u64) void {
        self.current_time_ns +%= ns;
    }

    fn pollCompletions(self: *FakeIO, events: []CompletionEntry) !u32 {
        var count: u32 = 0;
        var i: usize = 0;

        while (i < self.pending.items.len and count < events.len) {
            const op = self.pending.items[i];

            if (op.op_type == .timeout) {
                if (op.deadline_ns) |deadline| {
                    if (self.current_time_ns < deadline) {
                        i += 1;
                        continue;
                    }
                }
            }

            _ = self.pending.orderedRemove(i);

            // Normal completion
            switch (op.op_type) {
                .recv => {
                    if (op.buf) |buf| {
                        self.prng.fill(buf[0..op.buf_len]);
                        events[count] = .{ .user_data = op.user_data, .result = @intCast(op.buf_len), .flags = 0 };
                    } else {
                        events[count] = .{ .user_data = op.user_data, .result = 0, .flags = 0 };
                    }
                },
                else => {
                    events[count] = .{ .user_data = op.user_data, .result = 0, .flags = 0 };
                },
            }
            count += 1;
        }
        return count;
    }
};

// ── Scenario 1: Submit+poll cycle ────────────────────────────────────

const SCENARIO_1_ITERS = 100_000;
const WARMUP = 1_000;

fn benchKqueueCycle() !u64 {
    const pair = makeSocketPair();
    defer closeSocketPair(pair);

    const msg = "hello snek!";
    var recv_buf: [64]u8 = undefined;
    var events: [16]CompletionEntry = undefined;

    var kq = try Kqueue.init(std.heap.page_allocator);
    defer kq.deinit();

    // Warmup
    for (0..WARMUP) |i| {
        try kq.submitSend(pair[0], msg, i * 2);
        var count: u32 = 0;
        while (count == 0) {
            count = try kq.pollCompletions(&events);
        }
        try kq.submitRecv(pair[1], &recv_buf, i * 2 + 1);
        count = 0;
        while (count == 0) {
            count = try kq.pollCompletions(&events);
        }
    }

    var timer = try std.time.Timer.start();

    for (0..SCENARIO_1_ITERS) |i| {
        const base = (WARMUP + i) * 2;
        try kq.submitSend(pair[0], msg, base);
        var count: u32 = 0;
        while (count == 0) {
            count = try kq.pollCompletions(&events);
        }
        try kq.submitRecv(pair[1], &recv_buf, base + 1);
        count = 0;
        while (count == 0) {
            count = try kq.pollCompletions(&events);
        }
    }

    return timer.read();
}

fn benchFakeIOCycle() !u64 {
    const msg = "hello snek!";
    var recv_buf: [64]u8 = undefined;
    var events: [16]CompletionEntry = undefined;

    var fio = FakeIO.init(std.heap.page_allocator, 42);
    defer fio.deinit();

    // Warmup
    for (0..WARMUP) |i| {
        try fio.submitSend(100, msg, i * 2);
        _ = try fio.pollCompletions(&events);
        try fio.submitRecv(101, &recv_buf, i * 2 + 1);
        _ = try fio.pollCompletions(&events);
    }

    var timer = try std.time.Timer.start();

    for (0..SCENARIO_1_ITERS) |i| {
        const base = (WARMUP + i) * 2;
        try fio.submitSend(100, msg, base);
        _ = try fio.pollCompletions(&events);
        try fio.submitRecv(101, &recv_buf, base + 1);
        _ = try fio.pollCompletions(&events);
    }

    return timer.read();
}

// ── Scenario 2: Multiple outstanding ops ─────────────────────────────

const SCENARIO_2_OPS = 10;
const SCENARIO_2_ITERS = 10_000;

fn benchKqueueMultiple() !u64 {
    // Create SCENARIO_2_OPS socket pairs
    var pairs: [SCENARIO_2_OPS][2]posix.fd_t = undefined;
    for (0..SCENARIO_2_OPS) |i| {
        pairs[i] = makeSocketPair();
    }
    defer {
        for (0..SCENARIO_2_OPS) |i| {
            closeSocketPair(pairs[i]);
        }
    }

    const msg = "batch ops!";
    var recv_buf: [64]u8 = undefined;
    var events: [64]CompletionEntry = undefined;

    var kq = try Kqueue.init(std.heap.page_allocator);
    defer kq.deinit();

    // Warmup
    for (0..SCENARIO_2_OPS) |i| {
        try kq.submitSend(pairs[i][0], msg, @intCast(i));
    }
    var completed: u32 = 0;
    while (completed < SCENARIO_2_OPS) {
        completed += try kq.pollCompletions(events[0..]);
    }
    for (0..SCENARIO_2_OPS) |i| {
        _ = try posix.recv(@intCast(pairs[i][1]), &recv_buf, 0);
    }

    var timer = try std.time.Timer.start();

    for (0..SCENARIO_2_ITERS) |iter| {
        // Submit SCENARIO_2_OPS sends
        for (0..SCENARIO_2_OPS) |i| {
            try kq.submitSend(pairs[i][0], msg, @intCast(iter * SCENARIO_2_OPS + i + 1000));
        }
        // Poll all completions
        completed = 0;
        while (completed < SCENARIO_2_OPS) {
            completed += try kq.pollCompletions(events[0..]);
        }
        // Drain recv side
        for (0..SCENARIO_2_OPS) |i| {
            _ = try posix.recv(@intCast(pairs[i][1]), &recv_buf, 0);
        }
    }

    return timer.read();
}

fn benchFakeIOMultiple() !u64 {
    const msg = "batch ops!";
    var recv_buf: [64]u8 = undefined;
    var events: [64]CompletionEntry = undefined;

    var fio = FakeIO.init(std.heap.page_allocator, 42);
    defer fio.deinit();

    // Warmup
    for (0..SCENARIO_2_OPS) |i| {
        try fio.submitSend(100, msg, @intCast(i));
    }
    _ = try fio.pollCompletions(events[0..]);

    var timer = try std.time.Timer.start();

    for (0..SCENARIO_2_ITERS) |iter| {
        for (0..SCENARIO_2_OPS) |i| {
            try fio.submitSend(@intCast(100 + i), msg, @intCast(iter * SCENARIO_2_OPS + i + 1000));
        }
        // Also submit recvs to match the kqueue workload shape
        for (0..SCENARIO_2_OPS) |i| {
            try fio.submitRecv(@intCast(200 + i), &recv_buf, @intCast(iter * SCENARIO_2_OPS + i + 2000));
        }
        var completed: u32 = 0;
        while (completed < SCENARIO_2_OPS * 2) {
            completed += try fio.pollCompletions(events[0..]);
        }
    }

    return timer.read();
}

// ── Scenario 3: Timeout ──────────────────────────────────────────────

const SCENARIO_3_ITERS = 10_000;
const TIMEOUT_NS: u64 = 1_000_000; // 1ms

fn benchKqueueTimeout() !u64 {
    var kq = try Kqueue.init(std.heap.page_allocator);
    defer kq.deinit();

    var events: [16]CompletionEntry = undefined;

    var timer = try std.time.Timer.start();

    for (0..SCENARIO_3_ITERS) |i| {
        try kq.submitTimeout(TIMEOUT_NS, @intCast(i));
        var count: u32 = 0;
        while (count == 0) {
            count = try kq.pollCompletions(&events);
        }
    }

    return timer.read();
}

fn benchFakeIOTimeout() !u64 {
    var fio = FakeIO.init(std.heap.page_allocator, 42);
    defer fio.deinit();

    var events: [16]CompletionEntry = undefined;

    var timer = try std.time.Timer.start();

    for (0..SCENARIO_3_ITERS) |i| {
        try fio.submitTimeout(TIMEOUT_NS, @intCast(i));
        fio.advanceTime(TIMEOUT_NS);
        _ = try fio.pollCompletions(&events);
    }

    return timer.read();
}

// ── Results ──────────────────────────────────────────────────────────

const Results = struct {
    kq_cycle_ns: u64,
    fake_cycle_ns: u64,
    kq_multi_ns: u64,
    fake_multi_ns: u64,
    kq_timeout_ns: u64,
    fake_timeout_ns: u64,
};

// ── Main ─────────────────────────────────────────────────────────────

pub fn main() !void {
    std.debug.print("=== IO Backend Comparison Benchmark ===\n", .{});
    std.debug.print("  Comparing: Kqueue adapter (real I/O) vs FakeIO (zero-overhead simulation)\n", .{});
    std.debug.print("  Platform: macOS/Darwin\n", .{});
    std.debug.print("\n  NOTE: io_uring comparison requires Linux — run in Docker:\n", .{});
    std.debug.print("    docker run --rm --privileged -v $(pwd):/snek -w /snek alpine sh -c \\\n", .{});
    std.debug.print("      'apk add zig && zig build-exe -OReleaseFast bench/io_backend_comparison.zig && ./io_backend_comparison'\n\n", .{});

    var best: Results = .{
        .kq_cycle_ns = std.math.maxInt(u64),
        .fake_cycle_ns = std.math.maxInt(u64),
        .kq_multi_ns = std.math.maxInt(u64),
        .fake_multi_ns = std.math.maxInt(u64),
        .kq_timeout_ns = std.math.maxInt(u64),
        .fake_timeout_ns = std.math.maxInt(u64),
    };

    for (0..3) |run| {
        std.debug.print("--- Run {d} ---\n", .{run + 1});

        // Scenario 1
        std.debug.print("  Scenario 1: Submit+poll cycle ({d} send/recv round-trips)\n", .{SCENARIO_1_ITERS});
        const kq_cycle = try benchKqueueCycle();
        std.debug.print("    Kqueue adapter:  {d:>8.1} ns/op\n", .{nsPerOp(kq_cycle, SCENARIO_1_ITERS)});
        best.kq_cycle_ns = @min(best.kq_cycle_ns, kq_cycle);

        const fake_cycle = try benchFakeIOCycle();
        std.debug.print("    FakeIO:          {d:>8.1} ns/op\n", .{nsPerOp(fake_cycle, SCENARIO_1_ITERS)});
        best.fake_cycle_ns = @min(best.fake_cycle_ns, fake_cycle);

        // Scenario 2
        std.debug.print("  Scenario 2: Multiple outstanding ops ({d} ops x {d} iters)\n", .{ SCENARIO_2_OPS, SCENARIO_2_ITERS });
        const kq_multi = try benchKqueueMultiple();
        std.debug.print("    Kqueue adapter:  {d:>8.1} ns/op\n", .{nsPerOp(kq_multi, SCENARIO_2_ITERS)});
        best.kq_multi_ns = @min(best.kq_multi_ns, kq_multi);

        const fake_multi = try benchFakeIOMultiple();
        std.debug.print("    FakeIO:          {d:>8.1} ns/op\n", .{nsPerOp(fake_multi, SCENARIO_2_ITERS)});
        best.fake_multi_ns = @min(best.fake_multi_ns, fake_multi);

        // Scenario 3
        std.debug.print("  Scenario 3: Timeout submit+poll ({d} iters, 1ms each)\n", .{SCENARIO_3_ITERS});
        const kq_timeout = try benchKqueueTimeout();
        std.debug.print("    Kqueue adapter:  {d:>8.1} ns/op\n", .{nsPerOp(kq_timeout, SCENARIO_3_ITERS)});
        best.kq_timeout_ns = @min(best.kq_timeout_ns, kq_timeout);

        const fake_timeout = try benchFakeIOTimeout();
        std.debug.print("    FakeIO:          {d:>8.1} ns/op\n", .{nsPerOp(fake_timeout, SCENARIO_3_ITERS)});
        best.fake_timeout_ns = @min(best.fake_timeout_ns, fake_timeout);

        std.debug.print("\n", .{});
    }

    // ── Summary ──────────────────────────────────────────────────────
    std.debug.print("=== SUMMARY (best of 3 runs) ===\n\n", .{});

    const kq_cycle_per_op = nsPerOp(best.kq_cycle_ns, SCENARIO_1_ITERS);
    const fake_cycle_per_op = nsPerOp(best.fake_cycle_ns, SCENARIO_1_ITERS);
    std.debug.print("  Scenario 1 — Submit+poll send/recv cycle:\n", .{});
    std.debug.print("    Kqueue adapter:  {d:>10.1} ns/op\n", .{kq_cycle_per_op});
    std.debug.print("    FakeIO:          {d:>10.1} ns/op\n", .{fake_cycle_per_op});
    if (fake_cycle_per_op > 0) {
        std.debug.print("    Ratio (Kqueue/FakeIO): {d:.1}x\n", .{kq_cycle_per_op / fake_cycle_per_op});
    }

    const kq_multi_per_op = nsPerOp(best.kq_multi_ns, SCENARIO_2_ITERS);
    const fake_multi_per_op = nsPerOp(best.fake_multi_ns, SCENARIO_2_ITERS);
    std.debug.print("\n  Scenario 2 — Multiple outstanding ops ({d} per batch):\n", .{SCENARIO_2_OPS});
    std.debug.print("    Kqueue adapter:  {d:>10.1} ns/op\n", .{kq_multi_per_op});
    std.debug.print("    FakeIO:          {d:>10.1} ns/op\n", .{fake_multi_per_op});
    if (fake_multi_per_op > 0) {
        std.debug.print("    Ratio (Kqueue/FakeIO): {d:.1}x\n", .{kq_multi_per_op / fake_multi_per_op});
    }

    const kq_timeout_per_op = nsPerOp(best.kq_timeout_ns, SCENARIO_3_ITERS);
    const fake_timeout_per_op = nsPerOp(best.fake_timeout_ns, SCENARIO_3_ITERS);
    std.debug.print("\n  Scenario 3 — Timeout submit+poll:\n", .{});
    std.debug.print("    Kqueue adapter:  {d:>10.1} ns/op  (includes 1ms real wait)\n", .{kq_timeout_per_op});
    std.debug.print("    FakeIO:          {d:>10.1} ns/op  (simulated time, no real wait)\n", .{fake_timeout_per_op});
    if (fake_timeout_per_op > 0) {
        std.debug.print("    Ratio (Kqueue/FakeIO): {d:.1}x\n", .{kq_timeout_per_op / fake_timeout_per_op});
    }

    std.debug.print("\n  INTERPRETATION:\n", .{});
    std.debug.print("    FakeIO measures pure adapter overhead (no kernel, no real I/O).\n", .{});
    std.debug.print("    The Kqueue/FakeIO ratio shows how much time is spent in the kernel\n", .{});
    std.debug.print("    vs our adapter logic. Lower ratio = less adapter overhead.\n", .{});
    std.debug.print("    Timeout ratio is dominated by real 1ms waits (expected ~1M ns/op for Kqueue).\n", .{});
}
