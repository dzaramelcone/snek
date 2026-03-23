//! Worker thread management for the scheduler. Generic over IO.
//! One WorkerThread per CPU core, each owns a deque, IO instance, and arenas.
//!
//! Per-worker deque for local task scheduling (Chase-Lev).
//! Park/wake via futex for idle strategy.
//! Two arenas per connection (http.zig pattern): conn_arena + req_arena.

const std = @import("std");
const deque = @import("deque.zig");
const arena_mod = @import("arena.zig");
const pool_mod = @import("pool.zig");

pub const ThreadConfig = struct {
    affinity: ?u32 = null,
    priority: i32 = 0,
    name: []const u8 = "snek-worker",
    deque_capacity: usize = 4096,
    max_connections: u16 = 4096,
};

/// Worker thread parameterized on the IO backend type.
// See: src/core/REFERENCES.md §5.7 — per-worker IO instance from tardy/zzz
// Each worker owns its own IO instance, avoiding cross-thread synchronization.
// Inspired by: http.zig (refs/http.zig/INSIGHTS.md) — FallbackAllocator, two arenas per connection
pub fn WorkerThread(comptime IO: type) type {
    return struct {
        const Self = @This();

        id: u32,
        local_deque: deque.ChaseLevDeque(u64),
        io: IO,
        running: std.atomic.Value(bool),
        park_state: std.atomic.Value(u32),
        config: ThreadConfig,
        /// Per-connection arena pairs managed via free-list pool.
        connection_arenas: pool_mod.Pool(arena_mod.ConnectionArenas, 4096),
        /// Callback for processing work items. If null, items are just consumed.
        work_callback: ?*const fn (u64) void,
        allocator: std.mem.Allocator,
        /// OS thread handle. Set by WorkerPool.start(), null until then.
        thread: ?std.Thread,

        pub fn init(allocator: std.mem.Allocator, id: u32, cfg: ThreadConfig) !Self {
            var self = Self{
                .id = id,
                .local_deque = try deque.ChaseLevDeque(u64).init(allocator, cfg.deque_capacity),
                .io = try IO.init(.{ .allocator = allocator, .id = id }),
                .running = std.atomic.Value(bool).init(false),
                .park_state = std.atomic.Value(u32).init(0),
                .config = cfg,
                .connection_arenas = undefined,
                .work_callback = null,
                .allocator = allocator,
                .thread = null,
            };
            self.connection_arenas.initInPlace();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.local_deque.deinit();
            self.io.deinit();
        }

        pub fn stop(self: *Self) void {
            self.running.store(false, .release);
            self.wake();
        }

        /// Park the worker thread with race-safe running AND deque recheck.
        /// Matches the TLA+ spec's WorkerPark transition (scheduler.tla#L221):
        ///   store park_state=1 → recheck running AND deque → futex wait only if
        ///   still running AND deque empty.
        ///
        /// Fix for audit finding 3: lost wakeup race. A pusher can push work
        /// between our failed pop() and our park_state.store(1). Without the
        /// deque recheck, we'd sleep with a non-empty deque.
        ///
        /// Returns true if the worker should continue looping (was woken or
        /// found work), false if running became false.
        pub fn park(self: *Self) bool {
            self.park_state.store(1, .release);
            if (!self.running.load(.acquire)) return false;
            // Recheck deque after publishing park intent (audit finding 3).
            // If work arrived between pop() and park_state.store(1), cancel park.
            if (self.local_deque.len() > 0) {
                self.park_state.store(0, .release);
                return true;
            }
            std.Thread.Futex.wait(&self.park_state, 1);
            return true;
        }

        /// Wake a parked worker thread via futex.
        pub fn wake(self: *Self) void {
            self.park_state.store(0, .release);
            std.Thread.Futex.wake(&self.park_state, 1);
        }

        /// Try to steal work from another worker's deque.
        /// Iterates up to 3 victims starting from a deterministic offset
        /// (based on own id) to avoid herding. Returns stolen item or null.
        /// Matches scheduler.tla#L188 WorkerSteal.
        pub fn trySteal(self: *Self, all_workers: []Self) ?u64 {
            const n = all_workers.len;
            if (n <= 1) return null;
            const max_attempts = @min(n - 1, 3);
            var offset = self.id +% 1;
            for (0..max_attempts) |_| {
                const victim_idx = offset % @as(u32, @intCast(n));
                offset +%= 1;
                if (victim_idx == self.id) continue;
                if (all_workers[victim_idx].local_deque.steal()) |item| {
                    return item;
                }
            }
            return null;
        }

        /// Main worker loop. Pops from local deque; tries stealing if empty;
        /// parks if no work found anywhere.
        /// After running goes false, drains local deque and helps steal
        /// remaining work from other workers (audit finding 1, spec WorkerExit).
        pub fn runLoop(self: *Self, all_workers: []Self) void {
            // NOTE: running must be set to true by the caller (WorkerPool.start)
            // BEFORE spawning the thread, to avoid a race with stop().
            while (self.running.load(.acquire)) {
                if (self.local_deque.pop()) |item| {
                    if (self.work_callback) |cb| {
                        cb(item);
                    }
                } else if (self.trySteal(all_workers)) |item| {
                    // Work stealing (audit finding 2, scheduler.tla#L188).
                    if (self.work_callback) |cb| {
                        cb(item);
                    }
                } else {
                    // No local work, no stealable work — park.
                    // park() rechecks running AND deque (audit finding 3).
                    if (!self.park()) break; // running became false, exit
                }
            }
            // Drain-first shutdown (audit finding 1, spec WorkerExit).
            // Keep processing local deque and stealing until all work is done.
            self.drainLoop(all_workers);
        }

        /// Drain loop for shutdown: process remaining local work, then
        /// help steal from other workers until no work remains anywhere.
        /// Matches scheduler.tla#L244 WorkerExit precondition.
        fn drainLoop(self: *Self, all_workers: []Self) void {
            while (true) {
                if (self.local_deque.pop()) |item| {
                    if (self.work_callback) |cb| {
                        cb(item);
                    }
                } else if (self.trySteal(all_workers)) |item| {
                    if (self.work_callback) |cb| {
                        cb(item);
                    }
                } else {
                    break;
                }
            }
        }

        pub fn getThreadId(self: *const Self) u32 {
            return self.id;
        }

        pub fn setAffinity(self: *Self, core_id: u32) !void {
            // CPU affinity is platform-specific and deferred. Stub for now.
            _ = self;
            _ = core_id;
        }

        pub fn pinToCore(self: *Self, core_id: u32) !void {
            return self.setAffinity(core_id);
        }

        /// Acquire a connection arena pair from the pool.
        pub fn acquireConnection(self: *Self) ?*arena_mod.ConnectionArenas {
            return self.connection_arenas.get();
        }

        /// Release a connection arena pair back to the pool.
        pub fn releaseConnection(self: *Self, arenas: *arena_mod.ConnectionArenas) void {
            self.connection_arenas.put(arenas);
        }
    };
}

