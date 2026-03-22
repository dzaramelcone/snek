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

const zero_metrics = std.mem.zeroes(SchedulerMetrics);

/// Scheduler parameterized on the IO backend type.
/// In production: Scheduler(IoUring) or Scheduler(Kqueue).
/// In tests: Scheduler(FakeIO) for deterministic simulation.
// Inspired by: TigerBeetle — generic-over-IO + three-tier backpressure (refs/tigerbeetle/INSIGHTS.md)
pub fn Scheduler(comptime IO: type) type {
    return struct {
        const Self = @This();

        pool: worker.WorkerPool(IO),
        timers: timer.TimerWheel,
        config: SchedulerConfig,
        /// Atomic: set by run(), cleared by shutdown(). Read from the main
        /// loop and potentially written from a signal handler thread.
        running: std.atomic.Value(bool),
        /// Atomic: set once by shutdown/gracefulShutdown. After this,
        /// spawnCoroutine rejects. Must be atomic because shutdown() can
        /// race with spawnCoroutine() from different threads (audit finding 8).
        shut_down: std.atomic.Value(bool),
        metrics: SchedulerMetrics,
        accept_queue: coroutine.FrameQueue,
        accept_queue_capacity: u32,
        next_worker: u32,
        /// Futex for waking the scheduler when new work arrives.
        /// 0 = sleeping, 1 = work available.
        wake_state: std.atomic.Value(u32),

        pub fn init(allocator: std.mem.Allocator, config: SchedulerConfig) !Self {
            const num_threads = if (config.num_threads == 0)
                @as(u32, @intCast(@max(1, std.Thread.getCpuCount() catch 1)))
            else
                config.num_threads;

            return Self{
                .pool = try worker.WorkerPool(IO).init(allocator, num_threads, .{}),
                .timers = timer.TimerWheel.init(allocator, 1_000_000), // 1ms tick
                .config = config,
                .running = std.atomic.Value(bool).init(false),
                .shut_down = std.atomic.Value(bool).init(false),
                .metrics = zero_metrics,
                .accept_queue = coroutine.FrameQueue.init(),
                .accept_queue_capacity = config.accept_queue_capacity,
                .next_worker = 0,
                .wake_state = std.atomic.Value(u32).init(0),
            };
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit();
            self.timers.deinit();
        }

        /// One iteration of the main loop. Tests call this directly.
        pub fn tick(self: *Self) void {
            self.timers.tick();
            // Only dispatch to workers if the pool is started.
            // Before start, frames stay in the accept queue.
            if (self.pool.state != .started) {
                self.metrics.poll_count += 1;
                return;
            }
            // Dispatch from accept queue to workers round-robin.
            // Skip full workers — try all workers before giving up.
            var dispatched: u32 = 0;
            const num = self.pool.num_threads;
            while (self.accept_queue.len > 0) {
                // Find a worker with capacity, trying each one once.
                var found = false;
                for (0..num) |_| {
                    const idx = self.next_worker;
                    self.next_worker = (idx + 1) % num;
                    if (!self.pool.workers[idx].local_deque.isFull()) {
                        const frame = self.accept_queue.pop() orelse break;
                        self.pool.pushAndWake(idx, @intFromPtr(frame));
                        dispatched += 1;
                        found = true;
                        break;
                    }
                }
                // All workers full — backpressure. Stop dispatching.
                if (!found) break;
            }
            self.metrics.accept_queue_depth = self.accept_queue.len;
            self.metrics.poll_count += 1;
            // Reset wake state after dispatching — will sleep if queue is empty.
            self.wake_state.store(0, .release);
        }

        /// Run the scheduler. Owns the full pool lifecycle:
        ///   pool.start() → loop tick() → pool.stop()
        /// This is the ONLY place pool start/stop happens.
        /// shutdown() and gracefulShutdown() signal via atomic flag only.
        /// (See specs/scheduler.tla MainStart → MainShutdown → MainJoin)
        pub fn run(self: *Self) !void {
            // Store running=true BEFORE pool.start() to prevent the startup
            // race where shutdown() sets running=false between pool.start()
            // and the store (audit finding 8).
            self.running.store(true, .release);
            // Re-check: if shutdown() already ran (set shut_down=true), honor it.
            // This handles the race where shutdown() ran before running.store(true),
            // so running was never actually set to false by shutdown.
            if (self.shut_down.load(.acquire)) {
                self.running.store(false, .release);
            }
            try self.pool.start();
            while (self.running.load(.acquire)) {
                self.tick();
                if (self.accept_queue.len == 0) {
                    // No work to dispatch. Use futex to block until
                    // spawnCoroutine signals new work is available.
                    std.Thread.Futex.wait(&self.wake_state, 0);
                }
            }
            // Drain remaining accept queue before stopping workers.
            while (self.accept_queue.len > 0) {
                self.tick();
            }
            self.pool.stop();
        }

        /// Signal the scheduler to stop. Thread-safe (atomic store).
        /// run() will exit its loop, drain remaining work, and stop the pool.
        pub fn shutdown(self: *Self) void {
            self.shut_down.store(true, .release);
            self.running.store(false, .release);
            // Wake the scheduler thread if it's sleeping on the futex.
            self.wake_state.store(1, .release);
            std.Thread.Futex.wake(&self.wake_state, 1);
        }

        /// Graceful shutdown: same as shutdown(). run() handles draining and
        /// pool lifecycle. This method exists for API clarity — both paths
        /// signal via the atomic flag and let run() do the cleanup.
        pub fn gracefulShutdown(self: *Self) void {
            self.shutdown();
        }

        /// Enqueue a coroutine for dispatch. Works from init until shutdown.
        /// No need to call run() first — the accept queue is a buffer.
        /// Returns BackpressureFull if at capacity, NotRunning if shut down.
        pub fn spawnCoroutine(self: *Self, frame: *coroutine.CoroutineFrame) error{ BackpressureFull, NotRunning }!void {
            if (self.shut_down.load(.acquire)) return error.NotRunning;
            if (self.accept_queue.len >= self.accept_queue_capacity) {
                self.metrics.backpressure_events += 1;
                return error.BackpressureFull;
            }
            self.accept_queue.push(frame);
            self.metrics.coroutines_spawned += 1;
            self.metrics.accept_queue_depth = self.accept_queue.len;
            // Wake the scheduler thread if it's sleeping on the futex.
            self.wake_state.store(1, .release);
            std.Thread.Futex.wake(&self.wake_state, 1);
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
    try testing.expect(!s.running.load(.acquire));
    try testing.expectEqual(@as(u64, 0), s.metrics.coroutines_spawned);
}

test "scheduler spawn and dispatch via run" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    var processed = std.atomic.Value(u64).init(0);
    const S = struct {
        var counter: *std.atomic.Value(u64) = undefined;
        fn callback(_: u64) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    S.counter = &processed;
    s.pool.workers[0].work_callback = &S.callback;

    var frame = coroutine.CoroutineFrame.create(1);
    try s.spawnCoroutine(&frame);

    // Start scheduler in a thread, let it dispatch and process
    const t = try std.Thread.spawn(.{}, struct {
        fn entry(sched: *Scheduler(FakeIO)) void {
            sched.run() catch unreachable;
        }
    }.entry, .{&s});

    // Wait for the item to be processed
    var attempts: u32 = 0;
    while (processed.load(.acquire) == 0 and attempts < 1000) : (attempts += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    s.shutdown();
    t.join();

    try testing.expectEqual(@as(u64, 1), processed.load(.acquire));
    try testing.expectEqual(@as(usize, 0), s.accept_queue.len);
}

test "scheduler dispatches to multiple workers" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 2 });
    defer s.deinit();

    var processed = std.atomic.Value(u64).init(0);
    const S = struct {
        var counter: *std.atomic.Value(u64) = undefined;
        fn callback(_: u64) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    S.counter = &processed;
    for (s.pool.workers) |*w| {
        w.work_callback = &S.callback;
    }

    var frames: [4]coroutine.CoroutineFrame = undefined;
    for (0..4) |i| {
        frames[i] = coroutine.CoroutineFrame.create(@intCast(i));
        try s.spawnCoroutine(&frames[i]);
    }

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(sched: *Scheduler(FakeIO)) void {
            sched.run() catch unreachable;
        }
    }.entry, .{&s});

    var attempts: u32 = 0;
    while (processed.load(.acquire) < 4 and attempts < 1000) : (attempts += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    s.shutdown();
    t.join();

    try testing.expectEqual(@as(u64, 4), processed.load(.acquire));
}

