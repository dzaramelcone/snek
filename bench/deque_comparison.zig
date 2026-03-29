//! Benchmark: Chase-Lev deque vs Mutex+Deque vs Atomic SPSC queue
//!
//! Falsifiability test for the Chase-Lev work-stealing deque design choice.
//! Claim: Lock-free Chase-Lev beats mutex-protected deque under contention.
//! Threshold: if mutex is within 2x of Chase-Lev, prefer mutex (simpler).
//!
//! Run: zig build-exe -OReleaseFast bench/deque_comparison.zig -femit-bin=bench/deque_comparison && ./bench/deque_comparison

const std = @import("std");

// ── Chase-Lev Deque (inlined from src/core/deque.zig) ────────────────
fn ChaseLevDeque(comptime T: type) type {
    return struct {
        const Self = @This();

        top: std.atomic.Value(usize),
        bottom: std.atomic.Value(usize),
        buffer: []T,
        mask: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            std.debug.assert(capacity > 0 and (capacity & (capacity - 1)) == 0);
            const buffer = try allocator.alloc(T, capacity);
            return Self{
                .top = std.atomic.Value(usize).init(0),
                .bottom = std.atomic.Value(usize).init(0),
                .buffer = buffer,
                .mask = capacity - 1,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        pub fn push(self: *Self, item: T) void {
            const b = self.bottom.load(.monotonic);
            self.buffer[b & self.mask] = item;
            self.bottom.store(b +% 1, .release);
        }

        pub fn pop(self: *Self) ?T {
            const b = self.bottom.load(.monotonic) -% 1;
            self.bottom.store(b, .seq_cst);
            const t = self.top.load(.seq_cst);
            const diff: isize = @bitCast(b -% t);
            if (diff < 0) {
                self.bottom.store(t, .monotonic);
                return null;
            }
            const item = self.buffer[b & self.mask];
            if (diff == 0) {
                if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                    self.bottom.store(t +% 1, .monotonic);
                    return null;
                }
                self.bottom.store(t +% 1, .monotonic);
            }
            return item;
        }

        pub fn steal(self: *Self) ?T {
            const t = self.top.load(.seq_cst);
            const b = self.bottom.load(.seq_cst);
            const diff: isize = @bitCast(b -% t);
            if (diff <= 0) return null;
            const item = self.buffer[t & self.mask];
            if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                return null;
            }
            return item;
        }
    };
}

// ── Mutex-protected deque ────────────────────────────────────────────
fn MutexDeque(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        mask: usize,
        head: usize, // read/steal end (FIFO)
        tail: usize, // write/pop end (LIFO)
        mutex: std.Thread.Mutex,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            std.debug.assert(capacity > 0 and (capacity & (capacity - 1)) == 0);
            const buffer = try allocator.alloc(T, capacity);
            return Self{
                .buffer = buffer,
                .mask = capacity - 1,
                .head = 0,
                .tail = 0,
                .mutex = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        pub fn push(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.buffer[self.tail & self.mask] = item;
            self.tail +%= 1;
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.tail == self.head) return null;
            self.tail -%= 1;
            return self.buffer[self.tail & self.mask];
        }

        pub fn steal(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.head == self.tail) return null;
            const item = self.buffer[self.head & self.mask];
            self.head +%= 1;
            return item;
        }
    };
}

// ── Atomic SPSC ring buffer ──────────────────────────────────────────
fn SpscQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        mask: usize,
        head: std.atomic.Value(usize), // consumer reads from here
        tail: std.atomic.Value(usize), // producer writes here
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            std.debug.assert(capacity > 0 and (capacity & (capacity - 1)) == 0);
            const buffer = try allocator.alloc(T, capacity);
            return Self{
                .buffer = buffer,
                .mask = capacity - 1,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Producer pushes to tail.
        pub fn push(self: *Self, item: T) void {
            const t = self.tail.load(.monotonic);
            self.buffer[t & self.mask] = item;
            self.tail.store(t +% 1, .release);
        }

        /// Producer pops from tail (LIFO, like Chase-Lev owner pop).
        pub fn pop(self: *Self) ?T {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (t == h) return null;
            const new_t = t -% 1;
            self.tail.store(new_t, .release);
            return self.buffer[new_t & self.mask];
        }

        /// Consumer steals from head (FIFO).
        pub fn steal(self: *Self) ?T {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            const diff: isize = @bitCast(t -% h);
            if (diff <= 0) return null;
            const item = self.buffer[h & self.mask];
            self.head.store(h +% 1, .release);
            return item;
        }
    };
}

