//! Benchmark: io_uring I/O primitives on Linux
//!
//! Measures kernel floor and adapter overhead for socket I/O using io_uring.
//! Scenario 0: Raw socketpair send/recv throughput (kernel baseline)
//! Scenario 1: Raw std.os.linux.IoUring (stdlib direct)
//! Scenario 2: Our IoUring adapter overhead (inlined LinuxIoUring)
//! Scenario 3: Batch submission scaling (10, 50, 100 ops)
//! Scenario 4: io_uring read/write on pipe vs posix read/write
//!
//! Run: docker run --rm --privileged -v $PWD:/snek -w /snek alpine sh -c \
//!   "apk add --no-cache zig && zig build-exe -OReleaseFast bench/io_uring_benchmark.zig -femit-bin=/tmp/io_uring_bench && /tmp/io_uring_bench"

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

// ── Helpers ──────────────────────────────────────────────────────────

fn makeSocketPair() [2]posix.fd_t {
    var sv: [2]i32 = undefined;
    const rc = linux.socketpair(@intCast(linux.AF.UNIX), @intCast(linux.SOCK.STREAM), 0, &sv);
    std.debug.assert(rc == 0);
    return .{ sv[0], sv[1] };
}

fn closeSocketPair(pair: [2]posix.fd_t) void {
    posix.close(pair[0]);
    posix.close(pair[1]);
}

fn makePipe() [2]posix.fd_t {
    try return posix.pipe();
}

fn closePipe(pair: [2]posix.fd_t) void {
    posix.close(pair[0]);
    posix.close(pair[1]);
}

fn nsPerOp(total_ns: u64, ops: u64) f64 {
    return @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(ops));
}

// ── Inlined IoUring adapter (from src/core/io_uring.zig) ─────────────

const CompletionEntry = struct {
    user_data: u64,
    result: i32,
    flags: u32,
};

const LinuxIoUring = struct {
    ring: linux.IoUring,
    timeout_storage: [16]linux.kernel_timespec = undefined,
    timeout_count: u8 = 0,

    fn init(ring_size: u13) !LinuxIoUring {
        const ring = linux.IoUring.init(ring_size, 0) catch |err| {
            return err;
        };
        return .{ .ring = ring };
    }

    fn deinit(self: *LinuxIoUring) void {
        self.ring.deinit();
    }

    fn submitSend(self: *LinuxIoUring, fd: i32, buf: []const u8, user_data: u64) !void {
        _ = self.ring.send(user_data, fd, buf, 0) catch |err| {
            return err;
        };
    }

    fn submitRecv(self: *LinuxIoUring, fd: i32, buf: []u8, user_data: u64) !void {
        _ = self.ring.recv(user_data, fd, .{ .buffer = buf }, 0) catch |err| {
            return err;
        };
    }

    fn submitRead(self: *LinuxIoUring, fd: i32, buf: []u8, offset: u64, user_data: u64) !void {
        _ = self.ring.read(user_data, fd, .{ .buffer = buf }, offset) catch |err| {
            return err;
        };
    }

    fn submitWrite(self: *LinuxIoUring, fd: i32, buf: []const u8, offset: u64, user_data: u64) !void {
        _ = self.ring.write(user_data, fd, buf, offset) catch |err| {
            return err;
        };
    }

    fn pollCompletions(self: *LinuxIoUring, events: []CompletionEntry) !u32 {
        if (events.len == 0) return 0;
        const max_cqes = @min(events.len, 256);
        var cqe_buf: [256]linux.io_uring_cqe = undefined;
        const cqes = cqe_buf[0..max_cqes];

        _ = self.ring.submit() catch |err| {
            return err;
        };
        const count = self.ring.copy_cqes(cqes, 0) catch |err| {
            return err;
        };

        for (0..count) |i| {
            events[i] = .{
                .user_data = cqes[i].user_data,
                .result = cqes[i].res,
                .flags = cqes[i].flags,
            };
        }
        self.timeout_count = 0;
        return count;
    }

    /// Submit pending SQEs and wait for at least `wait_nr` completions.
    fn submitAndWait(self: *LinuxIoUring, events: []CompletionEntry, wait_nr: u32) !u32 {
        if (events.len == 0) return 0;
        const max_cqes = @min(events.len, 256);
        var cqe_buf: [256]linux.io_uring_cqe = undefined;
        const cqes = cqe_buf[0..max_cqes];

        _ = self.ring.submit_and_wait(wait_nr) catch |err| {
            return err;
        };
        const count = self.ring.copy_cqes(cqes, 0) catch |err| {
            return err;
        };

        for (0..count) |i| {
            events[i] = .{
                .user_data = cqes[i].user_data,
                .result = cqes[i].res,
                .flags = cqes[i].flags,
            };
        }
        return count;
    }
};

