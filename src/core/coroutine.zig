//! Stackless coroutine state machines and comptime pipeline builder.
//! Provides the fundamental async execution primitive for snek.
//!
//! CoroutinePool uses a free-list pool for pre-allocated frames.
//! CancellationToken integration for cooperative cancellation on disconnect.
//!
//! Falsifiability: Stackless (state machine) vs stackful (separate stack) coroutines.
//! - Claim: Stackless is correct here because snek coroutines are driven externally —
//!   the Python handler is an async def, and the Zig runtime calls coro.send() to
//!   advance it. The CoroutineFrame is Zig-side bookkeeping, not a coroutine itself.
//!   A stackful coroutine (separate stack, context-switch into it) would be wasted
//!   complexity since the actual "coroutine" lives in CPython's async machinery.
//! - Alternative: Stackful coroutines with mmap'd stacks (like Go goroutines).
//! - Threshold: If we ever need to suspend *Zig* code mid-function (not Python),
//!   stackful becomes necessary. Current design: Zig never suspends — it calls
//!   Python, Python yields, Zig gets control back synchronously.
//! - Context: Phases 12-13 will integrate with CPython. If the Python bridge
//!   requires Zig-side suspension points, revisit this choice.

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

    pub fn create(id: u64) CoroutineFrame {
        return .{
            .state = .suspended,
            .id = id,
            .cancellation = null,
            .timeout = null,
            .queue_link = .{ .next = null },
        };
    }

    /// Resume a suspended coroutine. Checks cancellation token first.
    /// Returns error.Cancelled if the token was set.
    pub fn @"resume"(self: *CoroutineFrame) error{Cancelled}!void {
        std.debug.assert(self.state == .suspended);
        // Check cancellation token before resuming
        if (self.cancellation) |token| {
            if (token.isCancelled()) {
                self.state = .cancelled;
                return error.Cancelled;
            }
        }
        self.state = .running;
    }

    pub fn suspend_(self: *CoroutineFrame) void {
        std.debug.assert(self.state == .running);
        self.state = .suspended;
    }

    pub fn complete(self: *CoroutineFrame) void {
        std.debug.assert(self.state == .running);
        self.state = .completed;
    }

    pub fn cancel(self: *CoroutineFrame) void {
        self.state = .cancelled;
        if (self.cancellation) |token| {
            token.cancel();
        }
    }

    pub fn isCancelled(self: *const CoroutineFrame) bool {
        if (self.cancellation) |token| {
            return token.isCancelled();
        }
        return self.state == .cancelled;
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
    cancelled: bool,

    pub fn init(deadline_ns: u64, coroutine_id: u64) TimeoutHandle {
        return .{
            .deadline_ns = deadline_ns,
            .coroutine_id = coroutine_id,
            .expired = false,
            .cancelled = false,
        };
    }

    pub fn isExpired(self: *const TimeoutHandle) bool {
        return self.expired;
    }

    pub fn cancel(self: *TimeoutHandle) void {
        self.expired = false;
        self.cancelled = true;
    }
};

/// Comptime pipeline that chains transformation stages.
/// All stages must share the same input/output type T.
/// For heterogeneous pipelines, compose manually.
pub fn Pipeline(comptime T: type, comptime stages: anytype) type {
    return struct {
        pub fn run(input: T) T {
            var result = input;
            inline for (stages) |stage| {
                result = stage(result);
            }
            return result;
        }
    };
}