// ── Constants ────────────────────────────────────────────────────────

const CAPACITY = 4096;
const OPS = 1_000_000;
const WARMUP = 10_000;

// ── Scenario 1: Single-threaded push/pop (owner-only) ────────────────

fn benchSingleThread(comptime name: []const u8, comptime DequeType: type) !u64 {
    const allocator = std.heap.page_allocator;
    var d = try DequeType.init(allocator, CAPACITY);
    defer d.deinit();

    // Warmup
    for (0..WARMUP) |i| {
        d.push(@as(u64, @intCast(i)));
        std.mem.doNotOptimizeAway(d.pop());
    }

    var timer = try std.time.Timer.start();

    for (0..OPS) |i| {
        d.push(@as(u64, @intCast(i)));
        std.mem.doNotOptimizeAway(d.pop());
    }

    const ns = timer.read();
    const ns_per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(OPS));
    std.debug.print("    {s:<30} {d:>8.1} ns/op\n", .{ name, ns_per_op });
    return ns;
}

// ── Scenario 2: Producer-consumer (1 pusher, 1 stealer) ──────────────

fn benchProducerConsumer(comptime name: []const u8, comptime DequeType: type) !u64 {
    const allocator = std.heap.page_allocator;
    var d = try DequeType.init(allocator, CAPACITY);
    defer d.deinit();

    var stolen_count = std.atomic.Value(usize).init(0);
    var done = std.atomic.Value(bool).init(false);

    const Stealer = struct {
        fn run(deque: *DequeType, count: *std.atomic.Value(usize), is_done: *std.atomic.Value(bool)) void {
            var c: usize = 0;
            while (!is_done.load(.acquire)) {
                if (deque.steal()) |v| {
                    std.mem.doNotOptimizeAway(&v);
                    c += 1;
                }
            }
            // Drain remaining
            while (deque.steal()) |v| {
                std.mem.doNotOptimizeAway(&v);
                c += 1;
            }
            count.store(c, .release);
        }
    };

    var timer = try std.time.Timer.start();

    var thief = try std.Thread.spawn(.{}, Stealer.run, .{ &d, &stolen_count, &done });

    // Producer pushes OPS items, throttling to avoid overflowing the buffer
    var pushed: usize = 0;
    while (pushed < OPS) {
        d.push(@as(u64, @intCast(pushed)));
        pushed += 1;
        // If buffer is getting full, yield to let stealer catch up
        if (pushed % (CAPACITY / 2) == 0) {
            std.atomic.spinLoopHint();
        }
    }

    done.store(true, .release);
    thief.join();

    const ns = timer.read();
    const total_stolen = stolen_count.load(.acquire);
    const ns_per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(OPS));
    std.debug.print("    {s:<30} {d:>8.1} ns/op  (stolen: {d})\n", .{ name, ns_per_op, total_stolen });
    return ns;
}

// ── Scenario 3: Contended stealing (1 pusher, 3 stealers) ────────────

