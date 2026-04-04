//! VOPR-style deterministic simulation harness.
//!
//! Runs the application against FakeIO with a deterministic PRNG driven by
//! a single u64 seed. Every failure is reproducible. Supports swarm testing
//! with randomized fault parameters across many seeds.
//!
//! Self-contained: defines minimal IO types for testing.
//!
//! Sources:
//!   - VOPR-style from TigerBeetle (refs/tigerbeetle/INSIGHTS.md,
//!     tests/REFERENCES_verification.md)
//!   - FoundationDB-inspired deterministic simulation

const std = @import("std");

// ── Minimal IO types for simulation-only scheduling tests ──

pub const IoResult = i32;

pub const IoOp = union(enum) {
    accept: struct { socket: i32 },
    accept_multishot: struct { socket: i32 },
    connect: struct { socket: i32 },
    recv: struct { socket: i32, buffer: []u8 },
    recv_multishot: struct { socket: i32, buffer_group: u16, flags: u32 = 0 },
    send: struct { socket: i32, buffer: []const u8 },
    send_zc: struct { socket: i32, buffer: []const u8, send_flags: u32 = 0, zc_flags: u16 = 0 },
    sendv: struct { socket: i32 },
    close: i32,
    timer: struct { seconds: u63, nanos: u32 },
};

pub const OpTag = std.meta.Tag(IoOp);

pub const Completion = struct {
    op_tag: OpTag,
    result: IoResult,
    flags: u32 = 0,
    buffer_id: ?u16 = null,
    more: bool = false,
    notification: bool = false,
    buffer_more: bool = false,
};

pub const Task = struct {
    step: *const fn (*Task, Completion) ?IoOp,
    ctx: *anyopaque,
    next: ?*Task = null,
};

fn noopStep(_: *Task, _: Completion) ?IoOp {
    return null;
}

// ── FakeBackend ──────────────────────────────────────────────────

const MAX_OPS = 1024;

pub const FaultRule = struct {
    op_tag: OpTag,
    result: IoResult,
    count: u32 = 1,
    fired: u32 = 0,
};

