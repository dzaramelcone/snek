//! Benchmark: BufferPool (pre-allocated pool) vs Arena allocation
//!
//! Falsifiability test for the BufferPool design choice.
//! Claim: Pre-allocated buffer pool eliminates allocation in the hot path.
//! Alternative: Arena allocators with retention achieve the same (no syscalls after warmup).
//! Threshold: If arena alloc+reset is within 2x of pool acquire+release latency,
//!   switch to arena (simpler, no ref counting overhead).
//!
//! Context: BufferPool's real justification is io_uring registered buffers
//!   (IORING_REGISTER_BUFFERS requires stable addresses). If we don't use
//!   registered buffers, arena wins on simplicity.
//!
//! Run: zig build-exe -OReleaseFast bench/buffer_comparison.zig && ./buffer_comparison

const std = @import("std");

// ── BufferPool (inlined from src/core/buffer.zig) ────────────────────

const Buffer = struct {
    data: []u8,
    ref_count: std.atomic.Value(u32),
    pool_index: u32,

    pub fn retain(self: *Buffer) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Buffer) void {
        const prev = self.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
    }
};

const BufferPool = struct {
    buffers: []Buffer,
    capacity: usize,
    buffer_size: usize,
    backing: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, buffer_size: usize) !BufferPool {
        const buffers = try @as([]Buffer, allocator.alloc(Buffer, capacity));
        for (buffers, 0..) |*buf, i| {
            buf.* = .{
                .data = try allocator.alloc(u8, buffer_size),
                .ref_count = std.atomic.Value(u32).init(0),
                .pool_index = @intCast(i),
            };
        }
        return .{
            .buffers = buffers,
            .capacity = capacity,
            .buffer_size = buffer_size,
            .backing = allocator,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        for (self.buffers) |*buf| {
            self.backing.free(buf.data);
        }
        self.backing.free(self.buffers);
    }

    /// Acquire a buffer with ref_count == 0. Linear scan.
    pub fn acquire(self: *BufferPool) ?*Buffer {
        for (self.buffers) |*buf| {
            if (buf.ref_count.load(.monotonic) == 0) {
                buf.retain();
                return buf;
            }
        }
        return null;
    }

    /// Release a buffer back to the pool.
    pub fn releaseBuffer(self: *BufferPool, buf: *Buffer) void {
        _ = self;
        buf.release();
    }
};

// ── Benchmark config ─────────────────────────────────────────────────

const SEQ_ITERS = 1_000_000;
const MULTI_ITERS = 100_000;
const BURST_ITERS = 10_000;
const WARMUP = 10_000;
const MULTI_COUNT = 10;
const BURST_COUNT = 100;

// ── BufferPool benchmarks ────────────────────────────────────────────

fn benchPoolSequential(pool: *BufferPool) !u64 {
    // Warmup
    for (0..WARMUP) |_| {
        const buf = pool.acquire().?;
        @memset(buf.data[0..64], 0xAB);
        std.mem.doNotOptimizeAway(buf.data.ptr);
        pool.releaseBuffer(buf);
    }

    var timer = try std.time.Timer.start();
    for (0..SEQ_ITERS) |_| {
        const buf = pool.acquire().?;
        @memset(buf.data[0..64], 0xAB);
        std.mem.doNotOptimizeAway(buf.data.ptr);
        pool.releaseBuffer(buf);
    }
    return timer.read();
}

fn benchPoolMulti(pool: *BufferPool) !u64 {
    var bufs: [MULTI_COUNT]*Buffer = undefined;

    // Warmup
    for (0..WARMUP / MULTI_COUNT) |_| {
        for (0..MULTI_COUNT) |i| {
            bufs[i] = pool.acquire().?;
            @memset(bufs[i].data[0..64], 0xAB);
        }
        for (0..MULTI_COUNT) |i| pool.releaseBuffer(bufs[i]);
    }

    var timer = try std.time.Timer.start();
    for (0..MULTI_ITERS) |_| {
        for (0..MULTI_COUNT) |i| {
            bufs[i] = pool.acquire().?;
            @memset(bufs[i].data[0..64], 0xAB);
            std.mem.doNotOptimizeAway(bufs[i].data.ptr);
        }
        for (0..MULTI_COUNT) |i| pool.releaseBuffer(bufs[i]);
    }
    return timer.read();
}