// ── Scenario 0: Raw socketpair send/recv throughput ──────────────────

const SCENARIO_0_ITERS = 100_000;
const WARMUP = 1_000;

fn benchRawSocketpair() !u64 {
    const pair = makeSocketPair();
    defer closeSocketPair(pair);

    const msg = "hello snek!"; // 11 bytes
    var recv_buf: [64]u8 = undefined;

    // Warmup
    for (0..WARMUP) |_| {
        _ = try posix.send(@intCast(pair[0]), msg, 0);
        const n = try posix.recv(@intCast(pair[1]), &recv_buf, 0);
        std.mem.doNotOptimizeAway(&n);
    }

    var timer = try std.time.Timer.start();

    for (0..SCENARIO_0_ITERS) |_| {
        _ = try posix.send(@intCast(pair[0]), msg, 0);
        const n = try posix.recv(@intCast(pair[1]), &recv_buf, 0);
        std.mem.doNotOptimizeAway(&n);
    }

    return timer.read();
}

// ── Scenario 1: Raw std.os.linux.IoUring (stdlib direct) ─────────────

const SCENARIO_1_ITERS = 100_000;

fn benchRawStdlibIoUring() !u64 {
    const pair = makeSocketPair();
    defer closeSocketPair(pair);

    const msg = "hello snek!";
    var recv_buf: [64]u8 = undefined;

    var ring = try linux.IoUring.init(256, 0);
    defer ring.deinit();

    // Warmup
    for (0..WARMUP) |_| {
        // Prep send
        _ = try ring.send(0, pair[0], msg, 0);
        _ = try ring.submit_and_wait(1);
        var cqe_buf: [4]linux.io_uring_cqe = undefined;
        _ = try ring.copy_cqes(&cqe_buf, 0);

        // Prep recv
        _ = try ring.recv(1, pair[1], .{ .buffer = &recv_buf }, 0);
        _ = try ring.submit_and_wait(1);
        const n = try ring.copy_cqes(&cqe_buf, 0);
        std.mem.doNotOptimizeAway(&n);
    }

    var timer = try std.time.Timer.start();

    for (0..SCENARIO_1_ITERS) |_| {
        _ = try ring.send(0, pair[0], msg, 0);
        _ = try ring.submit_and_wait(1);
        var cqe_buf: [4]linux.io_uring_cqe = undefined;
        _ = try ring.copy_cqes(&cqe_buf, 0);

        _ = try ring.recv(1, pair[1], .{ .buffer = &recv_buf }, 0);
        _ = try ring.submit_and_wait(1);
        const n = try ring.copy_cqes(&cqe_buf, 0);
        std.mem.doNotOptimizeAway(&n);
    }

    return timer.read();
}

// ── Scenario 2: Our IoUring adapter ──────────────────────────────────

const SCENARIO_2_ITERS = 100_000;

fn benchIoUringAdapter() !u64 {
    const pair = makeSocketPair();
    defer closeSocketPair(pair);

    const msg = "hello snek!";
    var recv_buf: [64]u8 = undefined;
    var events: [16]CompletionEntry = undefined;

    var ring = try LinuxIoUring.init(256);
    defer ring.deinit();

    // Warmup
    for (0..WARMUP) |i| {
        try ring.submitSend(pair[0], msg, i * 2);
        var count: u32 = 0;
        while (count == 0) {
            count = try ring.submitAndWait(&events, 1);
        }
        try ring.submitRecv(pair[1], &recv_buf, i * 2 + 1);
        count = 0;
        while (count == 0) {
            count = try ring.submitAndWait(&events, 1);
        }
    }

    var timer = try std.time.Timer.start();

    for (0..SCENARIO_2_ITERS) |i| {
        const base = (WARMUP + i) * 2;
        try ring.submitSend(pair[0], msg, base);
        var count: u32 = 0;
        while (count == 0) {
            count = try ring.submitAndWait(&events, 1);
        }
        try ring.submitRecv(pair[1], &recv_buf, base + 1);
        count = 0;
        while (count == 0) {
            count = try ring.submitAndWait(&events, 1);
        }
    }

    return timer.read();
}