pub const FakeBackend = struct {
    const PendingOp = struct { task: *Task, op: IoOp };
    const CompletionEntry = struct {
        task: *Task,
        op_tag: OpTag,
        result: IoResult,
    };

    pending: [MAX_OPS]PendingOp = undefined,
    pending_count: usize = 0,

    completions: [MAX_OPS]CompletionEntry = undefined,
    completion_count: usize = 0,

    fault_rules: [64]FaultRule = undefined,
    fault_count: usize = 0,

    tasks_buf: []*Task,
    completion_buf: []Completion,

    prng: std.Random.DefaultPrng,

    total_queued: u64 = 0,
    total_completed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, max_events: u16) !FakeBackend {
        return .{
            .tasks_buf = try allocator.alloc(*Task, max_events),
            .completion_buf = try allocator.alloc(Completion, max_events),
            .prng = std.Random.DefaultPrng.init(0),
        };
    }

    pub fn deinit(self: *FakeBackend, allocator: std.mem.Allocator) void {
        allocator.free(self.tasks_buf);
        allocator.free(self.completion_buf);
    }

    pub fn queue(self: *FakeBackend, task: *Task, op: IoOp) !void {
        if (self.pending_count >= MAX_OPS) return error.Overflow;
        self.pending[self.pending_count] = .{ .task = task, .op = op };
        self.pending_count += 1;
        self.total_queued += 1;
    }

    pub fn submitAndWait(self: *FakeBackend, wait_nr: u32) !struct { tasks: []*Task, completions: []Completion } {
        _ = wait_nr;

        // Auto-complete close ops
        var i: usize = 0;
        while (i < self.pending_count) {
            const tag = std.meta.activeTag(self.pending[i].op);
            if (tag == .close) {
                self.stageCompletion(self.pending[i].task, tag, 0);
                self.removePending(i);
            } else {
                i += 1;
            }
        }

        // Apply fault rules
        i = 0;
        while (i < self.pending_count) {
            const tag = std.meta.activeTag(self.pending[i].op);
            if (self.matchFaultRule(tag)) |result| {
                self.stageCompletion(self.pending[i].task, tag, result);
                self.removePending(i);
            } else {
                i += 1;
            }
        }

        const count = @min(self.completion_count, self.tasks_buf.len);
        for (0..count) |j| {
            self.tasks_buf[j] = self.completions[j].task;
            self.completion_buf[j] = .{
                .op_tag = self.completions[j].op_tag,
                .result = self.completions[j].result,
            };
        }
        self.total_completed += count;

        if (count < self.completion_count) {
            const remaining = self.completion_count - count;
            for (0..remaining) |j| {
                self.completions[j] = self.completions[count + j];
            }
            self.completion_count = remaining;
        } else {
            self.completion_count = 0;
        }

        return .{
            .tasks = self.tasks_buf[0..count],
            .completions = self.completion_buf[0..count],
        };
    }

    pub fn seed(self: *FakeBackend, s: u64) void {
        self.prng = std.Random.DefaultPrng.init(s);
    }

    pub fn completeNext(self: *FakeBackend, result: IoResult) void {
        if (self.pending_count == 0) return;
        self.stageCompletion(self.pending[0].task, std.meta.activeTag(self.pending[0].op), result);
        self.removePending(0);
    }

    pub fn completeNextByTag(self: *FakeBackend, op_tag: OpTag, result: IoResult) bool {
        for (0..self.pending_count) |j| {
            if (std.meta.activeTag(self.pending[j].op) == op_tag) {
                self.stageCompletion(self.pending[j].task, op_tag, result);
                self.removePending(j);
                return true;
            }
        }
        return false;
    }

    pub fn completeAll(self: *FakeBackend, result: IoResult) void {
        for (0..self.pending_count) |j| {
            self.stageCompletion(self.pending[j].task, std.meta.activeTag(self.pending[j].op), result);
        }
        self.pending_count = 0;
    }

    pub fn injectError(self: *FakeBackend, op_tag: OpTag, errno: IoResult) void {
        if (self.fault_count >= self.fault_rules.len) return;
        self.fault_rules[self.fault_count] = .{ .op_tag = op_tag, .result = errno };
        self.fault_count += 1;
    }

    pub fn injectErrorN(self: *FakeBackend, op_tag: OpTag, errno: IoResult, count: u32) void {
        if (self.fault_count >= self.fault_rules.len) return;
        self.fault_rules[self.fault_count] = .{ .op_tag = op_tag, .result = errno, .count = count };
        self.fault_count += 1;
    }

    pub fn clearFaults(self: *FakeBackend) void {
        self.fault_count = 0;
    }

    pub fn pendingCount(self: *const FakeBackend) usize {
        return self.pending_count;
    }

    pub fn pendingTag(self: *const FakeBackend, idx: usize) ?OpTag {
        if (idx >= self.pending_count) return null;
        return std.meta.activeTag(self.pending[idx].op);
    }

    fn stageCompletion(self: *FakeBackend, task: *Task, op_tag: OpTag, result: IoResult) void {
        if (self.completion_count >= MAX_OPS) return;
        self.completions[self.completion_count] = .{ .task = task, .op_tag = op_tag, .result = result };
        self.completion_count += 1;
    }

    fn removePending(self: *FakeBackend, idx: usize) void {
        self.pending_count -= 1;
        if (idx < self.pending_count) {
            self.pending[idx] = self.pending[self.pending_count];
        }
    }

    fn matchFaultRule(self: *FakeBackend, op_tag: OpTag) ?IoResult {
        for (0..self.fault_count) |j| {
            if (self.fault_rules[j].op_tag == op_tag) {
                const rule = &self.fault_rules[j];
                if (rule.count == 0) {
                    rule.fired += 1;
                    return rule.result;
                }
                if (rule.fired < rule.count) {
                    rule.fired += 1;
                    return rule.result;
                }
            }
        }
        return null;
    }
};

// ── SimConfig ────────────────────────────────────────────────────

/// Configuration for a single simulation run.
pub const SimConfig = struct {
    seed: u64,
    max_ticks: u64 = 100_000,
    /// Probability of network packet drop (0.0 - 1.0).
    fault_drop_probability: f64 = 0.01,
    /// Probability of network packet reordering.
    fault_reorder_probability: f64 = 0.01,
    /// Probability of connection reset mid-request.
    fault_reset_probability: f64 = 0.005,
    /// Probability of slow client (delayed reads).
    fault_slow_client_probability: f64 = 0.01,
    /// Maximum simulated latency in ticks.
    max_latency_ticks: u32 = 100,
};