fn benchPoolBurst(pool: *BufferPool) !u64 {
    var bufs: [BURST_COUNT]*Buffer = undefined;

    // Warmup
    for (0..WARMUP / BURST_COUNT) |_| {
        for (0..BURST_COUNT) |i| {
            bufs[i] = pool.acquire().?;
            @memset(bufs[i].data[0..64], 0xAB);
        }
        for (0..BURST_COUNT) |i| pool.releaseBuffer(bufs[i]);
    }

    var timer = try std.time.Timer.start();
    for (0..BURST_ITERS) |_| {
        for (0..BURST_COUNT) |i| {
            bufs[i] = pool.acquire().?;
            @memset(bufs[i].data[0..64], 0xAB);
            std.mem.doNotOptimizeAway(bufs[i].data.ptr);
        }
        for (0..BURST_COUNT) |i| pool.releaseBuffer(bufs[i]);
    }
    return timer.read();
}

// ── Arena benchmarks ─────────────────────────────────────────────────

fn benchArenaSequential(buffer_size: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Warmup
    for (0..WARMUP) |_| {
        const data = try allocator.alloc(u8, buffer_size);
        @memset(data[0..64], 0xAB);
        std.mem.doNotOptimizeAway(data.ptr);
        _ = arena.reset(.retain_capacity);
    }

    var timer = try std.time.Timer.start();
    for (0..SEQ_ITERS) |_| {
        const data = try allocator.alloc(u8, buffer_size);
        @memset(data[0..64], 0xAB);
        std.mem.doNotOptimizeAway(data.ptr);
        _ = arena.reset(.retain_capacity);
    }
    return timer.read();
}

fn benchArenaMulti(buffer_size: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Warmup
    for (0..WARMUP / MULTI_COUNT) |_| {
        for (0..MULTI_COUNT) |_| {
            const data = try allocator.alloc(u8, buffer_size);
            @memset(data[0..64], 0xAB);
        }
        _ = arena.reset(.retain_capacity);
    }

    var timer = try std.time.Timer.start();
    for (0..MULTI_ITERS) |_| {
        for (0..MULTI_COUNT) |_| {
            const data = try allocator.alloc(u8, buffer_size);
            @memset(data[0..64], 0xAB);
            std.mem.doNotOptimizeAway(data.ptr);
        }
        _ = arena.reset(.retain_capacity);
    }
    return timer.read();
}

fn benchArenaBurst(buffer_size: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Warmup
    for (0..WARMUP / BURST_COUNT) |_| {
        for (0..BURST_COUNT) |_| {
            const data = try allocator.alloc(u8, buffer_size);
            @memset(data[0..64], 0xAB);
        }
        _ = arena.reset(.retain_capacity);
    }

    var timer = try std.time.Timer.start();
    for (0..BURST_ITERS) |_| {
        for (0..BURST_COUNT) |_| {
            const data = try allocator.alloc(u8, buffer_size);
            @memset(data[0..64], 0xAB);
            std.mem.doNotOptimizeAway(data.ptr);
        }
        _ = arena.reset(.retain_capacity);
    }
    return timer.read();
}

// ── Run all scenarios for a given buffer size ────────────────────────