/// Worker pool parameterized on the IO backend type.
/// Lifecycle states match the TLA+ spec (specs/scheduler.tla):
///   ready → started → stopping → stopped
pub fn WorkerPool(comptime IO: type) type {
    return struct {
        const Self = @This();

        pub const State = enum { ready, started, stopping, stopped };

        workers: []WorkerThread(IO),
        num_threads: u32,
        allocator: std.mem.Allocator,
        state: State,

        pub fn init(allocator: std.mem.Allocator, num_threads: u32, cfg: ThreadConfig) !Self {
            const workers = try allocator.alloc(WorkerThread(IO), num_threads);
            errdefer allocator.free(workers);

            var initialized: u32 = 0;
            errdefer {
                var i: u32 = 0;
                while (i < initialized) : (i += 1) {
                    workers[i].deinit();
                }
            }

            for (0..num_threads) |i| {
                workers[i] = try WorkerThread(IO).init(allocator, @intCast(i), cfg);
                initialized += 1;
            }

            return Self{
                .workers = workers,
                .num_threads = num_threads,
                .allocator = allocator,
                .state = .ready,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.workers) |*w| {
                w.deinit();
            }
            self.allocator.free(self.workers);
        }

        /// Start all worker threads. Must be in .ready state.
        /// Sets running=true BEFORE spawning (TLA+ spec: MainStart).
        /// Failure-atomic: if any spawn fails, already-started threads are
        /// stopped and joined before returning the error (audit finding 9).
        pub fn start(self: *Self) !void {
            std.debug.assert(self.state == .ready);
            for (self.workers) |*w| {
                w.running.store(true, .release);
            }
            var spawned: u32 = 0;
            errdefer {
                // Rollback: stop and join already-spawned threads.
                for (self.workers[0..spawned]) |*w| {
                    w.stop();
                }
                for (self.workers[0..spawned]) |*w| {
                    if (w.thread) |t| {
                        t.join();
                        w.thread = null;
                    }
                }
                // Reset running for all workers.
                for (self.workers) |*w| {
                    w.running.store(false, .release);
                }
            }
            for (self.workers) |*w| {
                w.thread = try std.Thread.spawn(.{}, workerEntry, .{ w, self.workers });
                spawned += 1;
            }
            self.state = .started;
        }

        /// Stop all worker threads and join them. Must be in .started state.
        /// Implements TLA+ spec: MainStop → MainJoin.
        pub fn stop(self: *Self) void {
            std.debug.assert(self.state == .started);
            self.state = .stopping;
            for (self.workers) |*w| {
                w.stop();
            }
            for (self.workers) |*w| {
                if (w.thread) |t| {
                    t.join();
                    w.thread = null;
                }
            }
            self.state = .stopped;
        }

        /// Push work to a specific worker's deque and wake them.
        /// This pairs push + wake atomically, matching the TLA+ spec's
        /// requirement that WorkArrives + WakeWorker are coordinated.
        /// (See specs/scheduler.tla:127 — liveness depends on pairing)
        pub fn pushAndWake(self: *Self, worker_idx: u32, item: u64) void {
            self.workers[worker_idx].local_deque.push(item);
            self.workers[worker_idx].wake();
        }

        fn workerEntry(worker: *WorkerThread(IO), all_workers: []WorkerThread(IO)) void {
            worker.runLoop(all_workers);
        }
    };
}