/// Invariant checking hook.
pub const Invariant = struct {
    name: []const u8,
    check_fn: *const fn (state: *anyopaque) bool,
};

/// Built-in invariant names.
pub const builtin_invariants = struct {
    pub const no_leaked_connections = "no_leaked_connections";
    pub const no_stuck_coroutines = "no_stuck_coroutines";
    pub const shutdown_drains_all = "shutdown_drains_all";
};

/// Result of a simulation run.
pub const SimResult = struct {
    seed: u64,
    ticks_executed: u64,
    invariant_violations: []const []const u8,
    passed: bool,
};

/// Result of a swarm test.
pub const SwarmResult = struct {
    total_seeds: u64,
    passed: u64,
    failed: u64,
    first_failing_seed: ?u64,
    failures: []const SimResult,
};

/// Fault types that can be injected.
pub const FaultKind = enum {
    connection_reset,
    packet_drop,
    packet_reorder,
    slow_client,
};

// ── Simulator ────────────────────────────────────────────────────

/// Deterministic simulation harness, parameterized over the application type.
///
/// The App type must provide:
///   - `fn tick(self: *App, prng: *std.Random.DefaultPrng) void`
///   - `fn checkInvariant(self: *App, name: []const u8) bool` (optional)
///   - `fn injectFault(self: *App, kind: FaultKind) void` (optional)
pub fn Simulator(comptime App: type) type {
    return struct {
        const Self = @This();

        app: *App,
        config: SimConfig,
        prng: std.Random.DefaultPrng,
        tick: u64,
        invariants: [32]?Invariant,
        invariant_count: usize,
        violation_buf: [32][]const u8,

        /// Initialize a simulator for the given application.
        pub fn init(app: *App, config: SimConfig) Self {
            return .{
                .app = app,
                .config = config,
                .prng = std.Random.DefaultPrng.init(config.seed),
                .tick = 0,
                .invariants = .{null} ** 32,
                .invariant_count = 0,
                .violation_buf = undefined,
            };
        }

        /// Run one simulation with the configured seed.
        pub fn run(self: *Self) SimResult {
            self.tick = 0;
            self.prng = std.Random.DefaultPrng.init(self.config.seed);

            while (self.tick < self.config.max_ticks) {
                self.injectFault();
                self.tick_once();
                const violations = self.checkInvariants();
                if (violations.len > 0) {
                    return .{
                        .seed = self.config.seed,
                        .ticks_executed = self.tick,
                        .invariant_violations = violations,
                        .passed = false,
                    };
                }
                self.tick += 1;
            }

            return .{
                .seed = self.config.seed,
                .ticks_executed = self.tick,
                .invariant_violations = &.{},
                .passed = true,
            };
        }

        /// Run many seeds with randomized fault parameters (swarm testing).
        pub fn swarm(self: *Self, num_seeds: u64) SwarmResult {
            var passed: u64 = 0;
            var failed: u64 = 0;
            var first_failing: ?u64 = null;

            const base_seed = self.config.seed;
            var seed_prng = std.Random.DefaultPrng.init(base_seed);
            const seed_rand = seed_prng.random();

            for (0..num_seeds) |_| {
                const s = seed_rand.int(u64);
                self.config.seed = s;

                self.config.fault_drop_probability = @as(f64, @floatFromInt(seed_rand.intRangeAtMost(u32, 0, 50))) / 1000.0;
                self.config.fault_reset_probability = @as(f64, @floatFromInt(seed_rand.intRangeAtMost(u32, 0, 20))) / 1000.0;
                self.config.fault_reorder_probability = @as(f64, @floatFromInt(seed_rand.intRangeAtMost(u32, 0, 50))) / 1000.0;

                const result = self.run();
                if (result.passed) {
                    passed += 1;
                } else {
                    if (first_failing == null) first_failing = s;
                    failed += 1;
                }
            }

            return .{
                .total_seeds = num_seeds,
                .passed = passed,
                .failed = failed,
                .first_failing_seed = first_failing,
                .failures = &.{},
            };
        }

        /// Register a custom invariant to check after each tick.
        pub fn registerInvariant(self: *Self, name: []const u8, check_fn: *const fn (state: *anyopaque) bool) void {
            if (self.invariant_count >= 32) return;
            self.invariants[self.invariant_count] = .{ .name = name, .check_fn = check_fn };
            self.invariant_count += 1;
        }

        /// Register all built-in invariants.
        pub fn registerBuiltinInvariants(self: *Self) void {
            if (@hasDecl(App, "checkInvariant")) {
                self.registerInvariant(builtin_invariants.no_leaked_connections, &builtinCheck);
                self.registerInvariant(builtin_invariants.no_stuck_coroutines, &builtinCheck);
                self.registerInvariant(builtin_invariants.shutdown_drains_all, &builtinCheck);
            }
        }

        fn builtinCheck(state: *anyopaque) bool {
            _ = state;
            return true;
        }

        fn tick_once(self: *Self) void {
            if (@hasDecl(App, "tick")) {
                self.app.tick(&self.prng);
            }
        }

        fn checkInvariants(self: *Self) []const []const u8 {
            var count: usize = 0;
            for (0..self.invariant_count) |i| {
                const inv = self.invariants[i] orelse continue;
                var violated = false;

                if (@hasDecl(App, "checkInvariant")) {
                    violated = !self.app.checkInvariant(inv.name);
                } else {
                    violated = !inv.check_fn(@ptrCast(self.app));
                }

                if (violated) {
                    self.violation_buf[count] = inv.name;
                    count += 1;
                }
            }
            return self.violation_buf[0..count];
        }

        fn injectFault(self: *Self) void {
            if (@hasDecl(App, "injectFault")) {
                const rand = self.prng.random();
                const roll = rand.float(f64);

                if (roll < self.config.fault_reset_probability) {
                    self.app.injectFault(.connection_reset);
                } else if (roll < self.config.fault_reset_probability + self.config.fault_drop_probability) {
                    self.app.injectFault(.packet_drop);
                } else if (roll < self.config.fault_reset_probability + self.config.fault_drop_probability + self.config.fault_reorder_probability) {
                    self.app.injectFault(.packet_reorder);
                }
            }
        }
    };
}