// ── Scenario 3: Batch submission ─────────────────────────────────────

fn benchBatchSubmission(comptime batch_size: u32) !u64 {
    var pairs: [batch_size][2]posix.fd_t = undefined;
    for (0..batch_size) |i| {
        pairs[i] = makeSocketPair();
    }
    defer {
        for (0..batch_size) |i| {
            closeSocketPair(pairs[i]);
        }
    }

    var ring = try LinuxIoUring.init(256);
    defer ring.deinit();

    const msg = "batch test!";
    const iterations: u32 = 10_000 / batch_size + 1;

    // Warmup: one full batch cycle
    for (0..batch_size) |i| {
        try ring.submitSend(pairs[i][0], msg, @intCast(i));
    }
    var events: [512]CompletionEntry = undefined;
    var completed: u32 = 0;
    while (completed < batch_size) {
        completed += try ring.submitAndWait(events[0..], batch_size - completed);
    }
    // Drain recv side
    var recv_buf: [64]u8 = undefined;
    for (0..batch_size) |i| {
        _ = try posix.recv(@intCast(pairs[i][1]), &recv_buf, 0);
    }

    var timer = try std.time.Timer.start();

    for (0..iterations) |iter| {
        for (0..batch_size) |i| {
            try ring.submitSend(pairs[i][0], msg, @intCast(iter * batch_size + i));
        }
        completed = 0;
        while (completed < batch_size) {
            completed += try ring.submitAndWait(events[0..], batch_size - completed);
        }
        for (0..batch_size) |i| {
            _ = try posix.recv(@intCast(pairs[i][1]), &recv_buf, 0);
        }
    }

    const total_ns = timer.read();
    return total_ns / iterations;
}

// ── Scenario 4: io_uring read/write on pipe vs posix read/write ──────

const SCENARIO_4_ITERS = 100_000;

fn benchRawPipeReadWrite() !u64 {
    const pipe = makePipe();
    defer closePipe(pipe);

    const msg = "hello snek!";
    var recv_buf: [64]u8 = undefined;

    // Warmup
    for (0..WARMUP) |_| {
        _ = try posix.write(pipe[1], msg);
        const n = try posix.read(pipe[0], &recv_buf);
        std.mem.doNotOptimizeAway(&n);
    }

    var timer = try std.time.Timer.start();

    for (0..SCENARIO_4_ITERS) |_| {
        _ = try posix.write(pipe[1], msg);
        const n = try posix.read(pipe[0], &recv_buf);
        std.mem.doNotOptimizeAway(&n);
    }

    return timer.read();
}

fn benchIoUringPipeReadWrite() !u64 {
    const pipe = makePipe();
    defer closePipe(pipe);

    const msg = "hello snek!";
    var recv_buf: [64]u8 = undefined;

    var ring = try LinuxIoUring.init(256);
    defer ring.deinit();

    var events: [16]CompletionEntry = undefined;

    // Warmup
    for (0..WARMUP) |_| {
        try ring.submitWrite(pipe[1], msg, 0, 0);
        var count: u32 = 0;
        while (count == 0) {
            count = try ring.submitAndWait(&events, 1);
        }
        try ring.submitRead(pipe[0], &recv_buf, 0, 1);
        count = 0;
        while (count == 0) {
            count = try ring.submitAndWait(&events, 1);
        }
    }

    var timer = try std.time.Timer.start();

    for (0..SCENARIO_4_ITERS) |_| {
        try ring.submitWrite(pipe[1], msg, 0, 0);
        var count: u32 = 0;
        while (count == 0) {
            count = try ring.submitAndWait(&events, 1);
        }
        try ring.submitRead(pipe[0], &recv_buf, 0, 1);
        count = 0;
        while (count == 0) {
            count = try ring.submitAndWait(&events, 1);
        }
    }

    return timer.read();
}

// ── Summary storage ──────────────────────────────────────────────────

const Results = struct {
    raw_socketpair_ns: u64,
    raw_stdlib_uring_ns: u64,
    adapter_ns: u64,
    batch_10_ns: u64,
    batch_50_ns: u64,
    batch_100_ns: u64,
    raw_pipe_ns: u64,
    uring_pipe_ns: u64,
};

// ── Main ─────────────────────────────────────────────────────────────