fn benchContended(comptime name: []const u8, comptime DequeType: type) !u64 {
    const allocator = std.heap.page_allocator;
    var d = try DequeType.init(allocator, CAPACITY);
    defer d.deinit();

    const NUM_THIEVES = 3;
    var stolen_counts: [NUM_THIEVES]std.atomic.Value(usize) = undefined;
    for (0..NUM_THIEVES) |i| {
        stolen_counts[i] = std.atomic.Value(usize).init(0);
    }
    var done = std.atomic.Value(bool).init(false);

    const Stealer = struct {
        fn run(deque: *DequeType, count: *std.atomic.Value(usize), is_done: *std.atomic.Value(bool)) void {
            var c: usize = 0;
            while (!is_done.load(.acquire)) {
                if (deque.steal()) |v| {
                    std.mem.doNotOptimizeAway(&v);
                    c += 1;
                }
            }
            while (deque.steal()) |v| {
                std.mem.doNotOptimizeAway(&v);
                c += 1;
            }
            count.store(c, .release);
        }
    };

    var timer = try std.time.Timer.start();

    var threads: [NUM_THIEVES]std.Thread = undefined;
    for (0..NUM_THIEVES) |i| {
        threads[i] = try std.Thread.spawn(.{}, Stealer.run, .{ &d, &stolen_counts[i], &done });
    }

    var pushed: usize = 0;
    while (pushed < OPS) {
        d.push(@as(u64, @intCast(pushed)));
        pushed += 1;
        if (pushed % (CAPACITY / 2) == 0) {
            std.atomic.spinLoopHint();
        }
    }

    done.store(true, .release);
    for (0..NUM_THIEVES) |i| {
        threads[i].join();
    }

    const ns = timer.read();
    var total_stolen: usize = 0;
    for (0..NUM_THIEVES) |i| {
        total_stolen += stolen_counts[i].load(.acquire);
    }
    const ns_per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(OPS));
    std.debug.print("    {s:<30} {d:>8.1} ns/op  (stolen: {d})\n", .{ name, ns_per_op, total_stolen });
    return ns;
}

// ── Scenario 4: Mixed push/pop with occasional steal ─────────────────

fn benchMixed(comptime name: []const u8, comptime DequeType: type) !u64 {
    const allocator = std.heap.page_allocator;
    var d = try DequeType.init(allocator, CAPACITY);
    defer d.deinit();

    var stolen_count = std.atomic.Value(usize).init(0);
    var done = std.atomic.Value(bool).init(false);

    const Stealer = struct {
        fn run(deque: *DequeType, count: *std.atomic.Value(usize), is_done: *std.atomic.Value(bool)) void {
            var c: usize = 0;
            while (!is_done.load(.acquire)) {
                if (deque.steal()) |v| {
                    std.mem.doNotOptimizeAway(&v);
                    c += 1;
                }
                // Slow stealer — only steals occasionally (simulates rare work-stealing)
                var spin: usize = 0;
                while (spin < 100) : (spin += 1) {
                    std.atomic.spinLoopHint();
                }
            }
            count.store(c, .release);
        }
    };

    var timer = try std.time.Timer.start();

    var thief = try std.Thread.spawn(.{}, Stealer.run, .{ &d, &stolen_count, &done });

    // Owner does 90% push/pop, 10% just push (leaving items for stealer)
    for (0..OPS) |i| {
        d.push(@as(u64, @intCast(i)));
        if (i % 10 != 0) {
            // 90%: owner handles it
            std.mem.doNotOptimizeAway(d.pop());
        }
        // 10%: leave for stealer
    }

    done.store(true, .release);
    thief.join();

    const ns = timer.read();
    const total_stolen = stolen_count.load(.acquire);
    const ns_per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(OPS));
    std.debug.print("    {s:<30} {d:>8.1} ns/op  (stolen: {d})\n", .{ name, ns_per_op, total_stolen });
    return ns;
}

// ── Main ─────────────────────────────────────────────────────────────

const CL = ChaseLevDeque(u64);
const MX = MutexDeque(u64);
const SP = SpscQueue(u64);