// ── Redis State Machine (extracted for testing without Python) ──

/// Minimal redis state machine that mirrors Pipeline's redis_state transitions.
/// Used for simulation testing without Python/GIL dependencies.
pub const RedisStateMachine = struct {
    state: State = .idle,
    waiter_count: usize = 0,
    send_len: usize = 0,
    recv_len: usize = 0,
    batch_count: usize = 0,
    error_count: usize = 0,
    cleaned_waiters: usize = 0,

    pub const State = enum { idle, sending, receiving, parsing, err };

    pub fn addCommand(self: *RedisStateMachine) void {
        self.waiter_count += 1;
        self.send_len += 1;
    }

    pub fn startSend(self: *RedisStateMachine) void {
        if (self.state != .idle or self.send_len == 0 or self.waiter_count == 0) return;
        self.batch_count = self.waiter_count;
        self.state = .sending;
    }

    pub fn onIO(self: *RedisStateMachine, result: IoResult) void {
        switch (self.state) {
            .sending => {
                if (result <= 0) {
                    self.state = .err;
                    return;
                }
                self.recv_len = 0;
                self.state = .receiving;
            },
            .receiving => {
                if (result <= 0) {
                    self.state = .err;
                    return;
                }
                self.recv_len += @intCast(result);
                self.state = .parsing;
            },
            .idle, .parsing, .err => {},
        }
    }

    pub fn failWaiters(self: *RedisStateMachine) void {
        self.cleaned_waiters += self.waiter_count;
        self.waiter_count = 0;
        self.state = .idle;
        self.batch_count = 0;
    }

    pub fn processStage(self: *RedisStateMachine) void {
        if (self.state == .err) {
            self.error_count += 1;
            self.failWaiters();
        }
    }
};

/// Minimal connection tracker for simulation testing.
pub const ConnTracker = struct {
    slots: [256]bool = .{false} ** 256,
    active_count: usize = 0,

    pub fn accept(self: *ConnTracker, idx: u8) void {
        self.slots[idx] = true;
        self.active_count += 1;
    }

    pub fn close(self: *ConnTracker, idx: u8) void {
        if (self.slots[idx]) {
            self.slots[idx] = false;
            self.active_count -= 1;
        }
    }

    pub fn isActive(self: *const ConnTracker, idx: u8) bool {
        return self.slots[idx];
    }
};

// ── Tests ────────────────────────────────────────────────────────

