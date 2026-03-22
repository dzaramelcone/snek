//! Simple timer management using a flat list.
//! Used for request timeouts, keepalive, connection pool health, coroutine timeouts.
//!
//! Design: flat ArrayList scan on tick(). O(n) per tick but simple and correct.
//! Falsifiability: see FALSIFY.md — at <1000 timers, flat scan likely beats
//! timing wheel bookkeeping. Switch to wheel if profiling shows tick() is hot.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TimerCallback = *const fn (user_data: u64) void;

pub const Timer = struct {
    id: u64,
    deadline_tick: u64,
    callback: TimerCallback,
    user_data: u64,
    cancelled: bool,
};

pub const TimerWheel = struct {
    tick_ns: u64,
    current_tick: u64,
    timers: std.ArrayListUnmanaged(Timer),
    next_id: u64,
    allocator: Allocator,

    pub fn init(allocator: Allocator, tick_ns: u64) TimerWheel {
        return .{
            .tick_ns = tick_ns,
            .current_tick = 0,
            .timers = .{},
            .next_id = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TimerWheel) void {
        self.timers.deinit(self.allocator);
    }

    pub fn schedule(self: *TimerWheel, delay_ns: u64, callback: TimerCallback, user_data: u64) u64 {
        const delay_ticks = delay_ns / self.tick_ns;
        const deadline = self.current_tick + delay_ticks;
        const id = self.next_id;
        self.next_id += 1;

        self.timers.append(self.allocator, .{
            .id = id,
            .deadline_tick = deadline,
            .callback = callback,
            .user_data = user_data,
            .cancelled = false,
        }) catch @panic("timer alloc failed");

        return id;
    }

    pub fn cancel(self: *TimerWheel, timer_id: u64) void {
        for (self.timers.items) |*timer| {
            if (timer.id == timer_id) {
                timer.cancelled = true;
                return;
            }
        }
    }

    pub fn tick(self: *TimerWheel) void {
        self.current_tick += 1;

        // Walk backwards so swap-remove doesn't skip entries
        var i: usize = self.timers.items.len;
        while (i > 0) {
            i -= 1;
            const timer = self.timers.items[i];
            if (timer.cancelled) {
                _ = self.timers.swapRemove(i);
            } else if (timer.deadline_tick <= self.current_tick) {
                timer.callback(timer.user_data);
                _ = self.timers.swapRemove(i);
            }
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

var test_counter: u64 = 0;

fn testCallback(_: u64) void {
    test_counter += 1;
}

fn testCallbackWithData(user_data: u64) void {
    test_counter += user_data;
}

test "schedule timer" {
    test_counter = 0;
    var tw = TimerWheel.init(testing.allocator, 1_000_000); // 1ms tick
    defer tw.deinit();

    _ = tw.schedule(3_000_000, testCallback, 0); // 3ms = 3 ticks

    // Advance 2 ticks — should NOT fire
    tw.tick();
    tw.tick();
    try testing.expectEqual(@as(u64, 0), test_counter);

    // Advance 1 more tick — should fire
    tw.tick();
    try testing.expectEqual(@as(u64, 1), test_counter);
}

test "cancel timer" {
    test_counter = 0;
    var tw = TimerWheel.init(testing.allocator, 1_000_000);
    defer tw.deinit();

    const id = tw.schedule(2_000_000, testCallback, 0);
    tw.cancel(id);

    // Advance past deadline
    tw.tick();
    tw.tick();
    tw.tick();
    try testing.expectEqual(@as(u64, 0), test_counter);

    // Cancelled timer should have been cleaned up
    try testing.expectEqual(@as(usize, 0), tw.timers.items.len);
}

test "tick advances wheel" {
    test_counter = 0;
    var tw = TimerWheel.init(testing.allocator, 1_000_000);
    defer tw.deinit();

    _ = tw.schedule(1_000_000, testCallbackWithData, 10); // fires at tick 1
    _ = tw.schedule(3_000_000, testCallbackWithData, 100); // fires at tick 3

    tw.tick(); // tick 1 — first timer fires
    try testing.expectEqual(@as(u64, 10), test_counter);

    tw.tick(); // tick 2 — nothing fires
    try testing.expectEqual(@as(u64, 10), test_counter);

    tw.tick(); // tick 3 — second timer fires
    try testing.expectEqual(@as(u64, 110), test_counter);
}

test "multiple timers same slot" {
    test_counter = 0;
    var tw = TimerWheel.init(testing.allocator, 1_000_000);
    defer tw.deinit();

    _ = tw.schedule(2_000_000, testCallbackWithData, 1);
    _ = tw.schedule(2_000_000, testCallbackWithData, 1);

    tw.tick(); // tick 1
    try testing.expectEqual(@as(u64, 0), test_counter);

    tw.tick(); // tick 2 — both fire
    try testing.expectEqual(@as(u64, 2), test_counter);

    // Both removed
    try testing.expectEqual(@as(usize, 0), tw.timers.items.len);
}

test "tick with no timers" {
    var tw = TimerWheel.init(testing.allocator, 1_000_000);
    defer tw.deinit();

    // Should not crash or misbehave
    tw.tick();
    tw.tick();
    tw.tick();
    try testing.expectEqual(@as(u64, 3), tw.current_tick);
    try testing.expectEqual(@as(usize, 0), tw.timers.items.len);
}

test "zero delay timer fires on next tick" {
    test_counter = 0;
    var tw = TimerWheel.init(testing.allocator, 1_000_000);
    defer tw.deinit();

    // delay_ns = 0 → deadline_tick = current_tick (0)
    _ = tw.schedule(0, testCallback, 0);

    // tick() increments current_tick to 1, then checks deadline_tick (0) <= 1 → fires
    tw.tick();
    try testing.expectEqual(@as(u64, 1), test_counter);
}

test "cancel nonexistent timer is no-op" {
    var tw = TimerWheel.init(testing.allocator, 1_000_000);
    defer tw.deinit();

    // Should not crash
    tw.cancel(999);
    try testing.expectEqual(@as(usize, 0), tw.timers.items.len);
}

test "timer ids are monotonically increasing" {
    test_counter = 0;
    var tw = TimerWheel.init(testing.allocator, 1_000_000);
    defer tw.deinit();

    const id1 = tw.schedule(1_000_000, testCallback, 0);
    const id2 = tw.schedule(1_000_000, testCallback, 0);
    const id3 = tw.schedule(1_000_000, testCallback, 0);

    try testing.expect(id1 < id2);
    try testing.expect(id2 < id3);
    try testing.expectEqual(@as(u64, 1), id1);

    // Cleanup: fire them
    tw.tick();
}

// ── Edge case tests (Step 8.5 audit) ──────────────────────────────────

test "cancel same timer twice — second cancel is no-op" {
    test_counter = 0;
    var tw = TimerWheel.init(testing.allocator, 1_000_000);
    defer tw.deinit();

    const id = tw.schedule(2_000_000, testCallback, 0);
    tw.cancel(id);
    tw.cancel(id); // second cancel — should be harmless

    tw.tick();
    tw.tick();
    tw.tick();
    try testing.expectEqual(@as(u64, 0), test_counter);
    try testing.expectEqual(@as(usize, 0), tw.timers.items.len);
}

test "schedule 1000 timers, cancel half, tick past all" {
    test_counter = 0;
    var tw = TimerWheel.init(testing.allocator, 1_000_000);
    defer tw.deinit();

    var ids: [1000]u64 = undefined;
    for (0..1000) |i| {
        ids[i] = tw.schedule(5_000_000, testCallback, 0); // all fire at tick 5
    }

    // Cancel even-indexed timers
    for (0..1000) |i| {
        if (i % 2 == 0) tw.cancel(ids[i]);
    }

    // Tick past all deadlines
    for (0..6) |_| tw.tick();

    // Only 500 uncancelled timers should have fired
    try testing.expectEqual(@as(u64, 500), test_counter);
    try testing.expectEqual(@as(usize, 0), tw.timers.items.len);
}

test "tick once — timer not yet past deadline — does not fire" {
    test_counter = 0;
    var tw = TimerWheel.init(testing.allocator, 1_000_000);
    defer tw.deinit();

    _ = tw.schedule(5_000_000, testCallback, 0); // fires at tick 5

    tw.tick(); // tick 1 — not past deadline
    try testing.expectEqual(@as(u64, 0), test_counter);
    try testing.expectEqual(@as(usize, 1), tw.timers.items.len);

    // Cleanup
    for (0..5) |_| tw.tick();
}

test "many ticks with no timers — correctness" {
    var tw = TimerWheel.init(testing.allocator, 1_000_000);
    defer tw.deinit();

    for (0..10_000) |_| tw.tick();
    try testing.expectEqual(@as(u64, 10_000), tw.current_tick);
    try testing.expectEqual(@as(usize, 0), tw.timers.items.len);
}

// Global pointer for re-entrant test — the callback needs access to the TimerWheel
var reentrant_tw: ?*TimerWheel = null;
var reentrant_counter: u64 = 0;

fn reentrantCallback(_: u64) void {
    reentrant_counter += 1;
    if (reentrant_tw) |tw| {
        // Schedule a new timer from within the callback
        _ = tw.schedule(1_000_000, testCallback, 0);
    }
}

test "re-entrant scheduling — schedule timer from within callback" {
    reentrant_counter = 0;
    test_counter = 0;
    var tw = TimerWheel.init(testing.allocator, 1_000_000);
    defer tw.deinit();

    reentrant_tw = &tw;
    defer {
        reentrant_tw = null;
    }

    // Schedule a timer that will schedule another timer when it fires
    _ = tw.schedule(1_000_000, reentrantCallback, 0); // fires at tick 1

    tw.tick(); // tick 1: reentrantCallback fires, schedules a new timer
    try testing.expectEqual(@as(u64, 1), reentrant_counter);

    // The newly scheduled timer should fire at tick 2
    tw.tick(); // tick 2
    try testing.expectEqual(@as(u64, 1), test_counter);
    try testing.expectEqual(@as(usize, 0), tw.timers.items.len);
}

test "schedule timer with delay smaller than tick_ns — fires on next tick" {
    test_counter = 0;
    var tw = TimerWheel.init(testing.allocator, 1_000_000); // 1ms tick
    defer tw.deinit();

    // delay_ns = 500_000 (0.5ms) < tick_ns (1ms) → delay_ticks = 0 → deadline = current_tick
    _ = tw.schedule(500_000, testCallback, 0);

    tw.tick();
    try testing.expectEqual(@as(u64, 1), test_counter);
}
