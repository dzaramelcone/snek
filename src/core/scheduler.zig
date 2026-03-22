//! Top-level scheduler orchestrator. Generic over IO for simulation testing.
//! Owns WorkerPool(IO), timers, and the accept queue. Entry point for the runtime.
//!
//! Three-tier backpressure (TigerBeetle/design.md):
//!   1. Per-worker deque has fixed capacity. When full, worker stops accepting.
//!   2. Accept queue (between TCP accept loop and workers) is bounded.
//!      When full, stop calling accept() — TCP backlog absorbs pressure.
//!   3. TCP listen backlog (OS-level). When full, kernel refuses connections.
//!
//! Process dies on panic (v1). Let process manager (systemd/k8s) restart.

const std = @import("std");
const worker = @import("worker.zig");
const timer = @import("timer.zig");
const coroutine = @import("coroutine.zig");

pub const SchedulerMetrics = struct {
    coroutines_spawned: u64,
    coroutines_completed: u64,
    coroutines_cancelled: u64,
    steal_attempts: u64,
    steal_successes: u64,
    poll_count: u64,
    accept_queue_depth: u64,
    backpressure_events: u64,
};

pub const ShutdownConfig = struct {
    http_drain_timeout_ms: u32 = 30_000,
    ws_drain_timeout_ms: u32 = 5_000,
    task_drain_timeout_ms: u32 = 10_000,
    force_shutdown_timeout_ms: u32 = 5_000,
};

pub const SchedulerConfig = struct {
    num_threads: u32 = 0, // 0 = auto-detect CPU count
    accept_queue_capacity: u32 = 1024,
    tcp_backlog: u31 = 128,
    shutdown: ShutdownConfig = .{},
};

const zero_metrics = SchedulerMetrics{
    .coroutines_spawned = 0,
    .coroutines_completed = 0,
    .coroutines_cancelled = 0,
    .steal_attempts = 0,
    .steal_successes = 0,
    .poll_count = 0,
    .accept_queue_depth = 0,
    .backpressure_events = 0,
};

