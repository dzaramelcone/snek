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

/// Scheduler parameterized on the IO backend type.
/// In production: Scheduler(IoUring) or Scheduler(Kqueue).
/// In tests: Scheduler(FakeIO) for deterministic simulation.
// Inspired by: TigerBeetle (refs/tigerbeetle/INSIGHTS.md) — generic-over-IO pattern
// Scheduler(comptime IO: type) enables swapping real IO for FakeIO in tests.
// Inspired by: TigerBeetle (refs/tigerbeetle/INSIGHTS.md) — three-tier backpressure
// Per-worker deque capacity -> bounded accept queue -> TCP listen backlog.
pub fn Scheduler(comptime IO: type) type {
    return struct {
        const Self = @This();

        pool: worker.WorkerPool(IO),
        timers: timer.TimerWheel,
        config: SchedulerConfig,
        running: bool,
        metrics: SchedulerMetrics,

        pub fn init(config: SchedulerConfig) Self {
            _ = .{config};
            return undefined;
        }

        pub fn deinit(self: *Self) void {
            _ = .{self};
        }

        pub fn run(self: *Self) !void {
            _ = .{self};
        }

        pub fn shutdown(self: *Self) void {
            _ = .{self};
        }

        /// Graceful shutdown: stop accepting, drain in-flight, then close.
        pub fn gracefulShutdown(self: *Self, timeout_ms: u64) !void {
            _ = .{ self, timeout_ms };
        }

        pub fn spawnCoroutine(self: *Self, frame: *coroutine.CoroutineFrame) !void {
            _ = .{ self, frame };
        }

        pub fn cancelCoroutine(self: *Self, id: u64) !void {
            _ = .{ self, id };
        }

        pub fn getMetrics(self: *const Self) SchedulerMetrics {
            _ = .{self};
            return undefined;
        }
    };
}

test "scheduler init and deinit" {}

test "scheduler run and shutdown" {}

test "scheduler graceful shutdown" {}

test "scheduler spawn coroutine" {}

test "scheduler cancel coroutine" {}

test "scheduler metrics" {}

test "scheduler generic over fake io" {
    const fake_io = @import("fake_io.zig");
    const TestScheduler = Scheduler(fake_io.FakeIO);
    _ = TestScheduler;
}