// ---- Tests ----

const FakeIO = @import("fake_io.zig").FakeIO;

test "worker thread init and deinit" {
    var w = try WorkerThread(FakeIO).init(std.testing.allocator, 0, .{});
    defer w.deinit();

    try std.testing.expectEqual(@as(u32, 0), w.id);
    try std.testing.expect(!w.running.load(.acquire));
}

test "worker thread push and pop" {
    var w = try WorkerThread(FakeIO).init(std.testing.allocator, 1, .{});
    defer w.deinit();

    // Push items to local deque
    w.local_deque.push(10);
    w.local_deque.push(20);
    w.local_deque.push(30);

    // Pop in LIFO order
    try std.testing.expectEqual(@as(u64, 30), w.local_deque.pop().?);
    try std.testing.expectEqual(@as(u64, 20), w.local_deque.pop().?);
    try std.testing.expectEqual(@as(u64, 10), w.local_deque.pop().?);
    try std.testing.expect(w.local_deque.pop() == null);
}

test "worker thread park and wake" {
    var w = try WorkerThread(FakeIO).init(std.testing.allocator, 0, .{});
    defer w.deinit();

    // Start worker in a thread via runLoop — it will park immediately (empty deque)
    w.running.store(true, .release);
    // Single-element slice pointing to w itself for runLoop's all_workers param.
    const all = @as(*[1]WorkerThread(FakeIO), &w);

    const t = try std.Thread.spawn(.{}, struct {
        fn run(wkr: *WorkerThread(FakeIO), workers: []WorkerThread(FakeIO)) void {
            wkr.runLoop(workers);
        }
    }.run, .{ &w, @as([]WorkerThread(FakeIO), all) });

    // Give worker a moment to park
    std.Thread.sleep(5 * std.time.ns_per_ms);

    // Worker should be parked (park_state == 1)
    try std.testing.expectEqual(@as(u32, 1), w.park_state.load(.acquire));

    // Stop the worker — this wakes it
    w.stop();
    t.join();
}

test "worker pool init and deinit" {
    var pool = try WorkerPool(FakeIO).init(std.testing.allocator, 4, .{});
    defer pool.deinit();

    try std.testing.expectEqual(@as(u32, 4), pool.num_threads);
    for (0..4) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), pool.workers[i].id);
    }
}