/// Scheduler parameterized on the IO backend type.
/// In production: Scheduler(IoUring) or Scheduler(Kqueue).
/// In tests: Scheduler(FakeIO) for deterministic simulation.
// Inspired by: TigerBeetle (refs/tigerbeetle/INSIGHTS.md) — generic-over-IO pattern
// Inspired by: TigerBeetle (refs/tigerbeetle/INSIGHTS.md) — three-tier backpressure
pub fn Scheduler(comptime IO: type) type {
    return struct {
        const Self = @This();

        pool: worker.WorkerPool(IO),
        timers: timer.TimerWheel,
        config: SchedulerConfig,
        running: bool,
        metrics: SchedulerMetrics,
        accept_queue: coroutine.FrameQueue,
        accept_queue_capacity: u32,
        next_worker: u32,

        pub fn init(allocator: std.mem.Allocator, config: SchedulerConfig) !Self {
            const num_threads = if (config.num_threads == 0)
                @as(u32, @intCast(@max(1, std.Thread.getCpuCount() catch 1)))
            else
                config.num_threads;

            return Self{
                .pool = try worker.WorkerPool(IO).init(allocator, num_threads, .{}),
                .timers = timer.TimerWheel.init(allocator, 1_000_000), // 1ms tick
                .config = config,
                .running = false,
                .metrics = zero_metrics,
                .accept_queue = coroutine.FrameQueue.init(),
                .accept_queue_capacity = config.accept_queue_capacity,
                .next_worker = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit();
            self.timers.deinit();
        }

        /// One iteration of the main loop. Tests call this directly.
        pub fn tick(self: *Self) void {
            self.timers.tick();
            // Dispatch from accept queue to workers round-robin.
            // Check deque capacity before pushing — if full, leave the frame
            // in the accept queue (backpressure propagates per design.md §1.2).
            while (self.accept_queue.len > 0) {
                const idx = self.next_worker;
                // Three-tier backpressure: if worker's deque is full, don't push.
                // The frame stays in the accept queue. If the accept queue fills,
                // spawnCoroutine returns BackpressureFull. If TCP backlog fills,
                // kernel refuses connections.
                if (self.pool.workers[idx].local_deque.isFull()) break;
                const frame = self.accept_queue.pop() orelse break;
                self.next_worker = (idx + 1) % self.pool.num_threads;
                self.pool.pushAndWake(idx, @intFromPtr(frame));
            }
            self.metrics.accept_queue_depth = self.accept_queue.len;
            self.metrics.poll_count += 1;
        }

        /// Run the scheduler. Starts the worker pool, loops tick(), and on exit
        /// always completes the TLA+ lifecycle: start → stop → join → done.
        /// (See specs/worker_lifecycle.tla MainStart → MainStop → MainJoin)
        pub fn run(self: *Self) !void {
            try self.pool.start();
            self.running = true;
            while (self.running) {
                self.tick();
                // Avoid busy-looping when idle. In production, IO.poll() blocks
                // until completions arrive. With FakeIO, we need an explicit yield.
                if (self.accept_queue.len == 0) {
                    std.Thread.yield() catch {};
                }
            }
            // Finding 1 fix: run() must complete the lifecycle.
            // shutdown() sets running=false, run() exits the loop, then we
            // stop+join the pool here — matching the spec's full sequence.
            self.pool.stop();
        }

        /// Signal the scheduler to stop. run() will exit its loop and
        /// complete the shutdown sequence (pool.stop + join).
        pub fn shutdown(self: *Self) void {
            self.running = false;
        }

        /// Graceful shutdown: drain accept queue into workers, then stop.
        /// Workers finish processing their deque items before exiting
        /// (the deque is drained by the worker's runLoop naturally).
        /// Note: does NOT wait for worker deques to empty — workers drain
        /// their own deques as part of their runLoop before parking/exiting.
        pub fn gracefulShutdown(self: *Self) void {
            self.running = false;
            // Drain accept queue into workers (only if pool is started).
            if (self.pool.state == .started) {
                while (self.accept_queue.len > 0) {
                    self.tick();
                }
                self.pool.stop();
            }
        }

        /// Spawn a coroutine into the accept queue.
        /// Requires the scheduler to be running (pool started).
        /// Returns BackpressureFull if the accept queue is at capacity.
        pub fn spawnCoroutine(self: *Self, frame: *coroutine.CoroutineFrame) error{ BackpressureFull, NotRunning }!void {
            if (!self.running) return error.NotRunning;
            if (self.accept_queue.len >= self.accept_queue_capacity) {
                self.metrics.backpressure_events += 1;
                return error.BackpressureFull;
            }
            self.accept_queue.push(frame);
            self.metrics.coroutines_spawned += 1;
            self.metrics.accept_queue_depth = self.accept_queue.len;
        }

        pub fn cancelCoroutine(self: *Self, frame: *coroutine.CoroutineFrame) void {
            // Only count as cancelled if not already cancelled.
            if (frame.state != .cancelled) {
                frame.cancel();
                self.metrics.coroutines_cancelled += 1;
            }
        }

        pub fn getMetrics(self: *const Self) SchedulerMetrics {
            return self.metrics;
        }
    };
}

// ---- Tests ----

const FakeIO = @import("fake_io.zig").FakeIO;
const testing = std.testing;

test "scheduler init and deinit" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 2 });
    defer s.deinit();

    try testing.expectEqual(@as(u32, 2), s.pool.num_threads);
    try testing.expect(!s.running);
    try testing.expectEqual(@as(u64, 0), s.metrics.coroutines_spawned);
}

test "scheduler spawn and dispatch" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 2 });
    defer s.deinit();
    s.running = true;

    var frame = coroutine.CoroutineFrame.create(1);
    try s.spawnCoroutine(&frame);
    try testing.expectEqual(@as(u64, 1), s.metrics.coroutines_spawned);
    try testing.expectEqual(@as(usize, 1), s.accept_queue.len);

    // tick() dispatches to worker 0's deque
    s.tick();
    try testing.expectEqual(@as(usize, 0), s.accept_queue.len);
    try testing.expectEqual(@as(usize, 1), s.pool.workers[0].local_deque.len());
}

test "scheduler round-robin dispatch" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 4 });
    defer s.deinit();
    s.running = true;

    var frames: [4]coroutine.CoroutineFrame = undefined;
    for (0..4) |i| {
        frames[i] = coroutine.CoroutineFrame.create(@intCast(i));
        try s.spawnCoroutine(&frames[i]);
    }

    s.tick();

    // Each worker should have exactly 1 item
    for (0..4) |i| {
        try testing.expectEqual(@as(usize, 1), s.pool.workers[i].local_deque.len());
    }
}

test "scheduler backpressure" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{
        .num_threads = 1,
        .accept_queue_capacity = 2,
    });
    defer s.deinit();
    s.running = true;

    var f1 = coroutine.CoroutineFrame.create(1);
    var f2 = coroutine.CoroutineFrame.create(2);
    var f3 = coroutine.CoroutineFrame.create(3);

    try s.spawnCoroutine(&f1);
    try s.spawnCoroutine(&f2);

    // Queue is full (capacity 2), next spawn should fail
    const result = s.spawnCoroutine(&f3);
    try testing.expectError(error.BackpressureFull, result);
    try testing.expectEqual(@as(u64, 1), s.metrics.backpressure_events);
    try testing.expectEqual(@as(u64, 2), s.metrics.coroutines_spawned);
}

test "scheduler shutdown" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    s.running = true;
    s.shutdown();
    try testing.expect(!s.running);
}