pub fn main() !void {
    std.debug.print("=== io_uring Benchmark (Linux) ===\n", .{});
    std.debug.print("  Platform: Linux, io_uring backend\n", .{});
    std.debug.print("  Message size: 11 bytes\n\n", .{});

    var best: Results = .{
        .raw_socketpair_ns = std.math.maxInt(u64),
        .raw_stdlib_uring_ns = std.math.maxInt(u64),
        .adapter_ns = std.math.maxInt(u64),
        .batch_10_ns = std.math.maxInt(u64),
        .batch_50_ns = std.math.maxInt(u64),
        .batch_100_ns = std.math.maxInt(u64),
        .raw_pipe_ns = std.math.maxInt(u64),
        .uring_pipe_ns = std.math.maxInt(u64),
    };

    for (0..3) |run| {
        std.debug.print("--- Run {d} ---\n", .{run + 1});

        // Scenario 0
        std.debug.print("  Scenario 0: Raw socketpair send/recv ({d} iters)\n", .{SCENARIO_0_ITERS});
        const raw_ns = try benchRawSocketpair();
        std.debug.print("    Raw send/recv:              {d:>8.1} ns/op\n", .{nsPerOp(raw_ns, SCENARIO_0_ITERS)});
        best.raw_socketpair_ns = @min(best.raw_socketpair_ns, raw_ns);

        // Scenario 1
        std.debug.print("  Scenario 1: Raw stdlib IoUring ({d} iters)\n", .{SCENARIO_1_ITERS});
        const stdlib_ns = try benchRawStdlibIoUring();
        std.debug.print("    Stdlib io_uring:            {d:>8.1} ns/op\n", .{nsPerOp(stdlib_ns, SCENARIO_1_ITERS)});
        best.raw_stdlib_uring_ns = @min(best.raw_stdlib_uring_ns, stdlib_ns);

        // Scenario 2
        std.debug.print("  Scenario 2: Our IoUring adapter ({d} iters)\n", .{SCENARIO_2_ITERS});
        const adapter_ns = try benchIoUringAdapter();
        std.debug.print("    Adapter (submit+poll):      {d:>8.1} ns/op\n", .{nsPerOp(adapter_ns, SCENARIO_2_ITERS)});
        best.adapter_ns = @min(best.adapter_ns, adapter_ns);

        // Scenario 3
        std.debug.print("  Scenario 3: Batch submission scaling\n", .{});
        const b10 = try benchBatchSubmission(10);
        std.debug.print("    N=10:   {d:>10.1} ns/batch\n", .{@as(f64, @floatFromInt(b10))});
        best.batch_10_ns = @min(best.batch_10_ns, b10);

        const b50 = try benchBatchSubmission(50);
        std.debug.print("    N=50:   {d:>10.1} ns/batch\n", .{@as(f64, @floatFromInt(b50))});
        best.batch_50_ns = @min(best.batch_50_ns, b50);

        const b100 = try benchBatchSubmission(100);
        std.debug.print("    N=100:  {d:>10.1} ns/batch\n", .{@as(f64, @floatFromInt(b100))});
        best.batch_100_ns = @min(best.batch_100_ns, b100);

        // Scenario 4
        std.debug.print("  Scenario 4: io_uring vs raw syscalls (pipe read/write, {d} iters)\n", .{SCENARIO_4_ITERS});
        const raw_pipe_ns = try benchRawPipeReadWrite();
        std.debug.print("    Raw pipe read/write:        {d:>8.1} ns/op\n", .{nsPerOp(raw_pipe_ns, SCENARIO_4_ITERS)});
        best.raw_pipe_ns = @min(best.raw_pipe_ns, raw_pipe_ns);

        const uring_pipe_ns = try benchIoUringPipeReadWrite();
        std.debug.print("    io_uring pipe read/write:   {d:>8.1} ns/op\n", .{nsPerOp(uring_pipe_ns, SCENARIO_4_ITERS)});
        best.uring_pipe_ns = @min(best.uring_pipe_ns, uring_pipe_ns);

        std.debug.print("\n", .{});
    }

    // ── Summary ──────────────────────────────────────────────────────
    std.debug.print("=== SUMMARY (best of 3 runs) ===\n\n", .{});

    const raw_per_op = nsPerOp(best.raw_socketpair_ns, SCENARIO_0_ITERS);
    const stdlib_per_op = nsPerOp(best.raw_stdlib_uring_ns, SCENARIO_1_ITERS);
    const adapter_per_op = nsPerOp(best.adapter_ns, SCENARIO_2_ITERS);

    std.debug.print("  Scenario 0 — Raw socketpair throughput (kernel floor):\n", .{});
    std.debug.print("    {d:.1} ns/op ({d} round-trips)\n\n", .{ raw_per_op, SCENARIO_0_ITERS });

    std.debug.print("  Scenario 1 — Raw stdlib IoUring:\n", .{});
    std.debug.print("    {d:.1} ns/op ({d} round-trips)\n", .{ stdlib_per_op, SCENARIO_1_ITERS });
    if (raw_per_op > 0) {
        std.debug.print("    io_uring overhead vs kernel floor: {d:.1} ns/op ({d:.2}x)\n\n", .{
            stdlib_per_op - raw_per_op,
            stdlib_per_op / raw_per_op,
        });
    }

    std.debug.print("  Scenario 2 — Our IoUring adapter:\n", .{});
    std.debug.print("    {d:.1} ns/op ({d} round-trips)\n", .{ adapter_per_op, SCENARIO_2_ITERS });
    if (stdlib_per_op > 0) {
        std.debug.print("    Adapter/Stdlib ratio: {d:.2}x\n", .{adapter_per_op / stdlib_per_op});
        std.debug.print("    Adapter overhead vs stdlib: {d:.1} ns/op\n\n", .{adapter_per_op - stdlib_per_op});
    }

    std.debug.print("  Scenario 3 — Batch submission scaling:\n", .{});
    std.debug.print("    N=10:   {d:>10.1} ns/batch  ({d:.1} ns/op)\n", .{ @as(f64, @floatFromInt(best.batch_10_ns)), @as(f64, @floatFromInt(best.batch_10_ns)) / 10.0 });
    std.debug.print("    N=50:   {d:>10.1} ns/batch  ({d:.1} ns/op)\n", .{ @as(f64, @floatFromInt(best.batch_50_ns)), @as(f64, @floatFromInt(best.batch_50_ns)) / 50.0 });
    std.debug.print("    N=100:  {d:>10.1} ns/batch  ({d:.1} ns/op)\n", .{ @as(f64, @floatFromInt(best.batch_100_ns)), @as(f64, @floatFromInt(best.batch_100_ns)) / 100.0 });
    const per_op_10 = @as(f64, @floatFromInt(best.batch_10_ns)) / 10.0;
    const per_op_100 = @as(f64, @floatFromInt(best.batch_100_ns)) / 100.0;
    if (per_op_10 > 0) {
        std.debug.print("    Scaling efficiency (N=100 vs N=10): {d:.2}x per-op cost\n\n", .{per_op_100 / per_op_10});
    }

    std.debug.print("  Scenario 4 — io_uring vs raw syscalls (pipe read/write):\n", .{});
    const raw_pipe_per_op = nsPerOp(best.raw_pipe_ns, SCENARIO_4_ITERS);
    const uring_pipe_per_op = nsPerOp(best.uring_pipe_ns, SCENARIO_4_ITERS);
    std.debug.print("    Raw pipe:         {d:>8.1} ns/op\n", .{raw_pipe_per_op});
    std.debug.print("    io_uring pipe:    {d:>8.1} ns/op\n", .{uring_pipe_per_op});
    if (raw_pipe_per_op > 0) {
        std.debug.print("    io_uring/raw ratio: {d:.2}x\n", .{uring_pipe_per_op / raw_pipe_per_op});
        std.debug.print("    io_uring overhead: {d:.1} ns/op\n\n", .{uring_pipe_per_op - raw_pipe_per_op});
    }

    // ── Verdict ──────────────────────────────────────────────────────
    std.debug.print("  VERDICT:\n", .{});
    if (adapter_per_op > 0 and stdlib_per_op > 0) {
        const overhead_pct = (adapter_per_op - stdlib_per_op) / stdlib_per_op * 100.0;
        if (overhead_pct < 5.0) {
            std.debug.print("    Adapter overhead is negligible ({d:.1}%% over stdlib)\n", .{overhead_pct});
        } else if (overhead_pct < 20.0) {
            std.debug.print("    Adapter overhead is modest ({d:.1}%% over stdlib)\n", .{overhead_pct});
        } else {
            std.debug.print("    Adapter overhead is significant ({d:.1}%% over stdlib) — investigate\n", .{overhead_pct});
        }
    }
}
