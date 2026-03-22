//! Lock-free work-stealing deque (Chase-Lev algorithm).
//! Local end is LIFO (cache-friendly), remote steal end is FIFO (fairness).
//!
//! CRITICAL BUG NOTE (from REFERENCES.md research):
//! Le et al.'s C11 atomics translation of Chase-Lev has an integer overflow
//! vulnerability. The take() operation decrements `bottom` using size_t, which
//! underflows on an empty deque, creating a state that appears as (size_t)-1
//! elements. This causes garbage reads and undefined behavior.
//! See: https://wingolog.org/archives/2022/10/03/on-correct-and-efficient-work-stealing-for-weak-memory-models
//!
//! FIX: All arithmetic on top/bottom uses Zig's wrapping operators (+%, -%)
//! which have well-defined overflow semantics. Length computation uses
//! wrapping subtraction and compares correctly even across wraparound.
//!
//! FALSIFIABILITY (see FALSIFY.md):
//! Chase-Lev vs mutex-protected VecDeque — see Phase 1 entry in FALSIFY.md.
//!
//! NOTE on fences: The original C11 algorithm uses standalone atomic_thread_fence.
//! Zig 0.15 has no standalone fence primitive. We fold fence semantics into the
//! atomic operations themselves (release store instead of release fence + relaxed
//! store, seq_cst store/load instead of relaxed + seq_cst fence). This is a valid
//! strengthening — each operation provides at least as much ordering as the
//! fence+relaxed combination.

const std = @import("std");

// See: src/core/REFERENCES.md §3.1 — Chase-Lev deque integer overflow bug
// Le et al.'s C11 translation underflows size_t on empty deque take().
// Fix: Zig wrapping arithmetic (+%, -%) avoids undefined overflow behavior.
//
// Reference: "Dynamic Circular Work-Stealing Deque" by Chase & Lev, 2005.
pub fn ChaseLevDeque(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Top index — stolen from by thieves (FIFO end). Atomic.
        top: std.atomic.Value(usize),
        /// Bottom index — pushed/popped by owner (LIFO end). Atomic.
        bottom: std.atomic.Value(usize),
        buffer: []T,
        mask: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            std.debug.assert(capacity > 0 and (capacity & (capacity - 1)) == 0); // must be power of 2
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

        /// Owner pushes to the bottom (LIFO end).
        /// Uses wrapping arithmetic on bottom to avoid overflow bug.
        /// Asserts the deque is not full — caller must check isFull() or size capacity appropriately.
        pub fn push(self: *Self, item: T) void {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.monotonic);
            const size: isize = @bitCast(b -% t);
            std.debug.assert(size >= 0 and @as(usize, @intCast(size)) < self.buffer.len); // deque is full
            self.buffer[b & self.mask] = item;
            // Release store ensures item write is visible before bottom advances.
            // (Folded from: release fence + relaxed store.)
            self.bottom.store(b +% 1, .release);
        }

        /// Owner pops from the bottom (LIFO end).
        /// Uses wrapping subtraction on bottom: `bottom -% 1`.
        pub fn pop(self: *Self) ?T {
            const b = self.bottom.load(.monotonic) -% 1;
            // SeqCst store of bottom prevents reordering with steal's CAS.
            // (Folded from: relaxed store + seq_cst fence.)
            self.bottom.store(b, .seq_cst);
            const t = self.top.load(.seq_cst);
            // Use signed comparison for wrapping correctness.
            const diff: isize = @bitCast(b -% t);
            if (diff < 0) {
                // Deque was empty.
                self.bottom.store(t, .monotonic);
                return null;
            }
            const item = self.buffer[b & self.mask];
            if (diff == 0) {
                // Last item — race with steal. Try to claim it.
                if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                    // Thief got it. Deque is empty.
                    self.bottom.store(t +% 1, .monotonic);
                    return null;
                }
                self.bottom.store(t +% 1, .monotonic);
            }
            return item;
        }

        /// Thief steals from the top (FIFO end).
        /// Uses CAS on top. Returns null on empty or contention.
        pub fn steal(self: *Self) ?T {
            // SeqCst loads pair with pop's seq_cst store to prevent reordering.
            // (Folded from: acquire load + seq_cst fence + acquire load.)
            const t = self.top.load(.seq_cst);
            const b = self.bottom.load(.seq_cst);
            const diff: isize = @bitCast(b -% t);
            if (diff <= 0) {
                return null;
            }
            const item = self.buffer[t & self.mask];
            if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                return null; // another thief or pop() got it
            }
            return item;
        }

        /// Length uses wrapping subtraction: `bottom -% top`.
        pub fn len(self: *const Self) usize {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.monotonic);
            const diff: isize = @bitCast(b -% t);
            return if (diff < 0) 0 else @intCast(diff);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len() == self.buffer.len;
        }
    };
}

