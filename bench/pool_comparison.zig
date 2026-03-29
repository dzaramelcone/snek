//! Benchmark: HiveArray (bitset pool) vs FreeList pool
//!
//! Falsifiability test for the HiveArray design choice.
//! Claim: O(1) bitset acquire via CPU intrinsic beats free list traversal.
//! Threshold: if FreeList is within 2x of HiveArray, switch to FreeList (simpler).
//!
//! Run: zig build-exe -OReleaseFast bench/pool_comparison.zig && ./pool_comparison

const std = @import("std");

// ── HiveArray (inlined from src/core/pool.zig to avoid cross-module import) ──
fn HiveArray(comptime T: type, comptime capacity: u16) type {
    return struct {
        const Self = @This();
        const BitSet = std.bit_set.IntegerBitSet(capacity);

        buffer: [capacity]T,
        used: BitSet,

        pub fn init() Self {
            return .{ .buffer = undefined, .used = BitSet.initEmpty() };
        }

        pub fn get(self: *Self) ?*T {
            const free_bits = ~self.used.mask;
            if (free_bits == 0) return null;
            const index = @ctz(free_bits);
            if (index >= capacity) return null;
            self.used.set(index);
            return &self.buffer[index];
        }

        pub fn put(self: *Self, item: *T) void {
            const index = (@intFromPtr(item) - @intFromPtr(&self.buffer[0])) / @sizeOf(T);
            self.used.unset(index);
        }

        pub fn count(self: *const Self) usize {
            return self.used.count();
        }

        pub fn available(self: *const Self) usize {
            return capacity - self.used.count();
        }
    };
}

// ── Test item matching realistic connection context size ─────────────
const ConnectionContext = struct {
    id: u64,
    state: u32,
    flags: u32,
    timestamp: i64,
    padding: [96]u8, // ~128 bytes total, realistic for a connection context
};

// ── Free list alternative (index-based, no pointer overlay) ──────────
fn FreeList(comptime T: type, comptime capacity: u16) type {
    const SENTINEL = std.math.maxInt(u16);
    return struct {
        const Self = @This();

        buffer: [capacity]T,
        next: [capacity]u16, // index-based free list (next[i] = next free after i)
        free_head: u16, // index of first free slot, SENTINEL if none
        count_used: usize,

        pub fn initInPlace(self: *Self) void {
            // Chain: 0 → 1 → 2 → ... → capacity-1 → SENTINEL
            for (0..capacity) |i| {
                self.next[i] = if (i + 1 < capacity) @intCast(i + 1) else SENTINEL;
            }
            self.free_head = 0;
            self.count_used = 0;
        }

        pub fn get(self: *Self) ?*T {
            if (self.free_head == SENTINEL) return null;
            const index = self.free_head;
            self.free_head = self.next[index];
            self.count_used += 1;
            return &self.buffer[index];
        }

        pub fn put(self: *Self, item: *T) void {
            const index: u16 = @intCast((@intFromPtr(item) - @intFromPtr(&self.buffer[0])) / @sizeOf(T));
            self.next[index] = self.free_head;
            self.free_head = index;
            self.count_used -= 1;
        }

        pub fn count(self: *const Self) usize {
            return self.count_used;
        }

        pub fn available(self: *const Self) usize {
            return capacity - self.count_used;
        }
    };
}

// ── Benchmark harness ────────────────────────────────────────────────

const CAPACITY = 4096;
const ITERATIONS = 1_000_000;
const WARMUP = 10_000;

fn benchHiveArray() !u64 {
    var p = HiveArray(ConnectionContext, CAPACITY).init();
    var items: [CAPACITY]*ConnectionContext = undefined;

    // Warmup
    for (0..WARMUP) |_| {
        const item = p.get().?;
        item.id = 1;
        p.put(item);
    }

    var timer = try std.time.Timer.start();

    // Scenario 1: Sequential acquire/release (hot path — single connection accept/close)
    for (0..ITERATIONS) |i| {
        const item = p.get().?;
        item.id = i;
        std.mem.doNotOptimizeAway(&item.id);
        p.put(item);
    }
    const seq_ns = timer.read();

    // Scenario 2: Fill to 75% capacity, then churn (realistic steady state)
    timer.reset();
    const fill_count = CAPACITY * 3 / 4;
    for (0..fill_count) |i| {
        items[i] = p.get().?;
        items[i].id = i;
    }
    // Now acquire/release in the remaining 25% of slots
    const churn_iters = ITERATIONS / 4;
    for (0..churn_iters) |i| {
        const item = p.get().?;
        item.id = i;
        std.mem.doNotOptimizeAway(&item.id);
        p.put(item);
    }
    // Cleanup
    for (0..fill_count) |i| {
        p.put(items[i]);
    }
    const churn_ns = timer.read();

    // Scenario 3: Fill to near-exhaustion (worst case for bitset — few free bits)
    timer.reset();
    const near_full = CAPACITY - 4; // only 4 slots free
    for (0..near_full) |i| {
        items[i] = p.get().?;
        items[i].id = i;
    }
    const exhaust_iters = ITERATIONS / 10;
    for (0..exhaust_iters) |i| {
        const item = p.get().?;
        item.id = i;
        std.mem.doNotOptimizeAway(&item.id);
        p.put(item);
    }
    for (0..near_full) |i| {
        p.put(items[i]);
    }
    const exhaust_ns = timer.read();

    std.debug.print("\n  HiveArray (bitset):\n", .{});
    std.debug.print("    Sequential acquire/release: {d:.1} ns/op ({d} ops)\n", .{
        @as(f64, @floatFromInt(seq_ns)) / @as(f64, @floatFromInt(ITERATIONS)),
        ITERATIONS,
    });
    std.debug.print("    Churn at 75% capacity:      {d:.1} ns/op ({d} ops)\n", .{
        @as(f64, @floatFromInt(churn_ns)) / @as(f64, @floatFromInt(churn_iters)),
        churn_iters,
    });
    std.debug.print("    Near-exhaustion (4 free):    {d:.1} ns/op ({d} ops)\n", .{
        @as(f64, @floatFromInt(exhaust_ns)) / @as(f64, @floatFromInt(exhaust_iters)),
        exhaust_iters,
    });

    return seq_ns + churn_ns + exhaust_ns;
}