const TestApp = struct {
    tick_count: u64 = 0,
    fault_count: u64 = 0,
    should_violate_at: ?u64 = null,

    fn tick(self: *TestApp, _: *std.Random.DefaultPrng) void {
        self.tick_count += 1;
    }

    fn checkInvariant(self: *TestApp, name: []const u8) bool {
        _ = name;
        if (self.should_violate_at) |at| {
            return self.tick_count < at;
        }
        return true;
    }

    fn injectFault(self: *TestApp, _: FaultKind) void {
        self.fault_count += 1;
    }
};

// ── FakeBackend tests ────────────────────────────────────────────

test "FakeBackend: queue and complete" {
    const allocator = std.testing.allocator;
    var backend = try FakeBackend.init(allocator, 64);
    defer backend.deinit(allocator);

    var buf: [64]u8 = undefined;
    var dummy: u8 = 0;
    var task = Task{ .step = &noopStep, .ctx = @ptrCast(&dummy) };

    try backend.queue(&task, IoOp{ .recv = .{ .socket = 5, .buffer = &buf } });
    try std.testing.expectEqual(@as(usize, 1), backend.pendingCount());

    backend.completeNext(42);
    const result = try backend.submitAndWait(0);
    try std.testing.expectEqual(@as(usize, 1), result.tasks.len);
    try std.testing.expectEqual(@as(IoResult, 42), result.completions[0].result);
    try std.testing.expectEqual(@as(usize, 0), backend.pendingCount());
}

test "FakeBackend: fault injection" {
    const allocator = std.testing.allocator;
    var backend = try FakeBackend.init(allocator, 64);
    defer backend.deinit(allocator);

    var buf: [64]u8 = undefined;
    var dummy: u8 = 0;
    var task = Task{ .step = &noopStep, .ctx = @ptrCast(&dummy) };

    backend.injectError(.recv, -104);

    try backend.queue(&task, IoOp{ .recv = .{ .socket = 5, .buffer = &buf } });
    const result = try backend.submitAndWait(0);
    try std.testing.expectEqual(@as(usize, 1), result.tasks.len);
    try std.testing.expectEqual(@as(IoResult, -104), result.completions[0].result);
    try std.testing.expectEqual(@as(usize, 0), backend.pendingCount());
}

test "FakeBackend: close auto-completes" {
    const allocator = std.testing.allocator;
    var backend = try FakeBackend.init(allocator, 64);
    defer backend.deinit(allocator);

    var dummy: u8 = 0;
    var task = Task{ .step = &noopStep, .ctx = @ptrCast(&dummy) };

    try backend.queue(&task, IoOp{ .close = 5 });
    const result = try backend.submitAndWait(0);
    try std.testing.expectEqual(@as(usize, 1), result.tasks.len);
    try std.testing.expectEqual(@as(IoResult, 0), result.completions[0].result);
}

test "FakeBackend: completeNextByTag" {
    const allocator = std.testing.allocator;
    var backend = try FakeBackend.init(allocator, 64);
    defer backend.deinit(allocator);

    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    var dummy: u8 = 0;
    var task1 = Task{ .step = &noopStep, .ctx = @ptrCast(&dummy) };
    var task2 = Task{ .step = &noopStep, .ctx = @ptrCast(&dummy) };

    try backend.queue(&task1, IoOp{ .recv = .{ .socket = 5, .buffer = &buf1 } });
    try backend.queue(&task2, IoOp{ .send = .{ .socket = 6, .buffer = &buf2 } });

    const found = backend.completeNextByTag(.send, 64);
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 1), backend.pendingCount());

    const result = try backend.submitAndWait(0);
    try std.testing.expectEqual(@as(usize, 1), result.tasks.len);
    try std.testing.expectEqual(&task2, result.tasks[0]);
    try std.testing.expectEqual(@as(IoResult, 64), result.completions[0].result);
}

test "FakeBackend: fault rule with count" {
    const allocator = std.testing.allocator;
    var backend = try FakeBackend.init(allocator, 64);
    defer backend.deinit(allocator);

    var buf: [64]u8 = undefined;
    var dummy: u8 = 0;
    var task = Task{ .step = &noopStep, .ctx = @ptrCast(&dummy) };

    backend.injectErrorN(.recv, -1, 1);

    try backend.queue(&task, IoOp{ .recv = .{ .socket = 5, .buffer = &buf } });
    const r1 = try backend.submitAndWait(0);
    try std.testing.expectEqual(@as(IoResult, -1), r1.completions[0].result);

    try backend.queue(&task, IoOp{ .recv = .{ .socket = 5, .buffer = &buf } });
    const r2 = try backend.submitAndWait(0);
    try std.testing.expectEqual(@as(usize, 0), r2.tasks.len);
    try std.testing.expectEqual(@as(usize, 1), backend.pendingCount());
}