test "scheduler metrics" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{
        .num_threads = 1,
        .accept_queue_capacity = 2,
    });
    defer s.deinit();
    s.running = true;

    var f1 = coroutine.CoroutineFrame.create(1);
    var f2 = coroutine.CoroutineFrame.create(2);
    var f3 = coroutine.CoroutineFrame.create(3);

    try s.spawnCoroutine(&f1);
    try s.spawnCoroutine(&f2);
    _ = s.spawnCoroutine(&f3) catch {}; // backpressure

    s.cancelCoroutine(&f1);

    const m = s.getMetrics();
    try testing.expectEqual(@as(u64, 2), m.coroutines_spawned);
    try testing.expectEqual(@as(u64, 1), m.coroutines_cancelled);
    try testing.expectEqual(@as(u64, 1), m.backpressure_events);
}

test "scheduler generic over fake io" {
    const TestScheduler = Scheduler(FakeIO);
    var s = try TestScheduler.init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    try testing.expectEqual(@as(u32, 1), s.pool.num_threads);
}

test "scheduler tick advances timers" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    var fired: u64 = 0;
    const cb = struct {
        var counter: *u64 = undefined;
        fn callback(_: u64) void {
            counter.* += 1;
        }
    };
    cb.counter = &fired;

    // Schedule timer to fire after 2 ticks (2ms with 1ms tick_ns)
    _ = s.timers.schedule(2_000_000, cb.callback, 0);

    s.tick(); // tick 1 — not yet
    try testing.expectEqual(@as(u64, 0), fired);

    s.tick(); // tick 2 — fires
    try testing.expectEqual(@as(u64, 1), fired);
}

test "scheduler dispatch preserves frame pointer" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();
    s.running = true;

    var frame = coroutine.CoroutineFrame.create(42);
    try s.spawnCoroutine(&frame);
    s.tick();

    // Worker's deque has the frame as a u64. Verify the pointer round-trips.
    const raw = s.pool.workers[0].local_deque.pop().?;
    const recovered: *coroutine.CoroutineFrame = @ptrFromInt(raw);
    try testing.expectEqual(@as(u64, 42), recovered.id);
    try testing.expectEqual(&frame, recovered);
}

test "scheduler graceful shutdown drains accept queue" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 2 });
    defer s.deinit();

    // Must be running to spawn — start pool first.
    try s.pool.start();
    s.running = true;

    var f1 = coroutine.CoroutineFrame.create(1);
    var f2 = coroutine.CoroutineFrame.create(2);
    try s.spawnCoroutine(&f1);
    try s.spawnCoroutine(&f2);

    try testing.expectEqual(@as(usize, 2), s.accept_queue.len);

    // gracefulShutdown drains accept queue into workers, then stops pool.
    s.gracefulShutdown();
    try testing.expect(!s.running);
    try testing.expectEqual(@as(usize, 0), s.accept_queue.len);
}

// ── Edge cases ──────────────────────────────────────────────────────

test "edge: tick with empty accept queue is no-op" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    s.tick();
    s.tick();
    s.tick();
    try testing.expectEqual(@as(u64, 3), s.metrics.poll_count);
    try testing.expectEqual(@as(usize, 0), s.pool.workers[0].local_deque.len());
}

test "edge: spawn after shutdown returns NotRunning" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    s.shutdown();

    // Spawning after shutdown is rejected — matches TLA+ spec's started window.
    var f = coroutine.CoroutineFrame.create(1);
    const result = s.spawnCoroutine(&f);
    try testing.expectError(error.NotRunning, result);
    try testing.expectEqual(@as(u64, 0), s.metrics.coroutines_spawned);
}

test "edge: cancel already-cancelled coroutine" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    var f = coroutine.CoroutineFrame.create(1);
    s.cancelCoroutine(&f);
    s.cancelCoroutine(&f); // double cancel — idempotent, only counted once

    // Metrics: only 1 cancellation counted (second is a no-op)
    try testing.expectEqual(@as(u64, 1), s.metrics.coroutines_cancelled);
    try testing.expectEqual(coroutine.CoroutineState.cancelled, f.state);
}

test "edge: dispatch more frames than workers" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 2 });
    defer s.deinit();
    s.running = true;

    var frames: [5]coroutine.CoroutineFrame = undefined;
    for (0..5) |i| {
        frames[i] = coroutine.CoroutineFrame.create(@intCast(i));
        try s.spawnCoroutine(&frames[i]);
    }

    s.tick();

    // Round-robin: worker 0 gets 0,2,4 — worker 1 gets 1,3
    try testing.expectEqual(@as(usize, 3), s.pool.workers[0].local_deque.len());
    try testing.expectEqual(@as(usize, 2), s.pool.workers[1].local_deque.len());
}