pub fn main() !void {
    std.debug.print("=== Deque Comparison Benchmark ===\n", .{});
    std.debug.print("  Capacity: {d}, Ops: {d}, Item: u64\n\n", .{ CAPACITY, OPS });

    var best_cl: [4]u64 = .{ std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64) };
    var best_mx: [4]u64 = .{ std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64) };
    var best_sp: [4]u64 = .{ std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64) };

    for (0..3) |run| {
        std.debug.print("--- Run {d} ---\n", .{run + 1});

        std.debug.print("  Scenario 1: Single-threaded push/pop (1M cycles)\n", .{});
        best_cl[0] = @min(best_cl[0], try benchSingleThread("Chase-Lev", CL));
        best_mx[0] = @min(best_mx[0], try benchSingleThread("Mutex+Deque", MX));
        best_sp[0] = @min(best_sp[0], try benchSingleThread("SPSC Queue", SP));

        std.debug.print("  Scenario 2: Producer-consumer (1 push, 1 steal)\n", .{});
        best_cl[1] = @min(best_cl[1], try benchProducerConsumer("Chase-Lev", CL));
        best_mx[1] = @min(best_mx[1], try benchProducerConsumer("Mutex+Deque", MX));
        best_sp[1] = @min(best_sp[1], try benchProducerConsumer("SPSC Queue", SP));

        std.debug.print("  Scenario 3: Contended (1 push, 3 steal)\n", .{});
        best_cl[2] = @min(best_cl[2], try benchContended("Chase-Lev", CL));
        best_mx[2] = @min(best_mx[2], try benchContended("Mutex+Deque", MX));
        // SPSC can't do multi-consumer, skip
        std.debug.print("    {s:<30} {s:>8}        (N/A: single-consumer only)\n", .{ "SPSC Queue", "---" });

        std.debug.print("  Scenario 4: Mixed (90% local, 10% stolen)\n", .{});
        best_cl[3] = @min(best_cl[3], try benchMixed("Chase-Lev", CL));
        best_mx[3] = @min(best_mx[3], try benchMixed("Mutex+Deque", MX));
        best_sp[3] = @min(best_sp[3], try benchMixed("SPSC Queue", SP));

        std.debug.print("\n", .{});
    }

    // ── VERDICT ──────────────────────────────────────────────────────

    std.debug.print("=== VERDICT ===\n\n", .{});

    const scenario_names = [_][]const u8{
        "Single-threaded push/pop",
        "Producer-consumer (1:1)",
        "Contended (1:3)",
        "Mixed (90/10)",
    };

    for (0..4) |s| {
        std.debug.print("  {s}:\n", .{scenario_names[s]});
        const cl_ns = @as(f64, @floatFromInt(best_cl[s]));
        const mx_ns = @as(f64, @floatFromInt(best_mx[s]));
        const cl_per_op = cl_ns / @as(f64, @floatFromInt(OPS));
        const mx_per_op = mx_ns / @as(f64, @floatFromInt(OPS));
        const ratio = mx_per_op / cl_per_op;

        std.debug.print("    Chase-Lev:  {d:>8.1} ns/op\n", .{cl_per_op});
        std.debug.print("    Mutex:      {d:>8.1} ns/op\n", .{mx_per_op});
        if (s != 2) {
            const sp_ns = @as(f64, @floatFromInt(best_sp[s]));
            const sp_per_op = sp_ns / @as(f64, @floatFromInt(OPS));
            std.debug.print("    SPSC:       {d:>8.1} ns/op\n", .{sp_per_op});
        }
        std.debug.print("    Mutex/CL ratio: {d:.2}x\n\n", .{ratio});
    }

    // Overall verdict: focus on contended scenario (scenario 3) — that's the design justification
    const cl_contended = @as(f64, @floatFromInt(best_cl[2]));
    const mx_contended = @as(f64, @floatFromInt(best_mx[2]));
    const contended_ratio = mx_contended / cl_contended;

    std.debug.print("  KEY METRIC — Contended stealing (Mutex/Chase-Lev): {d:.2}x\n", .{contended_ratio});

    if (contended_ratio < 2.0) {
        std.debug.print("  RESULT: Mutex is within 2x of Chase-Lev under contention.\n", .{});
        std.debug.print("          PREFER MUTEX — simpler, and the performance gap doesn't justify\n", .{});
        std.debug.print("          the complexity of a lock-free algorithm.\n", .{});
    } else {
        std.debug.print("  RESULT: Chase-Lev is >2x faster than mutex under contention.\n", .{});
        std.debug.print("          KEEP Chase-Lev — the complexity pays for itself.\n", .{});
    }

    std.debug.print("\n  Falsifiability threshold: if mutex within 2x of Chase-Lev under contention,\n", .{});
    std.debug.print("  prefer mutex (simpler). SPSC shown as lower bound — no stealing overhead.\n", .{});
}