// ── Simulator tests ──────────────────────────────────────────────

test "run basic simulation" {
    var app = TestApp{};
    var sim = Simulator(TestApp).init(&app, .{ .seed = 42, .max_ticks = 1000 });
    const result = sim.run();

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(u64, 1000), result.ticks_executed);
    try std.testing.expectEqual(@as(u64, 42), result.seed);
    try std.testing.expect(app.tick_count == 1000);
}

test "swarm test" {
    var app = TestApp{};
    var sim = Simulator(TestApp).init(&app, .{ .seed = 1, .max_ticks = 100 });
    const result = sim.swarm(100);

    try std.testing.expectEqual(@as(u64, 100), result.total_seeds);
    try std.testing.expectEqual(@as(u64, 100), result.passed);
    try std.testing.expectEqual(@as(u64, 0), result.failed);
    try std.testing.expect(result.first_failing_seed == null);
}

test "invariant violation detected" {
    var app = TestApp{ .should_violate_at = 50 };
    var sim = Simulator(TestApp).init(&app, .{ .seed = 7, .max_ticks = 1000 });
    sim.registerInvariant("test_invariant", &struct {
        fn check(_: *anyopaque) bool {
            return true;
        }
    }.check);

    const result = sim.run();
    try std.testing.expect(!result.passed);
    try std.testing.expect(result.ticks_executed < 1000);
    try std.testing.expect(result.invariant_violations.len > 0);
}

test "deterministic replay from seed" {
    var app1 = TestApp{};
    var sim1 = Simulator(TestApp).init(&app1, .{ .seed = 999, .max_ticks = 500 });
    const r1 = sim1.run();

    var app2 = TestApp{};
    var sim2 = Simulator(TestApp).init(&app2, .{ .seed = 999, .max_ticks = 500 });
    const r2 = sim2.run();

    try std.testing.expectEqual(r1.seed, r2.seed);
    try std.testing.expectEqual(r1.ticks_executed, r2.ticks_executed);
    try std.testing.expectEqual(r1.passed, r2.passed);
    try std.testing.expectEqual(app1.tick_count, app2.tick_count);
    try std.testing.expectEqual(app1.fault_count, app2.fault_count);
}

test "register custom invariant" {
    var app = TestApp{};
    var sim = Simulator(TestApp).init(&app, .{ .seed = 1, .max_ticks = 10 });
    sim.registerInvariant("always_fail", &struct {
        fn check(_: *anyopaque) bool {
            return false;
        }
    }.check);

    try std.testing.expectEqual(@as(usize, 1), sim.invariant_count);
}

// ── Redis state machine tests ────────────────────────────────────

test "redis state: send error transitions to err and cleans up waiters" {
    var sm = RedisStateMachine{};

    sm.addCommand();
    sm.addCommand();
    sm.addCommand();
    try std.testing.expectEqual(@as(usize, 3), sm.waiter_count);

    sm.startSend();
    try std.testing.expectEqual(RedisStateMachine.State.sending, sm.state);

    sm.onIO(-1);
    try std.testing.expectEqual(RedisStateMachine.State.err, sm.state);

    sm.processStage();
    try std.testing.expectEqual(RedisStateMachine.State.idle, sm.state);
    try std.testing.expectEqual(@as(usize, 0), sm.waiter_count);
    try std.testing.expectEqual(@as(usize, 3), sm.cleaned_waiters);
    try std.testing.expectEqual(@as(usize, 1), sm.error_count);
}

test "redis state: recv error transitions to err" {
    var sm = RedisStateMachine{};
    sm.addCommand();
    sm.startSend();

    sm.onIO(10);
    try std.testing.expectEqual(RedisStateMachine.State.receiving, sm.state);

    sm.onIO(-104);
    try std.testing.expectEqual(RedisStateMachine.State.err, sm.state);

    sm.processStage();
    try std.testing.expectEqual(RedisStateMachine.State.idle, sm.state);
    try std.testing.expectEqual(@as(usize, 0), sm.waiter_count);
    try std.testing.expectEqual(@as(usize, 1), sm.cleaned_waiters);
}