fn runSuite(buffer_size: usize) !void {
    std.debug.print("\n── buffer_size = {d} bytes ──\n", .{buffer_size});

    // Pool needs enough capacity for burst scenario
    var pool = try BufferPool.init(std.heap.page_allocator, BURST_COUNT, buffer_size);
    defer pool.deinit();

    // Scenario 1: Sequential
    const pool_seq = try benchPoolSequential(&pool);
    const arena_seq = try benchArenaSequential(buffer_size);
    const seq_ratio = @as(f64, @floatFromInt(pool_seq)) / @as(f64, @floatFromInt(arena_seq));

    std.debug.print("\n  Scenario 1: Sequential acquire/release ({d} cycles)\n", .{SEQ_ITERS});
    std.debug.print("    BufferPool: {d:.1} ns/op\n", .{
        @as(f64, @floatFromInt(pool_seq)) / @as(f64, @floatFromInt(SEQ_ITERS)),
    });
    std.debug.print("    Arena:      {d:.1} ns/op\n", .{
        @as(f64, @floatFromInt(arena_seq)) / @as(f64, @floatFromInt(SEQ_ITERS)),
    });
    std.debug.print("    Ratio (Pool/Arena): {d:.2}x\n", .{seq_ratio});

    // Scenario 2: Multiple outstanding
    const pool_multi = try benchPoolMulti(&pool);
    const arena_multi = try benchArenaMulti(buffer_size);
    const multi_ops = MULTI_ITERS * MULTI_COUNT;
    const multi_ratio = @as(f64, @floatFromInt(pool_multi)) / @as(f64, @floatFromInt(arena_multi));

    std.debug.print("\n  Scenario 2: {d} outstanding buffers ({d} total ops)\n", .{ MULTI_COUNT, multi_ops });
    std.debug.print("    BufferPool: {d:.1} ns/op\n", .{
        @as(f64, @floatFromInt(pool_multi)) / @as(f64, @floatFromInt(multi_ops)),
    });
    std.debug.print("    Arena:      {d:.1} ns/op\n", .{
        @as(f64, @floatFromInt(arena_multi)) / @as(f64, @floatFromInt(multi_ops)),
    });
    std.debug.print("    Ratio (Pool/Arena): {d:.2}x\n", .{multi_ratio});

    // Scenario 3: Burst
    const pool_burst = try benchPoolBurst(&pool);
    const arena_burst = try benchArenaBurst(buffer_size);
    const burst_ops = BURST_ITERS * BURST_COUNT;
    const burst_ratio = @as(f64, @floatFromInt(pool_burst)) / @as(f64, @floatFromInt(arena_burst));

    std.debug.print("\n  Scenario 3: Burst {d} buffers ({d} total ops)\n", .{ BURST_COUNT, burst_ops });
    std.debug.print("    BufferPool: {d:.1} ns/op\n", .{
        @as(f64, @floatFromInt(pool_burst)) / @as(f64, @floatFromInt(burst_ops)),
    });
    std.debug.print("    Arena:      {d:.1} ns/op\n", .{
        @as(f64, @floatFromInt(arena_burst)) / @as(f64, @floatFromInt(burst_ops)),
    });
    std.debug.print("    Ratio (Pool/Arena): {d:.2}x\n", .{burst_ratio});
}

pub fn main() !void {
    std.debug.print("=== Buffer Comparison Benchmark ===\n", .{});
    std.debug.print("  BufferPool (pre-allocated, linear scan, atomic ref_count)\n", .{});
    std.debug.print("  vs Arena (std.heap.ArenaAllocator, reset with retain_capacity)\n", .{});
    std.debug.print("  Iterations: {d} seq, {d} multi, {d} burst\n", .{
        SEQ_ITERS, MULTI_ITERS, BURST_ITERS,
    });

    // Run 3 times for each buffer size, results stabilize from warmup
    std.debug.print("\n============================================================\n", .{});
    std.debug.print("  4 KB buffers (typical read buffer)\n", .{});
    std.debug.print("============================================================\n", .{});
    try runSuite(4096);

    std.debug.print("\n============================================================\n", .{});
    std.debug.print("  16 KB buffers (larger response buffer)\n", .{});
    std.debug.print("============================================================\n", .{});
    try runSuite(16384);

    // Overall verdict
    std.debug.print("\n============================================================\n", .{});
    std.debug.print("  VERDICT\n", .{});
    std.debug.print("============================================================\n", .{});
    std.debug.print(
        \\
        \\  Threshold: if arena is within 2x of BufferPool, prefer arena (simpler).
        \\  Arena has no ref counting, no pool sizing, no linear scan overhead.
        \\
        \\  BufferPool's real justification: io_uring registered buffers
        \\  (IORING_REGISTER_BUFFERS requires stable addresses across submissions).
        \\  If we don't use registered buffers, arena wins on simplicity.
        \\
        \\  Key observation: BufferPool acquire is O(n) linear scan for ref_count==0.
        \\  Arena alloc after warmup is O(1) bump pointer.
        \\  Arena reset(.retain_capacity) is O(1) — just resets the bump pointer.
        \\
    , .{});
}
