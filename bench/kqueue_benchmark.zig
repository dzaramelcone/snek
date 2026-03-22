//! Benchmark: kqueue I/O primitives on macOS
//!
//! Measures the kernel floor for socket I/O operations that our kqueue adapter builds on.
//! Scenario 0: Raw socketpair send/recv throughput (kernel baseline)
//! Scenario 1: Kqueue adapter overhead (submitSend + submitRecv + pollCompletions) vs raw kevent
//! Scenario 2: Throughput scaling with batch size (10, 50, 100, 500 pending ops)
//! Scenario 3: Timeout precision (1ms timer jitter, median and p99)
//!
//! Run: zig build-exe -OReleaseFast bench/kqueue_benchmark.zig -femit-bin=bench/kqueue_benchmark && ./bench/kqueue_benchmark

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

// ── Inlined Kqueue adapter (from src/core/kqueue.zig) ────────────────

const CompletionEntry = struct {
    user_data: u64,
    result: i32,
    flags: u32,
};

const OpType = enum { read, write, accept, connect, close, send, recv, timeout, cancel };

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

const Kqueue = struct {
    kq: i32,
    pending: std.ArrayList(PendingOp),
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
                    changelist.append(self.allocator, .{
                        .ident = @intCast(op.fd),
                        .filter = std.c.EVFILT.READ,
                        .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                        .fflags = 0,
                        .data = 0,
                        .udata = @intCast(op.user_data),
                    }) catch unreachable;
                },
                .write, .send, .connect => {
                    changelist.append(self.allocator, .{
                        .ident = @intCast(op.fd),
                        .filter = std.c.EVFILT.WRITE,
                        .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                        .fflags = 0,
                        .data = 0,
                        .udata = @intCast(op.user_data),
                    }) catch unreachable;
                },
                .timeout => {
                    changelist.append(self.allocator, .{
                        .ident = op.user_data,
                        .filter = std.c.EVFILT.TIMER,
                        .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                        .fflags = std.c.NOTE.NSECONDS,
                        .data = @intCast(op.timeout_ns),
                        .udata = @intCast(op.user_data),
                    }) catch unreachable;
                },
                .close, .cancel => {},
            }
        }

        if (changelist.items.len == 0) return count;

        const remaining = events.len - count;
        var kevents: [256]std.c.Kevent = undefined;
        const max_kevents = @min(remaining, 256);

        const timeout = std.c.timespec{ .sec = 0, .nsec = 100_000_000 }; // 100ms max wait

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

    fn executeOp(op: PendingOp, kev: std.c.Kevent) i32 {
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

// ── Scenario 0: Raw socketpair send/recv throughput ──────────────────

const SCENARIO_0_ITERS = 100_000;
const WARMUP = 1_000;

fn benchRawSocketpair() u64 {
    const pair = makeSocketPair();
    defer closeSocketPair(pair);

    const msg = "hello snek!"; // 11 bytes
    var recv_buf: [64]u8 = undefined;

    // Warmup
    for (0..WARMUP) |_| {
        _ = posix.send(@intCast(pair[0]), msg, 0) catch unreachable;
        const n = posix.recv(@intCast(pair[1]), &recv_buf, 0) catch unreachable;
        std.mem.doNotOptimizeAway(&n);
    }

    var timer = std.time.Timer.start() catch unreachable;

    for (0..SCENARIO_0_ITERS) |_| {
        _ = posix.send(@intCast(pair[0]), msg, 0) catch unreachable;
        const n = posix.recv(@intCast(pair[1]), &recv_buf, 0) catch unreachable;
        std.mem.doNotOptimizeAway(&n);
    }

    return timer.read();
}

// ── Scenario 1: Adapter overhead — kqueue adapter vs raw kevent ──────

const SCENARIO_1_ITERS = 100_000;

fn benchKqueueAdapter() u64 {
    const pair = makeSocketPair();
    defer closeSocketPair(pair);

    const msg = "hello snek!";
    var recv_buf: [64]u8 = undefined;
    var events: [16]CompletionEntry = undefined;

    var kq = Kqueue.init(std.heap.page_allocator) catch unreachable;
    defer kq.deinit();

    // Warmup
    for (0..WARMUP) |i| {
        kq.submitSend(pair[0], msg, i * 2) catch unreachable;
        var count: u32 = 0;
        while (count == 0) {
            count = kq.pollCompletions(&events) catch unreachable;
        }
        kq.submitRecv(pair[1], &recv_buf, i * 2 + 1) catch unreachable;
        count = 0;
        while (count == 0) {
            count = kq.pollCompletions(&events) catch unreachable;
        }
    }

    var timer = std.time.Timer.start() catch unreachable;

    for (0..SCENARIO_1_ITERS) |i| {
        const base = (WARMUP + i) * 2;
        kq.submitSend(pair[0], msg, base) catch unreachable;
        var count: u32 = 0;
        while (count == 0) {
            count = kq.pollCompletions(&events) catch unreachable;
        }
        kq.submitRecv(pair[1], &recv_buf, base + 1) catch unreachable;
        count = 0;
        while (count == 0) {
            count = kq.pollCompletions(&events) catch unreachable;
        }
    }

    return timer.read();
}

fn benchRawKevent() u64 {
    const pair = makeSocketPair();
    defer closeSocketPair(pair);

    const msg = "hello snek!";
    var recv_buf: [64]u8 = undefined;

    const kq = blk: {
        const ret = std.c.kqueue();
        std.debug.assert(ret != -1);
        break :blk @as(i32, @intCast(ret));
    };
    defer posix.close(@intCast(kq));

    // Warmup
    for (0..WARMUP) |_| {
        var changelist = [1]std.c.Kevent{.{
            .ident = @intCast(pair[0]),
            .filter = std.c.EVFILT.WRITE,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        var result_events: [1]std.c.Kevent = undefined;
        var n = std.c.kevent(kq, &changelist, 1, &result_events, 1, null);
        std.debug.assert(n == 1);
        _ = posix.send(@intCast(pair[0]), msg, 0) catch unreachable;

        changelist[0] = .{
            .ident = @intCast(pair[1]),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        n = std.c.kevent(kq, &changelist, 1, &result_events, 1, null);
        std.debug.assert(n == 1);
        const nr = posix.recv(@intCast(pair[1]), &recv_buf, 0) catch unreachable;
        std.mem.doNotOptimizeAway(&nr);
    }

    var timer = std.time.Timer.start() catch unreachable;

    for (0..SCENARIO_1_ITERS) |_| {
        // Register write readiness, wait, then send
        var changelist = [1]std.c.Kevent{.{
            .ident = @intCast(pair[0]),
            .filter = std.c.EVFILT.WRITE,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        var result_events: [1]std.c.Kevent = undefined;
        var n = std.c.kevent(kq, &changelist, 1, &result_events, 1, null);
        std.debug.assert(n == 1);
        _ = posix.send(@intCast(pair[0]), msg, 0) catch unreachable;

        // Register read readiness, wait, then recv
        changelist[0] = .{
            .ident = @intCast(pair[1]),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        n = std.c.kevent(kq, &changelist, 1, &result_events, 1, null);
        std.debug.assert(n == 1);
        const nr = posix.recv(@intCast(pair[1]), &recv_buf, 0) catch unreachable;
        std.mem.doNotOptimizeAway(&nr);
    }

    return timer.read();
}

// ── Scenario 2: Throughput scaling with batch size ────────────────────

fn benchBatchThroughput(comptime batch_size: u32) u64 {
    // Create batch_size socket pairs
    var pairs: [batch_size][2]posix.fd_t = undefined;
    for (0..batch_size) |i| {
        pairs[i] = makeSocketPair();
    }
    defer {
        for (0..batch_size) |i| {
            closeSocketPair(pairs[i]);
        }
    }

    var kq = Kqueue.init(std.heap.page_allocator) catch unreachable;
    defer kq.deinit();

    const msg = "batch test!";
    const iterations: u32 = 10_000 / batch_size + 1;

    // Warmup: one full batch cycle
    for (0..batch_size) |i| {
        kq.submitSend(pairs[i][0], msg, @intCast(i)) catch unreachable;
    }
    var events: [512]CompletionEntry = undefined;
    var completed: u32 = 0;
    while (completed < batch_size) {
        completed += kq.pollCompletions(events[0..]) catch unreachable;
    }
    // Recv all
    var recv_buf: [64]u8 = undefined;
    for (0..batch_size) |i| {
        _ = posix.recv(@intCast(pairs[i][1]), &recv_buf, 0) catch unreachable;
    }

    var timer = std.time.Timer.start() catch unreachable;

    for (0..iterations) |iter| {
        // Submit batch_size sends
        for (0..batch_size) |i| {
            kq.submitSend(pairs[i][0], msg, @intCast(iter * batch_size + i)) catch unreachable;
        }
        // Poll all completions
        completed = 0;
        while (completed < batch_size) {
            completed += kq.pollCompletions(events[0..]) catch unreachable;
        }
        // Drain recv side so buffers don't fill
        for (0..batch_size) |i| {
            _ = posix.recv(@intCast(pairs[i][1]), &recv_buf, 0) catch unreachable;
        }
    }

    const total_ns = timer.read();
    return total_ns / iterations;
}

// ── Scenario 3: Timeout precision ────────────────────────────────────

const TIMEOUT_ITERS = 1_000;
const TARGET_TIMEOUT_NS: u64 = 1_000_000; // 1ms

fn benchTimeoutPrecision() struct { median_ns: u64, p99_ns: u64 } {
    var kq = Kqueue.init(std.heap.page_allocator) catch unreachable;
    defer kq.deinit();

    var latencies: [TIMEOUT_ITERS]u64 = undefined;
    var events: [16]CompletionEntry = undefined;

    for (0..TIMEOUT_ITERS) |i| {
        var timer = std.time.Timer.start() catch unreachable;

        kq.submitTimeout(TARGET_TIMEOUT_NS, @intCast(i)) catch unreachable;

        var count: u32 = 0;
        while (count == 0) {
            count = kq.pollCompletions(&events) catch unreachable;
        }

        latencies[i] = timer.read();
    }

    // Sort for percentiles
    std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));

    return .{
        .median_ns = latencies[TIMEOUT_ITERS / 2],
        .p99_ns = latencies[TIMEOUT_ITERS * 99 / 100],
    };
}

// ── Summary storage ──────────────────────────────────────────────────

const Results = struct {
    raw_socketpair_ns: u64,
    adapter_ns: u64,
    raw_kevent_ns: u64,
    batch_10_ns: u64,
    batch_50_ns: u64,
    batch_100_ns: u64,
    batch_500_ns: u64,
    timeout_median_ns: u64,
    timeout_p99_ns: u64,
};

// ── Main ─────────────────────────────────────────────────────────────

pub fn main() !void {
    std.debug.print("=== Kqueue Benchmark (macOS) ===\n", .{});
    std.debug.print("  Platform: macOS/Darwin, kqueue backend\n", .{});
    std.debug.print("  Message size: 11 bytes\n\n", .{});

    var best: Results = .{
        .raw_socketpair_ns = std.math.maxInt(u64),
        .adapter_ns = std.math.maxInt(u64),
        .raw_kevent_ns = std.math.maxInt(u64),
        .batch_10_ns = std.math.maxInt(u64),
        .batch_50_ns = std.math.maxInt(u64),
        .batch_100_ns = std.math.maxInt(u64),
        .batch_500_ns = std.math.maxInt(u64),
        .timeout_median_ns = std.math.maxInt(u64),
        .timeout_p99_ns = std.math.maxInt(u64),
    };

    for (0..3) |run| {
        std.debug.print("--- Run {d} ---\n", .{run + 1});

        // Scenario 0
        std.debug.print("  Scenario 0: Raw socketpair send/recv ({d} iters)\n", .{SCENARIO_0_ITERS});
        const raw_ns = benchRawSocketpair();
        std.debug.print("    Raw send/recv:              {d:>8.1} ns/op\n", .{nsPerOp(raw_ns, SCENARIO_0_ITERS)});
        best.raw_socketpair_ns = @min(best.raw_socketpair_ns, raw_ns);

        // Scenario 1
        std.debug.print("  Scenario 1: Adapter overhead ({d} iters)\n", .{SCENARIO_1_ITERS});
        const adapter_ns = benchKqueueAdapter();
        std.debug.print("    Kqueue adapter (submit+poll): {d:>8.1} ns/op\n", .{nsPerOp(adapter_ns, SCENARIO_1_ITERS)});
        best.adapter_ns = @min(best.adapter_ns, adapter_ns);

        const raw_kev_ns = benchRawKevent();
        std.debug.print("    Raw kevent:                   {d:>8.1} ns/op\n", .{nsPerOp(raw_kev_ns, SCENARIO_1_ITERS)});
        best.raw_kevent_ns = @min(best.raw_kevent_ns, raw_kev_ns);

        // Scenario 2
        std.debug.print("  Scenario 2: Batch throughput scaling\n", .{});
        const b10 = benchBatchThroughput(10);
        std.debug.print("    N=10:   {d:>10.1} ns/batch\n", .{@as(f64, @floatFromInt(b10))});
        best.batch_10_ns = @min(best.batch_10_ns, b10);

        const b50 = benchBatchThroughput(50);
        std.debug.print("    N=50:   {d:>10.1} ns/batch\n", .{@as(f64, @floatFromInt(b50))});
        best.batch_50_ns = @min(best.batch_50_ns, b50);

        const b100 = benchBatchThroughput(100);
        std.debug.print("    N=100:  {d:>10.1} ns/batch\n", .{@as(f64, @floatFromInt(b100))});
        best.batch_100_ns = @min(best.batch_100_ns, b100);

        const b500 = benchBatchThroughput(500);
        std.debug.print("    N=500:  {d:>10.1} ns/batch\n", .{@as(f64, @floatFromInt(b500))});
        best.batch_500_ns = @min(best.batch_500_ns, b500);

        // Scenario 3
        std.debug.print("  Scenario 3: Timeout precision (1ms target, {d} iters)\n", .{TIMEOUT_ITERS});
        const timeout = benchTimeoutPrecision();
        std.debug.print("    Median: {d:>8.1} us (target: 1000.0 us)\n", .{@as(f64, @floatFromInt(timeout.median_ns)) / 1000.0});
        std.debug.print("    P99:    {d:>8.1} us\n", .{@as(f64, @floatFromInt(timeout.p99_ns)) / 1000.0});
        best.timeout_median_ns = @min(best.timeout_median_ns, timeout.median_ns);
        best.timeout_p99_ns = @min(best.timeout_p99_ns, timeout.p99_ns);

        std.debug.print("\n", .{});
    }

    // ── Summary ──────────────────────────────────────────────────────
    std.debug.print("=== SUMMARY (best of 3 runs) ===\n\n", .{});

    std.debug.print("  Scenario 0 — Raw socketpair throughput (kernel floor):\n", .{});
    std.debug.print("    {d:.1} ns/op ({d} round-trips)\n\n", .{
        nsPerOp(best.raw_socketpair_ns, SCENARIO_0_ITERS),
        SCENARIO_0_ITERS,
    });

    std.debug.print("  Scenario 1 — Adapter overhead:\n", .{});
    const adapter_per_op = nsPerOp(best.adapter_ns, SCENARIO_1_ITERS);
    const raw_kev_per_op = nsPerOp(best.raw_kevent_ns, SCENARIO_1_ITERS);
    const raw_per_op = nsPerOp(best.raw_socketpair_ns, SCENARIO_0_ITERS);
    std.debug.print("    Kqueue adapter:  {d:>8.1} ns/op\n", .{adapter_per_op});
    std.debug.print("    Raw kevent:      {d:>8.1} ns/op\n", .{raw_kev_per_op});
    std.debug.print("    Raw send/recv:   {d:>8.1} ns/op (no kevent, kernel floor)\n", .{raw_per_op});
    if (raw_kev_per_op > 0) {
        std.debug.print("    Adapter/Raw kevent ratio: {d:.2}x\n", .{adapter_per_op / raw_kev_per_op});
    }
    if (raw_per_op > 0) {
        std.debug.print("    Kevent overhead vs kernel floor: {d:.1} ns/op\n", .{raw_kev_per_op - raw_per_op});
    }

    std.debug.print("\n  Scenario 2 — Batch throughput scaling:\n", .{});
    std.debug.print("    N=10:   {d:>10.1} ns/batch  ({d:.1} ns/op)\n", .{ @as(f64, @floatFromInt(best.batch_10_ns)), @as(f64, @floatFromInt(best.batch_10_ns)) / 10.0 });
    std.debug.print("    N=50:   {d:>10.1} ns/batch  ({d:.1} ns/op)\n", .{ @as(f64, @floatFromInt(best.batch_50_ns)), @as(f64, @floatFromInt(best.batch_50_ns)) / 50.0 });
    std.debug.print("    N=100:  {d:>10.1} ns/batch  ({d:.1} ns/op)\n", .{ @as(f64, @floatFromInt(best.batch_100_ns)), @as(f64, @floatFromInt(best.batch_100_ns)) / 100.0 });
    std.debug.print("    N=500:  {d:>10.1} ns/batch  ({d:.1} ns/op)\n", .{ @as(f64, @floatFromInt(best.batch_500_ns)), @as(f64, @floatFromInt(best.batch_500_ns)) / 500.0 });
    // Scaling factor: compare per-op cost at N=500 vs N=10
    const per_op_10 = @as(f64, @floatFromInt(best.batch_10_ns)) / 10.0;
    const per_op_500 = @as(f64, @floatFromInt(best.batch_500_ns)) / 500.0;
    if (per_op_10 > 0) {
        std.debug.print("    Scaling efficiency (N=500 vs N=10): {d:.2}x per-op cost\n", .{per_op_500 / per_op_10});
    }

    std.debug.print("\n  Scenario 3 — Timeout precision (1ms target):\n", .{});
    const median_us = @as(f64, @floatFromInt(best.timeout_median_ns)) / 1000.0;
    const p99_us = @as(f64, @floatFromInt(best.timeout_p99_ns)) / 1000.0;
    std.debug.print("    Median:  {d:>8.1} us\n", .{median_us});
    std.debug.print("    P99:     {d:>8.1} us\n", .{p99_us});
    std.debug.print("    Jitter (p99 - median): {d:.1} us\n", .{p99_us - median_us});
    std.debug.print("    Overshoot (median - target): {d:.1} us\n", .{median_us - 1000.0});
}