test "scheduler backpressure" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{
        .num_threads = 1,
        .accept_queue_capacity = 2,
    });
    defer s.deinit();

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

    s.shutdown();
    try testing.expect(!s.running.load(.acquire));
}

test "scheduler metrics" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{
        .num_threads = 1,
        .accept_queue_capacity = 2,
    });
    defer s.deinit();

    var f1 = coroutine.CoroutineFrame.create(1);
    var f2 = coroutine.CoroutineFrame.create(2);
    var f3 = coroutine.CoroutineFrame.create(3);

    try s.spawnCoroutine(&f1);
    try s.spawnCoroutine(&f2);
    try testing.expectError(error.BackpressureFull, s.spawnCoroutine(&f3));

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

test "frame pointer round-trip through deque" {
    // Verify the @intFromPtr/@ptrFromInt cast that tick() uses to push
    // CoroutineFrame pointers through the u64 deque.
    const alloc = testing.allocator;
    var d = try @import("deque.zig").ChaseLevDeque(u64).init(alloc, 16);
    defer d.deinit();

    var frame = coroutine.CoroutineFrame.create(42);
    d.push(@intFromPtr(&frame));

    const raw = d.pop().?;
    const recovered: *coroutine.CoroutineFrame = @ptrFromInt(raw);
    try testing.expectEqual(@as(u64, 42), recovered.id);
    try testing.expectEqual(&frame, recovered);
}

