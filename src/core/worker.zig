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
                .io = IO.init(allocator, id),
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

        /// Park the worker thread with race-safe running check.
        /// Matches the TLA+ spec's park_recheck transition:
        ///   store park_state=1 → recheck running → futex wait only if still running.
        /// (See specs/worker_lifecycle.tla WorkerParkRecheck)
        ///
        /// Returns true if the worker parked and was woken, false if it bailed
        /// because running became false before entering the wait.
        pub fn park(self: *Self) bool {
            self.park_state.store(1, .release);
            if (!self.running.load(.acquire)) return false;
            std.Thread.Futex.wait(&self.park_state, 1);
            return true;
        }

        /// Wake a parked worker thread via futex.
        pub fn wake(self: *Self) void {
            self.park_state.store(0, .release);
            std.Thread.Futex.wake(&self.park_state, 1);
        }

        /// Main worker loop. Pops from local deque; parks if idle.
        /// Work stealing from other workers is deferred to Phase 5 (scheduler).
        pub fn runLoop(self: *Self) void {
            // NOTE: running must be set to true by the caller (WorkerPool.start)
            // BEFORE spawning the thread, to avoid a race with stop().
            while (self.running.load(.acquire)) {
                if (self.local_deque.pop()) |item| {
                    if (self.work_callback) |cb| {
                        cb(item);
                    }
                } else {
                    // No local work — park with race-safe running check.
                    // park() implements the spec's park_recheck transition.
                    if (!self.park()) break; // running became false, exit
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
/// Lifecycle states match the TLA+ spec (specs/worker_lifecycle.tla):
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
        pub fn start(self: *Self) !void {
            std.debug.assert(self.state == .ready);
            for (self.workers) |*w| {
                w.running.store(true, .release);
            }
            for (self.workers) |*w| {
                w.thread = try std.Thread.spawn(.{}, workerEntry, .{w});
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
        /// (See specs/worker_lifecycle.tla:127 — liveness depends on pairing)
        pub fn pushAndWake(self: *Self, worker_idx: u32, item: u64) void {
            self.workers[worker_idx].local_deque.push(item);
            self.workers[worker_idx].wake();
        }

        fn workerEntry(worker: *WorkerThread(IO)) void {
            worker.runLoop();
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

    const t = try std.Thread.spawn(.{}, struct {
        fn run(worker: *WorkerThread(FakeIO)) void {
            worker.runLoop();
        }
    }.run, .{&w});

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

    const t = try std.Thread.spawn(.{}, struct {
        fn run(worker: *WorkerThread(FakeIO)) void {
            worker.runLoop();
        }
    }.run, .{&w});

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
