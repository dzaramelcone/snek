//! Stackless coroutine state machines and comptime pipeline builder.
//! Provides the fundamental async execution primitive for snek.
//!
//! CoroutinePool uses a free-list pool for pre-allocated frames.
//! CancellationToken integration for cooperative cancellation on disconnect.

const std = @import("std");
const pool_mod = @import("pool.zig");

pub const CoroutineState = enum {
    suspended,
    running,
    completed,
    cancelled,
};

pub const CoroutineFrame = struct {
    state: CoroutineState,
    id: u64,
    cancellation: ?*CancellationToken,
    timeout: ?TimeoutHandle,
    /// Intrusive linked list link for zero-allocation task queues.
    // Inspired by: Bun + TigerBeetle — @fieldParentPtr intrusive queues
    // Bun (refs/bun/INSIGHTS.md) and TigerBeetle (refs/tigerbeetle/INSIGHTS.md)
    // both use @fieldParentPtr for zero-allocation intrusive linked lists.
    queue_link: QueueLink,

    pub const QueueLink = struct {
        next: ?*QueueLink,

        pub fn parentFrame(link: *QueueLink) *CoroutineFrame {
            return @fieldParentPtr("queue_link", link);
        }
    };

    pub fn create() CoroutineFrame {
        return undefined;
    }

    pub fn @"resume"(self: *CoroutineFrame) !void {
        _ = .{self};
    }

    pub fn suspend_(self: *CoroutineFrame) void {
        _ = .{self};
    }

    pub fn cancel(self: *CoroutineFrame) void {
        _ = .{self};
    }

    pub fn isCancelled(self: *const CoroutineFrame) bool {
        _ = .{self};
        return undefined;
    }
};

pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool),
    id: u64,

    pub fn init(id: u64) CancellationToken {
        return .{
            .cancelled = std.atomic.Value(bool).init(false),
            .id = id,
        };
    }

    /// Set the cancelled flag. Thread-safe (atomic store).
    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .release);
    }

    /// Check if cancelled. Thread-safe (atomic load).
    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn reset(self: *CancellationToken) void {
        self.cancelled.store(false, .release);
    }
};

/// CoroutinePool backed by free-list pool — pre-allocated, O(1) acquire/release.
/// Default capacity: 2048 frames.
/// Originally used Bun's HiveArray (bitset) pattern but benchmarked 42x slower
/// than free list at this capacity due to cache pressure. See bench/pool_comparison.zig.
pub const CoroutinePool = pool_mod.Pool(CoroutineFrame, 2048);

pub const TimeoutHandle = struct {
    deadline_ns: u64,
    coroutine_id: u64,
    expired: bool,

    pub fn init(deadline_ns: u64, coroutine_id: u64) TimeoutHandle {
        _ = .{ deadline_ns, coroutine_id };
        return undefined;
    }

    pub fn isExpired(self: *const TimeoutHandle) bool {
        _ = .{self};
        return undefined;
    }

    pub fn cancel(self: *TimeoutHandle) void {
        _ = .{self};
    }
};

pub fn Pipeline(comptime stages: anytype) type {
    _ = .{stages};
    return struct {
        pub fn run(input: anytype) @TypeOf(input) {
            _ = .{input};
            return undefined;
        }
    };
}

test "coroutine frame creation" {}

test "coroutine state transitions" {}

test "coroutine suspend and resume" {}

test "coroutine cancellation" {}

test "comptime pipeline builder" {}

test "cancellation token init and cancel" {
    var token = CancellationToken.init(1);
    try std.testing.expect(!token.isCancelled());
    token.cancel();
    try std.testing.expect(token.isCancelled());
    token.reset();
    try std.testing.expect(!token.isCancelled());
}

test "coroutine pool type exists" {
    _ = CoroutinePool;
}

test "timeout handle expiration" {}

test "intrusive queue link fieldParentPtr" {}