fn benchFreeList() !u64 {
    var p: FreeList(ConnectionContext, CAPACITY) = undefined;
    p.initInPlace();
    var items: [CAPACITY]*ConnectionContext = undefined;

    // Warmup
    for (0..WARMUP) |_| {
        const item = p.get().?;
        item.id = 1;
        p.put(item);
    }

    var timer = try std.time.Timer.start();

    // Scenario 1: Sequential acquire/release
    for (0..ITERATIONS) |i| {
        const item = p.get().?;
        item.id = i;
        std.mem.doNotOptimizeAway(&item.id);
        p.put(item);
    }
    const seq_ns = timer.read();

    // Scenario 2: Fill to 75%, churn in remaining
    timer.reset();
    const fill_count = CAPACITY * 3 / 4;
    for (0..fill_count) |i| {
        items[i] = p.get().?;
        items[i].id = i;
    }
    const churn_iters = ITERATIONS / 4;
    for (0..churn_iters) |i| {
        const item = p.get().?;
        item.id = i;
        std.mem.doNotOptimizeAway(&item.id);
        p.put(item);
    }
    for (0..fill_count) |i| {
        p.put(items[i]);
    }
    const churn_ns = timer.read();

    // Scenario 3: Near exhaustion
    timer.reset();
    const near_full = CAPACITY - 4;
    for (0..near_full) |i| {
        items[i] = p.get().?;
        items[i].id = i;
    }
    const exhaust_iters = ITERATIONS / 10;
    for (0..exhaust_iters) |i| {
        const item = p.get().?;
        item.id = i;
        std.mem.doNotOptimizeAway(&item.id);
        p.put(item);
    }
    for (0..near_full) |i| {
        p.put(items[i]);
    }
    const exhaust_ns = timer.read();

    std.debug.print("\n  FreeList:\n", .{});
    std.debug.print("    Sequential acquire/release: {d:.1} ns/op ({d} ops)\n", .{
        @as(f64, @floatFromInt(seq_ns)) / @as(f64, @floatFromInt(ITERATIONS)),
        ITERATIONS,
    });
    std.debug.print("    Churn at 75% capacity:      {d:.1} ns/op ({d} ops)\n", .{
        @as(f64, @floatFromInt(churn_ns)) / @as(f64, @floatFromInt(churn_iters)),
        churn_iters,
    });
    std.debug.print("    Near-exhaustion (4 free):    {d:.1} ns/op ({d} ops)\n", .{
        @as(f64, @floatFromInt(exhaust_ns)) / @as(f64, @floatFromInt(exhaust_iters)),
        exhaust_iters,
    });

    return seq_ns + churn_ns + exhaust_ns;
}

pub fn main() !void {
    std.debug.print("=== Pool Comparison Benchmark ===\n", .{});
    std.debug.print("  Capacity: {d}, Item size: {d} bytes\n", .{ CAPACITY, @sizeOf(ConnectionContext) });
    std.debug.print("  Iterations: {d} (sequential), {d} (churn), {d} (exhaustion)\n", .{
        ITERATIONS,
        ITERATIONS / 4,
        ITERATIONS / 10,
    });

    // Run each 3 times, take best
    var best_hive: u64 = std.math.maxInt(u64);
    var best_free: u64 = std.math.maxInt(u64);

    std.debug.print("\n--- Run 1 ---", .{});
    best_hive = @min(best_hive, try benchHiveArray());
    best_free = @min(best_free, try benchFreeList());

    std.debug.print("\n--- Run 2 ---", .{});
    best_hive = @min(best_hive, try benchHiveArray());
    best_free = @min(best_free, try benchFreeList());

    std.debug.print("\n--- Run 3 ---", .{});
    best_hive = @min(best_hive, try benchHiveArray());
    best_free = @min(best_free, try benchFreeList());

    std.debug.print("\n\n=== VERDICT ===\n", .{});
    const ratio = @as(f64, @floatFromInt(best_hive)) / @as(f64, @floatFromInt(best_free));
    std.debug.print("  HiveArray total: {d} ns\n", .{best_hive});
    std.debug.print("  FreeList  total: {d} ns\n", .{best_free});
    std.debug.print("  Ratio (HiveArray/FreeList): {d:.2}x\n", .{ratio});

    if (ratio > 2.0) {
        std.debug.print("  RESULT: HiveArray is >2x SLOWER. Consider switching to FreeList.\n", .{});
    } else if (ratio > 1.0) {
        std.debug.print("  RESULT: HiveArray is slower but within 2x. Keep if other benefits justify.\n", .{});
    } else if (ratio > 0.5) {
        std.debug.print("  RESULT: HiveArray is faster but within 2x. Marginal win.\n", .{});
    } else {
        std.debug.print("  RESULT: HiveArray is >2x FASTER. Clear winner.\n", .{});
    }

    std.debug.print("\n  Falsifiability threshold: if FreeList within 2x, prefer FreeList (simpler).\n", .{});
    std.debug.print("  Note: This is single-threaded. Per-worker pools have no contention.\n", .{});
}