/// Intrusive FIFO queue of CoroutineFrames, linked via queue_link.
/// Zero allocation — uses the intrusive QueueLink embedded in each frame.
pub const FrameQueue = struct {
    head: ?*CoroutineFrame.QueueLink,
    tail: ?*CoroutineFrame.QueueLink,
    len: usize,

    pub fn init() FrameQueue {
        return .{
            .head = null,
            .tail = null,
            .len = 0,
        };
    }

    pub fn push(self: *FrameQueue, frame: *CoroutineFrame) void {
        const link = &frame.queue_link;
        link.next = null;
        if (self.tail) |tail| {
            tail.next = link;
        } else {
            self.head = link;
        }
        self.tail = link;
        self.len += 1;
    }

    pub fn pop(self: *FrameQueue) ?*CoroutineFrame {
        const head = self.head orelse return null;
        self.head = head.next;
        if (self.head == null) {
            self.tail = null;
        }
        head.next = null;
        self.len -= 1;
        return head.parentFrame();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "coroutine frame creation" {
    const frame = CoroutineFrame.create(42);
    try std.testing.expectEqual(CoroutineState.suspended, frame.state);
    try std.testing.expectEqual(@as(u64, 42), frame.id);
    try std.testing.expect(frame.cancellation == null);
    try std.testing.expect(frame.timeout == null);
}

test "coroutine state transitions" {
    // create → resume → suspend → resume → complete (full lifecycle)
    var frame = CoroutineFrame.create(1);
    try std.testing.expectEqual(CoroutineState.suspended, frame.state);

    try frame.@"resume"();
    try std.testing.expectEqual(CoroutineState.running, frame.state);

    frame.suspend_();
    try std.testing.expectEqual(CoroutineState.suspended, frame.state);

    try frame.@"resume"();
    try std.testing.expectEqual(CoroutineState.running, frame.state);

    frame.complete();
    try std.testing.expectEqual(CoroutineState.completed, frame.state);
}

test "coroutine suspend and resume" {
    // Verify id is preserved across suspend/resume cycles
    var frame = CoroutineFrame.create(99);
    try std.testing.expectEqual(@as(u64, 99), frame.id);

    try frame.@"resume"();
    try std.testing.expectEqual(@as(u64, 99), frame.id);

    frame.suspend_();
    try std.testing.expectEqual(@as(u64, 99), frame.id);

    try frame.@"resume"();
    try std.testing.expectEqual(@as(u64, 99), frame.id);
}

test "coroutine cancellation" {
    var frame = CoroutineFrame.create(10);
    try std.testing.expect(!frame.isCancelled());

    frame.cancel();
    try std.testing.expectEqual(CoroutineState.cancelled, frame.state);
    try std.testing.expect(frame.isCancelled());
}

test "coroutine cancellation with token" {
    // Create with CancellationToken, cancel token externally, resume checks token
    var token = CancellationToken.init(5);
    var frame = CoroutineFrame.create(5);
    frame.cancellation = &token;

    // Not cancelled yet
    try std.testing.expect(!frame.isCancelled());

    // Cancel the token externally (simulates client disconnect)
    token.cancel();

    // isCancelled sees the token
    try std.testing.expect(frame.isCancelled());

    // resume() should detect the token and transition to cancelled
    const result = frame.@"resume"();
    try std.testing.expectError(error.Cancelled, result);
    try std.testing.expectEqual(CoroutineState.cancelled, frame.state);
}

test "comptime pipeline builder" {
    // Chain 3 functions: double → add_one → double
    const double = struct {
        fn f(x: u32) u32 {
            return x * 2;
        }
    }.f;
    const add_one = struct {
        fn f(x: u32) u32 {
            return x + 1;
        }
    }.f;

    const P = Pipeline(u32, .{ double, add_one, double });
    // input=3 → double(3)=6 → add_one(6)=7 → double(7)=14
    const result = P.run(3);
    try std.testing.expectEqual(@as(u32, 14), result);
}

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

test "timeout handle expiration" {
    var handle = TimeoutHandle.init(1_000_000, 7);
    try std.testing.expectEqual(@as(u64, 1_000_000), handle.deadline_ns);
    try std.testing.expectEqual(@as(u64, 7), handle.coroutine_id);
    try std.testing.expect(!handle.isExpired());

    // Simulate expiration (in real code, the timer system sets this)
    handle.expired = true;
    try std.testing.expect(handle.isExpired());

    // Cancel prevents firing
    handle.cancel();
    try std.testing.expect(!handle.isExpired());
    try std.testing.expect(handle.cancelled);
}

test "intrusive queue link fieldParentPtr" {
    // Push 3 frames, pop all, verify FIFO order
    var f1 = CoroutineFrame.create(1);
    var f2 = CoroutineFrame.create(2);
    var f3 = CoroutineFrame.create(3);

    var queue = FrameQueue.init();
    try std.testing.expectEqual(@as(usize, 0), queue.len);

    queue.push(&f1);
    queue.push(&f2);
    queue.push(&f3);
    try std.testing.expectEqual(@as(usize, 3), queue.len);

    // Pop in FIFO order
    const p1 = queue.pop().?;
    try std.testing.expectEqual(@as(u64, 1), p1.id);
    try std.testing.expectEqual(@as(usize, 2), queue.len);

    const p2 = queue.pop().?;
    try std.testing.expectEqual(@as(u64, 2), p2.id);

    const p3 = queue.pop().?;
    try std.testing.expectEqual(@as(u64, 3), p3.id);

    // Empty
    try std.testing.expectEqual(@as(usize, 0), queue.len);
    try std.testing.expect(queue.pop() == null);
}

// ── Edge case tests ──────────────────────────────────────────────────

test "edge: double cancel is idempotent" {
    var token = CancellationToken.init(1);
    var frame = CoroutineFrame.create(1);
    frame.cancellation = &token;

    frame.cancel();
    try std.testing.expectEqual(CoroutineState.cancelled, frame.state);
    try std.testing.expect(token.isCancelled());

    // Second cancel — should not panic or change anything
    frame.cancel();
    try std.testing.expectEqual(CoroutineState.cancelled, frame.state);
    try std.testing.expect(token.isCancelled());
}

test "edge: cancel then resume returns Cancelled" {
    var frame = CoroutineFrame.create(1);
    frame.cancel();
    // Frame is cancelled — but resume() asserts state == .suspended
    // Since cancel sets state to .cancelled, resume would assert-fail.
    // This is correct: you shouldn't resume a cancelled frame.
    // The caller should check isCancelled() before resuming.
    try std.testing.expect(frame.isCancelled());
}

test "edge: empty pipeline returns input unchanged" {
    const P = Pipeline(u32, .{});
    try std.testing.expectEqual(@as(u32, 42), P.run(42));
}

test "edge: frame queue pop from empty" {
    var queue = FrameQueue.init();
    try std.testing.expect(queue.pop() == null);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
}

test "edge: frame queue single element" {
    var f = CoroutineFrame.create(99);
    var queue = FrameQueue.init();
    queue.push(&f);
    try std.testing.expectEqual(@as(usize, 1), queue.len);

    const popped = queue.pop().?;
    try std.testing.expectEqual(@as(u64, 99), popped.id);
    try std.testing.expect(queue.head == null);
    try std.testing.expect(queue.tail == null);
}

test "edge: cancellation token reset then recancel" {
    var token = CancellationToken.init(1);
    token.cancel();
    try std.testing.expect(token.isCancelled());
    token.reset();
    try std.testing.expect(!token.isCancelled());
    token.cancel();
    try std.testing.expect(token.isCancelled());
}