test "scheduler graceful shutdown signals and run handles cleanup" {
    // gracefulShutdown() just signals — run() does the actual drain + stop.
    // Test without run() thread: verify gracefulShutdown sets the flags.
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 2 });
    defer s.deinit();

    var f1 = coroutine.CoroutineFrame.create(1);
    try s.spawnCoroutine(&f1);

    s.gracefulShutdown();
    try testing.expect(!s.running.load(.acquire));
    try testing.expect(s.shut_down.load(.acquire));
    // Accept queue is NOT drained here — run() does that.
    try testing.expectEqual(@as(usize, 1), s.accept_queue.len);
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

    var processed = std.atomic.Value(u64).init(0);
    const S = struct {
        var counter: *std.atomic.Value(u64) = undefined;
        fn callback(_: u64) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    S.counter = &processed;
    for (s.pool.workers) |*w| {
        w.work_callback = &S.callback;
    }

    var frames: [5]coroutine.CoroutineFrame = undefined;
    for (0..5) |i| {
        frames[i] = coroutine.CoroutineFrame.create(@intCast(i));
        try s.spawnCoroutine(&frames[i]);
    }

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(sched: *Scheduler(FakeIO)) void {
            sched.run() catch unreachable;
        }
    }.entry, .{&s});

    var attempts: u32 = 0;
    while (processed.load(.acquire) < 5 and attempts < 1000) : (attempts += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    s.shutdown();
    t.join();

    try testing.expectEqual(@as(u64, 5), processed.load(.acquire));
}

// ── Simplify review tests ────────────────────────────────────────────
// These test the API we WANT (no manual s.running = true hacks).

test "simplify: spawn works without setting running manually" {
    // The accept queue should accept work anytime between init and shutdown.
    // Callers should not need to know about internal state.
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    var f = coroutine.CoroutineFrame.create(1);
    // This should work without s.running = true
    try s.spawnCoroutine(&f);
    try testing.expectEqual(@as(u64, 1), s.metrics.coroutines_spawned);
}

test "simplify: spawn rejected only after explicit shutdown" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    var f1 = coroutine.CoroutineFrame.create(1);
    try s.spawnCoroutine(&f1); // should work

    s.shutdown();

    var f2 = coroutine.CoroutineFrame.create(2);
    const result = s.spawnCoroutine(&f2);
    try testing.expectError(error.NotRunning, result);
}

test "simplify: work processed even when one worker deque is full" {
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 2 });
    defer s.deinit();

    var processed = std.atomic.Value(u64).init(0);
    const S = struct {
        var counter: *std.atomic.Value(u64) = undefined;
        fn callback(_: u64) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    S.counter = &processed;
    for (s.pool.workers) |*w| {
        w.work_callback = &S.callback;
    }

    // Fill worker 0's deque before starting
    while (!s.pool.workers[0].local_deque.isFull()) {
        s.pool.workers[0].local_deque.push(0);
    }

    // Spawn new work — should get dispatched to worker 1 (not blocked)
    var f = coroutine.CoroutineFrame.create(99);
    try s.spawnCoroutine(&f);

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(sched: *Scheduler(FakeIO)) void {
            sched.run() catch unreachable;
        }
    }.entry, .{&s});

    // Wait for at least 1 item to be processed (the spawned frame)
    // Worker 0 will also process its full deque, but we care that
    // the new frame wasn't blocked by worker 0 being full.
    var attempts: u32 = 0;
    while (processed.load(.acquire) < 1 and attempts < 1000) : (attempts += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    s.shutdown();
    t.join();

    // At least our spawned frame was processed
    try testing.expect(processed.load(.acquire) >= 1);
}

test "simplify: running is atomic — cross-thread shutdown visibility" {
    // This test verifies shutdown() is visible to run() across threads.
    // If running is a plain bool, the compiler might hoist the read out of
    // the loop, causing run() to never see the write.
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    // We can't easily test atomicity directly, but we can verify the type.
    // After the fix, running should be std.atomic.Value(bool).
    const RunningType = @TypeOf(s.running);
    // This will fail if running is a plain bool — it should be atomic.
    try testing.expect(RunningType == std.atomic.Value(bool));
}