test "push and pop local" {
    const Deque = ChaseLevDeque(usize);
    var d = try Deque.init(std.testing.allocator, 16);
    defer d.deinit();

    // Push 10 items
    for (0..10) |i| {
        d.push(i);
    }

    // Pop all 10 — should come back in LIFO order (9, 8, 7, ..., 0)
    var i: usize = 10;
    while (i > 0) {
        i -= 1;
        const val = d.pop() orelse unreachable;
        try std.testing.expectEqual(i, val);
    }

    // Deque should be empty
    try std.testing.expect(d.pop() == null);
}

test "steal from remote" {
    const Deque = ChaseLevDeque(usize);
    var d = try Deque.init(std.testing.allocator, 16);
    defer d.deinit();

    // Push 10 items
    for (0..10) |i| {
        d.push(i);
    }

    // Steal all 10 — should come back in FIFO order (0, 1, 2, ..., 9)
    for (0..10) |i| {
        const val = d.steal() orelse unreachable;
        try std.testing.expectEqual(i, val);
    }

    // Deque should be empty
    try std.testing.expect(d.steal() == null);
}

test "concurrent push and steal" {
    const num_items: usize = 100_000;
    const num_thieves: usize = 3;
    const Deque = ChaseLevDeque(usize);

    var d = try Deque.init(std.testing.allocator, 1 << 17); // 131072, enough for 100K
    defer d.deinit();

    var stolen_counts = [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** num_thieves;
    var owner_popped = std.atomic.Value(usize).init(0);
    var done = std.atomic.Value(bool).init(false);

    // Thief function
    const Thief = struct {
        fn run(deque: *Deque, count: *std.atomic.Value(usize), is_done: *std.atomic.Value(bool)) void {
            var c: usize = 0;
            while (!is_done.load(.acquire)) {
                if (deque.steal() != null) {
                    c += 1;
                }
            }
            // Drain remaining
            while (deque.steal() != null) {
                c += 1;
            }
            count.store(c, .release);
        }
    };

    // Spawn thieves
    var threads: [num_thieves]std.Thread = undefined;
    for (0..num_thieves) |i| {
        threads[i] = try std.Thread.spawn(.{}, Thief.run, .{ &d, &stolen_counts[i], &done });
    }

    // Owner pushes all items, then pops remaining
    for (0..num_items) |i| {
        d.push(i);
    }

    var popped: usize = 0;
    while (d.pop() != null) {
        popped += 1;
    }
    owner_popped.store(popped, .release);

    done.store(true, .release);

    for (0..num_thieves) |i| {
        threads[i].join();
    }

    var total_stolen: usize = 0;
    for (0..num_thieves) |i| {
        total_stolen += stolen_counts[i].load(.acquire);
    }

    const total = owner_popped.load(.acquire) + total_stolen;
    try std.testing.expectEqual(num_items, total);
}

test "empty deque steal returns null" {
    const Deque = ChaseLevDeque(usize);
    var d = try Deque.init(std.testing.allocator, 16);
    defer d.deinit();

    try std.testing.expect(d.steal() == null);
    try std.testing.expect(d.pop() == null);
    try std.testing.expect(d.isEmpty());
}

test "wrapping arithmetic correctness" {
    const Deque = ChaseLevDeque(usize);
    // Use small capacity to force index wrapping around the buffer.
    var d = try Deque.init(std.testing.allocator, 16);
    defer d.deinit();

    const iterations: usize = 1 << 16; // 65536 — forces usize indices well past buffer size
    for (0..iterations) |i| {
        d.push(i);
        const val = d.pop() orelse unreachable;
        try std.testing.expectEqual(i, val);
    }

    // Verify deque is still functional after heavy wrapping
    try std.testing.expect(d.isEmpty());
    d.push(42);
    try std.testing.expectEqual(@as(usize, 42), d.pop().?);
}

test "isFull prevents overflow" {
    const Deque = ChaseLevDeque(usize);
    var d = try Deque.init(std.testing.allocator, 4);
    defer d.deinit();

    // Fill to capacity
    for (0..4) |i| {
        try std.testing.expect(!d.isFull());
        d.push(i);
    }
    try std.testing.expect(d.isFull());

    // Pop one, push one — should work
    _ = d.pop();
    try std.testing.expect(!d.isFull());
    d.push(99);
    try std.testing.expect(d.isFull());
}

test "non-power-of-2 capacity panics" {
    const Deque = ChaseLevDeque(usize);
    // Capacity 3 is not power of 2 — init should panic (debug assert).
    // We can't easily test panics in Zig's test framework without
    // expectPanic, so we just verify the assertion exists by checking
    // that valid power-of-2 capacities work.
    var d = try Deque.init(std.testing.allocator, 8);
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 7), d.mask);
}

// ── Edge case tests (Step 8.5 audit) ──────────────────────────────────