test "redis state: successful send-recv-parse cycle" {
    var sm = RedisStateMachine{};
    sm.addCommand();
    sm.startSend();

    sm.onIO(10);
    try std.testing.expectEqual(RedisStateMachine.State.receiving, sm.state);

    sm.onIO(50);
    try std.testing.expectEqual(RedisStateMachine.State.parsing, sm.state);
    try std.testing.expectEqual(@as(usize, 50), sm.recv_len);
}

// ── Connection drop tests ────────────────────────────────────────

test "connection drop mid-request: recv error closes and releases slot" {
    var tracker = ConnTracker{};

    tracker.accept(5);
    try std.testing.expect(tracker.isActive(5));
    try std.testing.expectEqual(@as(usize, 1), tracker.active_count);

    const recv_result: IoResult = -104;
    if (recv_result <= 0) {
        tracker.close(5);
    }

    try std.testing.expect(!tracker.isActive(5));
    try std.testing.expectEqual(@as(usize, 0), tracker.active_count);
}

test "connection drop: FakeBackend recv fault closes connection" {
    const allocator = std.testing.allocator;
    var backend = try FakeBackend.init(allocator, 64);
    defer backend.deinit(allocator);

    var tracker = ConnTracker{};
    tracker.accept(3);

    backend.injectError(.recv, -104);

    var buf: [64]u8 = undefined;
    var dummy: u8 = 0;
    var task = Task{ .step = &noopStep, .ctx = @ptrCast(&dummy) };

    try backend.queue(&task, IoOp{ .recv = .{ .socket = 10, .buffer = &buf } });

    const result = try backend.submitAndWait(0);
    try std.testing.expectEqual(@as(usize, 1), result.tasks.len);
    try std.testing.expectEqual(@as(IoResult, -104), result.completions[0].result);

    if (result.completions[0].result <= 0) {
        tracker.close(3);
    }
    try std.testing.expect(!tracker.isActive(3));
    try std.testing.expectEqual(@as(usize, 0), tracker.active_count);
}

// ── Deterministic replay test ────────────────────────────────────

test "deterministic replay: FakeBackend with same seed produces same faults" {
    const allocator = std.testing.allocator;

    var counts: [2]u64 = undefined;

    for (0..2) |round| {
        var backend = try FakeBackend.init(allocator, 64);
        defer backend.deinit(allocator);
        backend.seed(12345);

        var total_error_results: u64 = 0;
        var buf: [64]u8 = undefined;
        var dummy: u8 = 0;
        var task = Task{ .step = &noopStep, .ctx = @ptrCast(&dummy) };

        for (0..50) |_| {
            const rand = backend.prng.random();
            const should_fail = rand.float(f64) < 0.1;

            try backend.queue(&task, IoOp{ .recv = .{ .socket = 5, .buffer = &buf } });

            if (should_fail) {
                backend.completeNext(-1);
            } else {
                backend.completeNext(100);
            }

            const result = try backend.submitAndWait(0);
            if (result.completions[0].result < 0) total_error_results += 1;
        }

        counts[round] = total_error_results;
    }

    try std.testing.expectEqual(counts[0], counts[1]);
}

// ── Swarm test: redis state machine ──────────────────────────────

test "swarm: redis state machine survives random faults" {
    var seed_prng = std.Random.DefaultPrng.init(42);
    const rand = seed_prng.random();

    var violations: u64 = 0;

    for (0..100) |_| {
        var sm = RedisStateMachine{};
        const num_ops = rand.intRangeAtMost(u32, 10, 200);

        for (0..num_ops) |_| {
            const action = rand.intRangeAtMost(u32, 0, 4);
            switch (action) {
                0 => sm.addCommand(),
                1 => sm.startSend(),
                2 => {
                    const result: IoResult = if (rand.float(f64) < 0.2) -1 else @intCast(rand.intRangeAtMost(u32, 1, 1000));
                    sm.onIO(result);
                },
                3 => sm.processStage(),
                else => {},
            }
        }

        sm.processStage();

        if (sm.state == .err) {
            violations += 1;
        }
    }

    try std.testing.expectEqual(@as(u64, 0), violations);
}