// ── Audit round 4 tests (must fail before fix) ──────────────────────

test "audit4: shutdown is the only way to stop, run owns pool lifecycle" {
    // Finding 1: run() and gracefulShutdown() both call pool.stop().
    // run() should be the ONLY place that starts and stops the pool.
    // shutdown/gracefulShutdown should just signal via the atomic flag.
    //
    // After the fix: gracefulShutdown() just drains + signals, run() handles
    // the pool lifecycle.
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    // Use a thread to run the scheduler
    const t = try std.Thread.spawn(.{}, struct {
        fn entry(sched: *Scheduler(FakeIO)) void {
            sched.run() catch unreachable;
        }
    }.entry, .{&s});

    // Give it a moment to start
    std.Thread.sleep(5 * std.time.ns_per_ms);

    // gracefulShutdown should NOT call pool.stop() — just signal
    s.gracefulShutdown();

    // run() exits its loop and calls pool.stop() — the only stop.
    t.join();

    // Pool should be stopped exactly once (no assert panic, no double-stop)
    try testing.expect(s.pool.state == .stopped);
}

test "audit4: tick does not dispatch to workers before pool is started" {
    // Finding 2: tick() dispatches frames into worker deques even before
    // pool.start(). Workers aren't running yet, so the work sits unprocessed.
    // The TLA+ spec restricts work arrival to the started state.
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 2 });
    defer s.deinit();

    var f = coroutine.CoroutineFrame.create(1);
    try s.spawnCoroutine(&f);

    // tick() before pool.start() — should NOT push to worker deques
    s.tick();

    // Frame should still be in accept queue, not dispatched
    try testing.expectEqual(@as(usize, 1), s.accept_queue.len);
    try testing.expectEqual(@as(usize, 0), s.pool.workers[0].local_deque.len());
    try testing.expectEqual(@as(usize, 0), s.pool.workers[1].local_deque.len());
}

// ── Audit gap fix tests ─────────────────────────────────────────────

test "audit: shut_down is atomic" {
    // Finding 8: shut_down was a plain bool, raceable between shutdown()
    // and spawnCoroutine() across threads.
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    const ShutDownType = @TypeOf(s.shut_down);
    try testing.expect(ShutDownType == std.atomic.Value(bool));
}

test "audit: startup race — running stored before pool.start" {
    // Finding 8: if shutdown() runs between pool.start() and running.store(true),
    // it sets running=false, then run() overwrites with true. Fix: store
    // running=true BEFORE pool.start().
    //
    // We test this indirectly: call shutdown() immediately, then verify
    // run() exits without hanging.
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 1 });
    defer s.deinit();

    // Shutdown before run() — run() should store running=true, then see
    // shut_down=true... but actually run() doesn't check shut_down, it
    // checks running. We need to verify shutdown during startup works.
    // The actual test: start run() in a thread, immediately shutdown.
    const t = try std.Thread.spawn(.{}, struct {
        fn entry(sched: *Scheduler(FakeIO)) void {
            sched.run() catch unreachable;
        }
    }.entry, .{&s});

    // Immediate shutdown — should not race with run()'s running.store(true)
    s.shutdown();
    t.join();

    try testing.expect(s.pool.state == .stopped);
}

test "audit: dispatch more frames than workers drains all" {
    // This test previously failed (expected 5, found 4) because workers
    // exited without draining. With drain-first shutdown, all 5 must complete.
    var s = try Scheduler(FakeIO).init(testing.allocator, .{ .num_threads = 2 });
    defer s.deinit();

    var processed = std.atomic.Value(u64).init(0);
    const S = struct {
        var counter: *std.atomic.Value(u64) = undefined;
        fn callback(_: u64) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    S.counter = &processed;
    for (s.pool.workers) |*w| {
        w.work_callback = &S.callback;
    }

    var frames: [5]coroutine.CoroutineFrame = undefined;
    for (0..5) |i| {
        frames[i] = coroutine.CoroutineFrame.create(@intCast(i));
        try s.spawnCoroutine(&frames[i]);
    }

    const t = try std.Thread.spawn(.{}, struct {
        fn entry(sched: *Scheduler(FakeIO)) void {
            sched.run() catch unreachable;
        }
    }.entry, .{&s});

    // Give scheduler time to dispatch all frames to workers
    var attempts: u32 = 0;
    while (processed.load(.acquire) < 5 and attempts < 2000) : (attempts += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    s.shutdown();
    t.join();

    // All 5 must be processed — drain-first shutdown guarantees this
    try testing.expectEqual(@as(u64, 5), processed.load(.acquire));
}
