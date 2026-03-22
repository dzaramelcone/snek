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
const coroutine = @import("coroutine.zig");

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
        is_parked: bool,
        config: ThreadConfig,
        /// Per-connection arena pairs managed via free-list pool.
        connection_arenas: pool_mod.Pool(arena_mod.ConnectionArenas, 4096),

        pub fn init(id: u32, cfg: ThreadConfig) Self {
            _ = .{ id, cfg };
            return undefined;
        }

        pub fn deinit(self: *Self) void {
            _ = .{self};
        }

        pub fn start(self: *Self) !void {
            _ = .{self};
        }

        pub fn stop(self: *Self) void {
            _ = .{self};
        }

        /// Park the worker thread (idle strategy). Blocks on futex until woken.
        pub fn park(self: *Self) void {
            _ = .{self};
        }

        /// Wake a parked worker thread via futex.
        pub fn wake(self: *Self) void {
            _ = .{self};
        }

        pub fn runLoop(self: *Self) !void {
            _ = .{self};
        }

        pub fn getThreadId(self: *const Self) u32 {
            _ = .{self};
            return undefined;
        }

        pub fn setAffinity(self: *Self, core_id: u32) !void {
            _ = .{ self, core_id };
        }

        pub fn pinToCore(self: *Self, core_id: u32) !void {
            _ = .{ self, core_id };
        }

        /// Acquire a connection arena pair from the pool.
        pub fn acquireConnection(self: *Self) ?*arena_mod.ConnectionArenas {
            _ = .{self};
            return null;
        }

        /// Release a connection arena pair back to the pool.
        pub fn releaseConnection(self: *Self, arenas: *arena_mod.ConnectionArenas) void {
            _ = .{ self, arenas };
        }
    };
}

/// Worker pool parameterized on the IO backend type.
pub fn WorkerPool(comptime IO: type) type {
    return struct {
        const Self = @This();

        workers: []WorkerThread(IO),
        num_threads: u32,

        pub fn init(num_threads: u32) Self {
            _ = .{num_threads};
            return undefined;
        }

        pub fn deinit(self: *Self) void {
            _ = .{self};
        }

        pub fn start(self: *Self) !void {
            _ = .{self};
        }

        pub fn stop(self: *Self) void {
            _ = .{self};
        }
    };
}

test "worker thread init and deinit" {}

test "worker thread start and stop" {}

test "worker thread park and wake" {}

test "worker thread run loop" {}

test "worker thread set affinity" {}

test "worker pool init and deinit" {}

test "worker pool start and stop" {}

test "worker thread acquire and release connection" {}

test "worker generic over fake io" {
    const fake_io = @import("fake_io.zig");
    const TestWorker = WorkerThread(fake_io.FakeIO);
    _ = TestWorker;
}