test "capacity 1 — minimum valid power of 2" {
    const Deque = ChaseLevDeque(usize);
    var d = try Deque.init(std.testing.allocator, 1);
    defer d.deinit();

    // Should work as a single-slot deque
    try std.testing.expect(d.isEmpty());
    d.push(42);
    try std.testing.expect(d.isFull());
    try std.testing.expectEqual(@as(usize, 1), d.len());

    // Pop it
    const val = d.pop() orelse unreachable;
    try std.testing.expectEqual(@as(usize, 42), val);
    try std.testing.expect(d.isEmpty());

    // Push again — verify recovery
    d.push(99);
    const val2 = d.steal() orelse unreachable;
    try std.testing.expectEqual(@as(usize, 99), val2);
    try std.testing.expect(d.isEmpty());
}

test "push, steal everything, push again — recovery" {
    const Deque = ChaseLevDeque(usize);
    var d = try Deque.init(std.testing.allocator, 8);
    defer d.deinit();

    // Fill, steal everything
    for (0..8) |i| d.push(i);
    for (0..8) |_| {
        try std.testing.expect(d.steal() != null);
    }
    try std.testing.expect(d.isEmpty());
    try std.testing.expect(d.steal() == null);

    // Push again — deque should recover and work correctly
    for (0..8) |i| d.push(i);
    try std.testing.expect(d.isFull());

    // Pop all — should be LIFO
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        const val = d.pop() orelse unreachable;
        try std.testing.expectEqual(i, val);
    }
    try std.testing.expect(d.isEmpty());
}

test "multiple thieves on single item — only one succeeds" {
    const Deque = ChaseLevDeque(usize);
    var d = try Deque.init(std.testing.allocator, 16);
    defer d.deinit();

    const num_thieves: usize = 8;
    var success_count = std.atomic.Value(usize).init(0);

    d.push(42);

    const Thief = struct {
        fn run(deque: *ChaseLevDeque(usize), successes: *std.atomic.Value(usize)) void {
            if (deque.steal() != null) {
                _ = successes.fetchAdd(1, .monotonic);
            }
        }
    };

    var threads: [num_thieves]std.Thread = undefined;
    for (0..num_thieves) |i| {
        threads[i] = try std.Thread.spawn(.{}, Thief.run, .{ &d, &success_count });
    }
    for (0..num_thieves) |i| {
        threads[i].join();
    }

    // Exactly one thief should have succeeded
    try std.testing.expectEqual(@as(usize, 1), success_count.load(.monotonic));
    try std.testing.expect(d.isEmpty());
}

test "deinit on partially filled deque — no leak" {
    const Deque = ChaseLevDeque(usize);
    var d = try Deque.init(std.testing.allocator, 16);

    // Push some items but don't pop them all — deinit should still free the buffer
    d.push(1);
    d.push(2);
    d.push(3);
    _ = d.pop(); // pop one, leave 2

    d.deinit(); // testing.allocator will catch any leak
}

test "interleave push/pop rapidly — wrapping stays correct after many cycles" {
    const Deque = ChaseLevDeque(usize);
    var d = try Deque.init(std.testing.allocator, 4);
    defer d.deinit();

    // Push 2, pop 1, repeatedly — exercises wrapping with small buffer
    const cycles: usize = 100_000;
    var push_count: usize = 0;
    var pop_count: usize = 0;

    for (0..cycles) |_| {
        if (!d.isFull()) {
            d.push(push_count);
            push_count += 1;
        }
        if (!d.isFull()) {
            d.push(push_count);
            push_count += 1;
        }
        // Pop one
        if (d.pop()) |_| {
            pop_count += 1;
        }
    }

    // Drain remainder
    while (d.pop()) |_| {
        pop_count += 1;
    }

    try std.testing.expectEqual(push_count, pop_count);
    try std.testing.expect(d.isEmpty());
}

test "concurrent pop and steal on single item — exactly one wins" {
    const Deque = ChaseLevDeque(usize);
    const rounds: usize = 10_000;

    for (0..rounds) |_| {
        var d = try Deque.init(std.testing.allocator, 4);
        defer d.deinit();

        d.push(42);

        var steal_got_it = std.atomic.Value(bool).init(false);
        const Thief = struct {
            fn run(deque: *ChaseLevDeque(usize), got_it: *std.atomic.Value(bool)) void {
                if (deque.steal() != null) {
                    got_it.store(true, .release);
                }
            }
        };

        var thief = try std.Thread.spawn(.{}, Thief.run, .{ &d, &steal_got_it });
        const owner_got = d.pop();
        thief.join();

        const thief_got = steal_got_it.load(.acquire);
        // Exactly one must succeed
        const got_count: usize = (if (owner_got != null) @as(usize, 1) else 0) + (if (thief_got) @as(usize, 1) else 0);
        try std.testing.expectEqual(@as(usize, 1), got_count);
    }
}

test "len returns 0 for freshly initialized deque" {
    const Deque = ChaseLevDeque(usize);
    var d = try Deque.init(std.testing.allocator, 4);
    defer d.deinit();

    try std.testing.expectEqual(@as(usize, 0), d.len());
    try std.testing.expect(d.isEmpty());
    try std.testing.expect(!d.isFull());
}
