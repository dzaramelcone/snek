//! FakeIO backend — deterministic, in-memory IO for simulation testing.
//!
//! Same interface as Kqueue/IoUring but stores ops in memory and returns
//! pre-programmed or PRNG-driven results. No syscalls.
//!
//! This module is intended to be imported by the simulation harness.
//! For standalone tests, see src/testing/simulation.zig.

const std = @import("std");
const IoOp = @import("io_op.zig").IoOp;
const IoResult = @import("io_op.zig").IoResult;
const Task = @import("../task.zig").Task;

const MAX_OPS = 1024;

pub const FaultRule = struct {
    op_tag: OpTag,
    result: IoResult,
    /// Number of times to fire. 0 = infinite.
    count: u32 = 1,
    fired: u32 = 0,
};

pub const OpTag = enum {
    accept,
    connect,
    recv,
    send,
    sendv,
    close,
    timer,
};

pub fn ioOpTag(op: IoOp) OpTag {
    return switch (op) {
        .accept => .accept,
        .connect => .connect,
        .recv => .recv,
        .send => .send,
        .sendv => .sendv,
        .close => .close,
        .timer => .timer,
    };
}

pub const PendingOp = struct {
    task: *Task,
    op: IoOp,
};

pub const Completion = struct {
    task: *Task,
    result: IoResult,
};

pub const FakeBackend = struct {
    pending: [MAX_OPS]PendingOp = undefined,
    pending_count: usize = 0,

    completions: [MAX_OPS]Completion = undefined,
    completion_count: usize = 0,

    fault_rules: [64]FaultRule = undefined,
    fault_count: usize = 0,

    tasks_buf: []*Task,
    result_buf: []IoResult,

    prng: std.Random.DefaultPrng,

    /// Total ops queued (lifetime counter).
    total_queued: u64 = 0,
    /// Total completions returned (lifetime counter).
    total_completed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, max_events: u16) !FakeBackend {
        return .{
            .tasks_buf = try allocator.alloc(*Task, max_events),
            .result_buf = try allocator.alloc(IoResult, max_events),
            .prng = std.Random.DefaultPrng.init(0),
        };
    }

    pub fn deinit(self: *FakeBackend, allocator: std.mem.Allocator) void {
        allocator.free(self.tasks_buf);
        allocator.free(self.result_buf);
    }

    /// Queue an IO operation. Stores it — does not execute.
    pub fn queue(self: *FakeBackend, task: *Task, op: IoOp) !void {
        if (self.pending_count >= MAX_OPS) return error.Overflow;
        task.pending_op = op;
        self.pending[self.pending_count] = .{ .task = task, .op = op };
        self.pending_count += 1;
        self.total_queued += 1;
    }

    /// Return completions that have been staged via completeNext/completeAll/injectError.
    /// Close ops are completed immediately (matching kqueue behavior).
    pub fn submitAndWait(self: *FakeBackend, wait_nr: u32) !struct { tasks: []*Task, results: []IoResult } {
        _ = wait_nr;

        // Auto-complete close ops
        var i: usize = 0;
        while (i < self.pending_count) {
            if (ioOpTag(self.pending[i].op) == .close) {
                self.stageCompletion(self.pending[i].task, 0);
                self.removePending(i);
            } else {
                i += 1;
            }
        }

        // Check fault rules against pending ops
        i = 0;
        while (i < self.pending_count) {
            const tag = ioOpTag(self.pending[i].op);
            if (self.matchFaultRule(tag)) |result| {
                self.stageCompletion(self.pending[i].task, result);
                self.removePending(i);
            } else {
                i += 1;
            }
        }

        // Copy staged completions to output buffers
        const count = @min(self.completion_count, self.tasks_buf.len);
        for (0..count) |j| {
            self.tasks_buf[j] = self.completions[j].task;
            self.result_buf[j] = self.completions[j].result;
        }
        self.total_completed += count;

        // Shift remaining completions
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
            .results = self.result_buf[0..count],
        };
    }

    // ── Test helpers ──────────────────────────────────────────────

    /// Seed the PRNG (for deterministic replay).
    pub fn setSeed(self: *FakeBackend, s: u64) void {
        self.prng = std.Random.DefaultPrng.init(s);
    }

    /// Manually complete the next pending op with the given result.
    pub fn completeNext(self: *FakeBackend, result: IoResult) void {
        if (self.pending_count == 0) return;
        self.stageCompletion(self.pending[0].task, result);
        self.removePending(0);
    }

    /// Complete the next pending op matching a specific tag.
    pub fn completeNextByTag(self: *FakeBackend, tag: OpTag, result: IoResult) bool {
        for (0..self.pending_count) |j| {
            if (ioOpTag(self.pending[j].op) == tag) {
                self.stageCompletion(self.pending[j].task, result);
                self.removePending(j);
                return true;
            }
        }
        return false;
    }

    /// Complete all pending ops with the given result.
    pub fn completeAll(self: *FakeBackend, result: IoResult) void {
        for (0..self.pending_count) |j| {
            self.stageCompletion(self.pending[j].task, result);
        }
        self.pending_count = 0;
    }

    /// Add a fault rule: any op matching this tag gets this result.
    pub fn injectError(self: *FakeBackend, tag: OpTag, errno: IoResult) void {
        if (self.fault_count >= self.fault_rules.len) return;
        self.fault_rules[self.fault_count] = .{
            .op_tag = tag,
            .result = errno,
        };
        self.fault_count += 1;
    }

    /// Add a fault rule with a fire count.
    pub fn injectErrorN(self: *FakeBackend, tag: OpTag, errno: IoResult, count: u32) void {
        if (self.fault_count >= self.fault_rules.len) return;
        self.fault_rules[self.fault_count] = .{
            .op_tag = tag,
            .result = errno,
            .count = count,
        };
        self.fault_count += 1;
    }

    /// Clear all fault rules.
    pub fn clearFaults(self: *FakeBackend) void {
        self.fault_count = 0;
    }

    /// Number of pending (not yet completed) ops.
    pub fn pendingCount(self: *const FakeBackend) usize {
        return self.pending_count;
    }

    /// Tag of the i-th pending op.
    pub fn pendingTag(self: *const FakeBackend, idx: usize) ?OpTag {
        if (idx >= self.pending_count) return null;
        return ioOpTag(self.pending[idx].op);
    }

    // ── Internal ─────────────────────────────────────────────────

    fn stageCompletion(self: *FakeBackend, task: *Task, result: IoResult) void {
        if (self.completion_count >= MAX_OPS) return;
        self.completions[self.completion_count] = .{ .task = task, .result = result };
        self.completion_count += 1;
    }

    fn removePending(self: *FakeBackend, idx: usize) void {
        self.pending_count -= 1;
        if (idx < self.pending_count) {
            self.pending[idx] = self.pending[self.pending_count];
        }
    }

    fn matchFaultRule(self: *FakeBackend, tag: OpTag) ?IoResult {
        for (0..self.fault_count) |j| {
            if (self.fault_rules[j].op_tag == tag) {
                const rule = &self.fault_rules[j];
                if (rule.count == 0) {
                    // infinite
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