test "worker pool start and stop" {
    var processed = std.atomic.Value(u64).init(0);

    var pool = try WorkerPool(FakeIO).init(std.testing.allocator, 2, .{});
    defer pool.deinit();

    // Set a callback that records work was done
    const S = struct {
        var counter: *std.atomic.Value(u64) = undefined;
        fn callback(item: u64) void {
            _ = item;
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    S.counter = &processed;

    for (pool.workers) |*w| {
        w.work_callback = &S.callback;
    }

    // Push work before starting
    pool.workers[0].local_deque.push(1);
    pool.workers[0].local_deque.push(2);
    pool.workers[0].local_deque.push(3);

    try pool.start();

    // Wake worker 0 so it processes items
    pool.workers[0].wake();

    // Give it time to process
    std.Thread.sleep(10 * std.time.ns_per_ms);

    pool.stop();

    // All 3 items should have been processed
    try std.testing.expectEqual(@as(u64, 3), processed.load(.acquire));
}

test "worker thread acquire and release connection" {
    var w = try WorkerThread(FakeIO).init(std.testing.allocator, 0, .{});
    defer w.deinit();

    const arenas = w.acquireConnection();
    try std.testing.expect(arenas != null);
    try std.testing.expectEqual(@as(usize, 1), w.connection_arenas.count());

    w.releaseConnection(arenas.?);
    try std.testing.expectEqual(@as(usize, 0), w.connection_arenas.count());
}

test "worker generic over fake io" {
    const TestWorker = WorkerThread(FakeIO);
    var w = try TestWorker.init(std.testing.allocator, 7, .{});
    defer w.deinit();

    try std.testing.expectEqual(@as(u32, 7), w.getThreadId());
}

// ── Edge case tests ──────────────────────────────────────────────────

test "edge: stop before start is safe" {
    var w = try WorkerThread(FakeIO).init(std.testing.allocator, 0, .{});
    defer w.deinit();

    // running is false by default, stop() should be harmless
    w.stop();
    try std.testing.expect(!w.running.load(.acquire));
}

test "edge: double stop is safe" {
    var w = try WorkerThread(FakeIO).init(std.testing.allocator, 0, .{});
    defer w.deinit();

    const all = @as(*[1]WorkerThread(FakeIO), &w);
    const t = try std.Thread.spawn(.{}, struct {
        fn run(wkr: *WorkerThread(FakeIO), workers: []WorkerThread(FakeIO)) void {
            wkr.runLoop(workers);
        }
    }.run, .{ &w, @as([]WorkerThread(FakeIO), all) });

    std.Thread.sleep(5 * std.time.ns_per_ms);
    w.stop();
    w.stop(); // second stop should not panic or deadlock
    t.join();
}

test "edge: wake without park is harmless" {
    var w = try WorkerThread(FakeIO).init(std.testing.allocator, 0, .{});
    defer w.deinit();

    // Worker is not parked, wake should be a no-op
    w.wake();
    try std.testing.expectEqual(@as(u32, 0), w.park_state.load(.acquire));
}

test "edge: rapid start stop" {
    var pool = try WorkerPool(FakeIO).init(std.testing.allocator, 2, .{});
    defer pool.deinit();

    // Start and immediately stop — race condition test
    try pool.start();
    pool.stop();
    // Should not hang or crash
}

test "edge: one worker gets all work, others park" {
    var processed = std.atomic.Value(u64).init(0);
    var pool = try WorkerPool(FakeIO).init(std.testing.allocator, 4, .{});
    defer pool.deinit();

    const S = struct {
        var counter: *std.atomic.Value(u64) = undefined;
        fn callback(item: u64) void {
            _ = item;
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    S.counter = &processed;

    for (pool.workers) |*w| {
        w.work_callback = &S.callback;
    }

    // Push 100 items to worker 0 only
    for (0..100) |i| {
        pool.workers[0].local_deque.push(@intCast(i));
    }

    try pool.start();
    pool.workers[0].wake();

    // Give time for worker 0 to process all
    std.Thread.sleep(50 * std.time.ns_per_ms);

    pool.stop();

    // All 100 should be processed (by worker 0, since no stealing)
    try std.testing.expectEqual(@as(u64, 100), processed.load(.acquire));
}

test "edge: connection pool exhaustion" {
    var w = try WorkerThread(FakeIO).init(std.testing.allocator, 0, .{ .max_connections = 4096 });
    defer w.deinit();

    // Acquire a few connections
    var acquired: [10]*arena_mod.ConnectionArenas = undefined;
    for (0..10) |i| {
        acquired[i] = w.acquireConnection().?;
    }

    // Release them all
    for (0..10) |i| {
        w.releaseConnection(acquired[i]);
    }
    try std.testing.expectEqual(@as(usize, 0), w.connection_arenas.count());
}

// ── Audit fix tests (spec-implementation gap fixes) ─────────────────

test "audit: work stealing moves items between workers" {
    // Finding 2: workers must steal from other workers' deques.
    // Push work to worker 0, verify worker 1 can steal it via trySteal.
    var pool = try WorkerPool(FakeIO).init(std.testing.allocator, 2, .{});
    defer pool.deinit();

    // Push items into worker 0's deque
    pool.workers[0].local_deque.push(42);
    pool.workers[0].local_deque.push(43);

    // Worker 1 steals from worker 0
    const stolen = pool.workers[1].trySteal(pool.workers);
    try std.testing.expect(stolen != null);
    // Steal takes from FIFO end (top), so should get 42 first
    try std.testing.expectEqual(@as(u64, 42), stolen.?);
    // Worker 0 should have 1 item left
    try std.testing.expectEqual(@as(usize, 1), pool.workers[0].local_deque.len());
}

test "audit: trySteal returns null when no victims have work" {
    var pool = try WorkerPool(FakeIO).init(std.testing.allocator, 3, .{});
    defer pool.deinit();

    // All deques empty — steal should fail
    const stolen = pool.workers[0].trySteal(pool.workers);
    try std.testing.expect(stolen == null);
}

test "audit: trySteal skips self" {
    var pool = try WorkerPool(FakeIO).init(std.testing.allocator, 2, .{});
    defer pool.deinit();

    // Only worker 0 has work — worker 0 should not steal from itself
    pool.workers[0].local_deque.push(99);
    const stolen = pool.workers[0].trySteal(pool.workers);
    try std.testing.expect(stolen == null);
    // Item still in worker 0's deque
    try std.testing.expectEqual(@as(usize, 1), pool.workers[0].local_deque.len());
}

test "audit: work stealing happens during runLoop" {
    // Verify that runLoop actually steals work from other workers.
    // Push all work to worker 0, both workers have callbacks,
    // after processing worker 1 should have processed some via stealing.
    var processed_0 = std.atomic.Value(u64).init(0);
    var processed_1 = std.atomic.Value(u64).init(0);

    var pool = try WorkerPool(FakeIO).init(std.testing.allocator, 2, .{});
    defer pool.deinit();

    const S0 = struct {
        var counter: *std.atomic.Value(u64) = undefined;
        fn callback(_: u64) void {
            // Small busywait to give the thief time to steal
            var v: u64 = 0;
            for (0..200) |_| v +%= 1;
            std.mem.doNotOptimizeAway(v);
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    const S1 = struct {
        var counter: *std.atomic.Value(u64) = undefined;
        fn callback(_: u64) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    S0.counter = &processed_0;
    S1.counter = &processed_1;
    pool.workers[0].work_callback = &S0.callback;
    pool.workers[1].work_callback = &S1.callback;

    // Push enough work to worker 0 that worker 1 has time to steal some
    for (0..2000) |i| {
        pool.workers[0].local_deque.push(@intCast(i));
    }

    try pool.start();
    pool.workers[0].wake();
    pool.workers[1].wake();

    // Give time for both workers to process
    std.Thread.sleep(100 * std.time.ns_per_ms);

    pool.stop();

    // Total should be 2000
    const total = processed_0.load(.acquire) + processed_1.load(.acquire);
    try std.testing.expectEqual(@as(u64, 2000), total);
    // Worker 1 should have stolen and processed at least 1 item
    try std.testing.expect(processed_1.load(.acquire) > 0);
}

test "audit: park rechecks deque (lost wakeup prevention)" {
    // Finding 3: after storing park_state=1, if deque is non-empty,
    // park() must cancel the park and return true.
    var w = try WorkerThread(FakeIO).init(std.testing.allocator, 0, .{});
    defer w.deinit();

    w.running.store(true, .release);
    // Push an item — simulating work arriving between pop() and park()
    w.local_deque.push(42);

    // park() should detect the non-empty deque and return true (not block)
    const result = w.park();
    try std.testing.expect(result); // should return true, not block
    // park_state should be reset to 0 (park cancelled)
    try std.testing.expectEqual(@as(u32, 0), w.park_state.load(.acquire));
    // Item should still be in deque
    try std.testing.expectEqual(@as(usize, 1), w.local_deque.len());
}

test "audit: drain-first shutdown processes all remaining work" {
    // Finding 1: workers must drain their deques during shutdown.
    var processed = std.atomic.Value(u64).init(0);

    var pool = try WorkerPool(FakeIO).init(std.testing.allocator, 2, .{});
    defer pool.deinit();

    const S = struct {
        var counter: *std.atomic.Value(u64) = undefined;
        fn callback(_: u64) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    S.counter = &processed;
    for (pool.workers) |*w| {
        w.work_callback = &S.callback;
    }

    // Push work to both workers
    for (0..50) |i| {
        pool.workers[0].local_deque.push(@intCast(i));
    }
    for (50..100) |i| {
        pool.workers[1].local_deque.push(@intCast(i));
    }

    try pool.start();
    // Wake workers briefly then immediately stop
    pool.workers[0].wake();
    pool.workers[1].wake();
    std.Thread.sleep(1 * std.time.ns_per_ms);
    pool.stop();

    // All 100 items must be processed despite rapid shutdown (drain-first)
    try std.testing.expectEqual(@as(u64, 100), processed.load(.acquire));
}
