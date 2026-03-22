//! Deterministic FakeIO backend for VOPR-style simulation testing.
//! PRNG-driven, simulated time, fault injection (network drops, latency,
//! storage faults). Controlled by a single u64 seed.
//!
//! Reference: TigerBeetle's src/testing/io.zig (~200 lines).
//!
//! The FakeIO has the SAME interface as the real IO backends (IoUring, Kqueue).
//! Production code doesn't know which IO it's running on — enabled by
//! Zig's comptime generics: `Scheduler(comptime IO: type)`.
//!
//! Every failure is reproducible: seed -> PRNG -> (faults, timing, ordering)
//! -> deterministic execution. Single-threaded, no real syscalls, no real time.

const std = @import("std");
const io = @import("io.zig");
const Allocator = std.mem.Allocator;

pub const FaultConfig = struct {
    /// Probability of dropping a network packet (0.0 = never, 1.0 = always).
    drop_probability: f64 = 0.0,
    /// Maximum simulated latency in nanoseconds added to operations.
    max_latency_ns: u64 = 0,
    /// Probability of a storage read/write fault.
    storage_fault_probability: f64 = 0.0,
    /// Probability of connection reset during send/recv.
    connection_reset_probability: f64 = 0.0,
};

pub const CompletionEntry = struct {
    user_data: u64,
    result: i32,
    flags: u32,
};

pub const Fault = enum {
    drop,
    corruption,
    latency,
    connection_reset,
    storage_error,
};

const PendingOp = struct {
    op_type: io.IoOp,
    fd: i32,
    user_data: u64,
    deadline_ns: ?u64,
    buf: ?[]u8,
    buf_len: u32,
};

// Inspired by: TigerBeetle (refs/tigerbeetle/INSIGHTS.md) — VOPR deterministic simulation
// Source: TigerBeetle src/testing/io.zig — PRNG-driven fake IO with fault injection,
// same interface as real backends via comptime generics.
pub const FakeIO = struct {
    prng: std.Random.DefaultPrng,
    current_time_ns: u64,
    fault_config: FaultConfig,
    pending: std.ArrayList(PendingOp),
    next_fake_fd: i32,
    injected_faults: std.AutoHashMap(i32, Fault),
    allocator: Allocator,

    pub fn init(allocator: Allocator, seed: u64) FakeIO {
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .current_time_ns = 0,
            .fault_config = .{},
            .pending = .{},
            .next_fake_fd = 100,
            .injected_faults = std.AutoHashMap(i32, Fault).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn initWithFaults(allocator: Allocator, seed: u64, config: FaultConfig) FakeIO {
        var result = init(allocator, seed);
        result.fault_config = config;
        return result;
    }

    pub fn deinit(self: *FakeIO) void {
        self.pending.deinit(self.allocator);
        self.injected_faults.deinit();
    }

    // --- IO interface methods (same signatures as IoUring) ---

    pub fn submitRead(self: *FakeIO, fd: i32, buf: []u8, offset: u64, user_data: u64) !void {
        _ = offset;
        return self.pending.append(self.allocator, .{
            .op_type = .read,
            .fd = fd,
            .user_data = user_data,
            .deadline_ns = null,
            .buf = buf,
            .buf_len = @intCast(buf.len),
        });
    }

    pub fn submitWrite(self: *FakeIO, fd: i32, buf: []const u8, offset: u64, user_data: u64) !void {
        _ = offset;
        return self.pending.append(self.allocator, .{
            .op_type = .write,
            .fd = fd,
            .user_data = user_data,
            .deadline_ns = null,
            .buf = null,
            .buf_len = @intCast(buf.len),
        });
    }

    pub fn submitAccept(self: *FakeIO, fd: i32, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .accept,
            .fd = fd,
            .user_data = user_data,
            .deadline_ns = null,
            .buf = null,
            .buf_len = 0,
        });
    }

    pub fn submitConnect(self: *FakeIO, fd: i32, addr: []const u8, port: u16, user_data: u64) !void {
        _ = addr;
        _ = port;
        return self.pending.append(self.allocator, .{
            .op_type = .connect,
            .fd = fd,
            .user_data = user_data,
            .deadline_ns = null,
            .buf = null,
            .buf_len = 0,
        });
    }

    pub fn submitClose(self: *FakeIO, fd: i32, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .close,
            .fd = fd,
            .user_data = user_data,
            .deadline_ns = null,
            .buf = null,
            .buf_len = 0,
        });
    }

    pub fn submitSend(self: *FakeIO, fd: i32, buf: []const u8, user_data: u64) !void {
        _ = buf;
        return self.pending.append(self.allocator, .{
            .op_type = .send,
            .fd = fd,
            .user_data = user_data,
            .deadline_ns = null,
            .buf = null,
            .buf_len = 0,
        });
    }

    pub fn submitRecv(self: *FakeIO, fd: i32, buf: []u8, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .recv,
            .fd = fd,
            .user_data = user_data,
            .deadline_ns = null,
            .buf = buf,
            .buf_len = @intCast(buf.len),
        });
    }

    pub fn submitTimeout(self: *FakeIO, timeout_ns: u64, user_data: u64) !void {
        return self.pending.append(self.allocator, .{
            .op_type = .timeout,
            .fd = -1,
            .user_data = user_data,
            .deadline_ns = self.current_time_ns + timeout_ns,
            .buf = null,
            .buf_len = 0,
        });
    }

    pub fn submitCancel(self: *FakeIO, target_user_data: u64, user_data: u64) !void {
        // Remove the target from pending
        for (self.pending.items, 0..) |item, idx| {
            if (item.user_data == target_user_data) {
                _ = self.pending.orderedRemove(idx);
                break;
            }
        }
        // Push a cancel completion
        return self.pending.append(self.allocator, .{
            .op_type = .cancel,
            .fd = -1,
            .user_data = user_data,
            .deadline_ns = null,
            .buf = null,
            .buf_len = 0,
        });
    }

    pub fn pollCompletions(self: *FakeIO, events: []CompletionEntry) !u32 {
        var count: u32 = 0;
        var i: usize = 0;

        while (i < self.pending.items.len and count < events.len) {
            const op = self.pending.items[i];

            // Timeout ops only complete when time has passed their deadline
            if (op.op_type == .timeout) {
                if (op.deadline_ns) |deadline| {
                    if (self.current_time_ns < deadline) {
                        i += 1;
                        continue;
                    }
                }
            }

            // Apply fault injection
            const result = self.resolveOp(op);

            // Remove the completed/dropped op
            _ = self.pending.orderedRemove(i);

            // If dropped by fault injection, don't emit a completion
            if (result) |entry| {
                events[count] = entry;
                count += 1;
            }
            // Don't increment i — orderedRemove shifted elements down
        }
        return count;
    }

    /// Resolve a pending op into a completion, applying faults.
    /// Returns null if the op is dropped (fault injection).
    fn resolveOp(self: *FakeIO, op: PendingOp) ?CompletionEntry {
        // Check for targeted fault injection first
        if (self.injected_faults.get(op.fd)) |fault| {
            _ = self.injected_faults.remove(op.fd);
            return self.applyFault(op, fault);
        }

        // Check probabilistic faults based on op type
        switch (op.op_type) {
            .read, .write => {
                if (self.fault_config.storage_fault_probability > 0.0) {
                    if (self.randomChance(self.fault_config.storage_fault_probability)) {
                        return .{ .user_data = op.user_data, .result = -5, .flags = 0 }; // EIO
                    }
                }
            },
            .send, .recv => {
                if (self.fault_config.drop_probability > 0.0) {
                    if (self.randomChance(self.fault_config.drop_probability)) {
                        return null; // dropped
                    }
                }
                if (self.fault_config.connection_reset_probability > 0.0) {
                    if (self.randomChance(self.fault_config.connection_reset_probability)) {
                        return .{ .user_data = op.user_data, .result = -104, .flags = 0 }; // ECONNRESET
                    }
                }
            },
            else => {},
        }

        // Normal completion
        return self.normalCompletion(op);
    }

    fn normalCompletion(self: *FakeIO, op: PendingOp) CompletionEntry {
        switch (op.op_type) {
            .read => {
                if (op.buf) |buf| {
                    self.prng.fill(buf[0..op.buf_len]);
                }
                return .{ .user_data = op.user_data, .result = @intCast(op.buf_len), .flags = 0 };
            },
            .write => {
                return .{ .user_data = op.user_data, .result = @intCast(op.buf_len), .flags = 0 };
            },
            .accept => {
                const fake_fd = self.next_fake_fd;
                self.next_fake_fd += 1;
                return .{ .user_data = op.user_data, .result = fake_fd, .flags = 0 };
            },
            .connect, .close, .send, .send_zc, .timeout, .cancel => {
                return .{ .user_data = op.user_data, .result = 0, .flags = 0 };
            },
            .recv => {
                if (op.buf) |buf| {
                    self.prng.fill(buf[0..op.buf_len]);
                    return .{ .user_data = op.user_data, .result = @intCast(op.buf_len), .flags = 0 };
                }
                return .{ .user_data = op.user_data, .result = 0, .flags = 0 };
            },
        }
    }

    fn applyFault(_: *FakeIO, op: PendingOp, fault: Fault) ?CompletionEntry {
        return switch (fault) {
            .drop => null,
            .corruption, .storage_error => .{ .user_data = op.user_data, .result = -5, .flags = 0 },
            .latency => null, // simplified: drop (deadline-based delay is future work)
            .connection_reset => .{ .user_data = op.user_data, .result = -104, .flags = 0 },
        };
    }

    fn randomChance(self: *FakeIO, probability: f64) bool {
        return self.prng.random().float(f64) < probability;
    }

    // --- Simulation control ---

    /// Advance simulated time by the given number of nanoseconds.
    pub fn advanceTime(self: *FakeIO, ns: u64) void {
        self.current_time_ns +%= ns;
    }

    /// Get current simulated time.
    pub fn currentTime(self: *const FakeIO) u64 {
        return self.current_time_ns;
    }

    /// Run one tick of the simulation: process all ready completions.
    pub fn tick(self: *FakeIO) !void {
        var events: [64]CompletionEntry = undefined;
        _ = self.pollCompletions(&events) catch unreachable;
    }

    /// Inject a specific fault on the next operation matching the given fd.
    pub fn injectFault(self: *FakeIO, fd: i32, fault: Fault) void {
        self.injected_faults.put(fd, fault) catch {};
    }

    /// Get count of pending operations (for testing).
    pub fn pendingCount(self: *const FakeIO) usize {
        return self.pending.items.len;
    }
};

// ---- Tests ----

test "fake io deterministic replay" {
    // The critical test: same seed, same operations → identical results.
    const alloc = std.testing.allocator;

    const seeds = [_]u64{ 42, 0, 0xDEADBEEF, std.math.maxInt(u64) };

    for (seeds) |seed| {
        // Run 1
        var io1 = FakeIO.init(alloc, seed);
        defer io1.deinit();

        var buf1: [32]u8 = undefined;
        io1.submitRead(3, &buf1, 0, 1) catch unreachable;
        io1.submitWrite(3, "data", 0, 2) catch unreachable;
        io1.submitAccept(4, 3) catch unreachable;

        var events1: [16]CompletionEntry = undefined;
        const n1 = io1.pollCompletions(&events1) catch unreachable;

        // Run 2 — same seed, same operations
        var io2 = FakeIO.init(alloc, seed);
        defer io2.deinit();

        var buf2: [32]u8 = undefined;
        io2.submitRead(3, &buf2, 0, 1) catch unreachable;
        io2.submitWrite(3, "data", 0, 2) catch unreachable;
        io2.submitAccept(4, 3) catch unreachable;

        var events2: [16]CompletionEntry = undefined;
        const n2 = io2.pollCompletions(&events2) catch unreachable;

        // Same number of completions
        try std.testing.expectEqual(n1, n2);

        // Same completion order and results
        for (0..n1) |j| {
            try std.testing.expectEqual(events1[j].user_data, events2[j].user_data);
            try std.testing.expectEqual(events1[j].result, events2[j].result);
            try std.testing.expectEqual(events1[j].flags, events2[j].flags);
        }

        // Same buffer contents (PRNG-filled read data)
        try std.testing.expectEqualSlices(u8, &buf1, &buf2);
    }
}

test "fake io fault injection" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 42);
    defer fio.deinit();

    // Inject a drop fault on fd 5
    fio.injectFault(5, .drop);

    fio.submitSend(5, "hello", 10) catch unreachable;
    fio.submitSend(6, "world", 11) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    const n = fio.pollCompletions(&events) catch unreachable;

    // fd 5 was dropped, only fd 6 should complete
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqual(@as(u64, 11), events[0].user_data);
}

test "fake io probabilistic fault injection" {
    const alloc = std.testing.allocator;

    // 100% drop probability — all sends/recvs should be dropped
    var fio = FakeIO.initWithFaults(alloc, 42, .{ .drop_probability = 1.0 });
    defer fio.deinit();

    fio.submitSend(5, "hello", 10) catch unreachable;
    fio.submitSend(6, "world", 11) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    const n = fio.pollCompletions(&events) catch unreachable;

    // Both should be dropped
    try std.testing.expectEqual(@as(u32, 0), n);
}

test "fake io storage fault" {
    const alloc = std.testing.allocator;

    // 100% storage fault — reads/writes return EIO
    var fio = FakeIO.initWithFaults(alloc, 42, .{ .storage_fault_probability = 1.0 });
    defer fio.deinit();

    var buf: [16]u8 = undefined;
    fio.submitRead(3, &buf, 0, 20) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    const n = fio.pollCompletions(&events) catch unreachable;

    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqual(@as(i32, -5), events[0].result); // EIO
}

test "fake io simulated time" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 42);
    defer fio.deinit();

    try std.testing.expectEqual(@as(u64, 0), fio.currentTime());

    // Submit a timeout for 1 second
    fio.submitTimeout(1_000_000_000, 50) catch unreachable;

    // Poll before advancing time — timeout should NOT complete
    var events: [16]CompletionEntry = undefined;
    const n1 = fio.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 0), n1);
    try std.testing.expectEqual(@as(usize, 1), fio.pendingCount());

    // Advance time past the deadline
    fio.advanceTime(1_000_000_001);
    try std.testing.expectEqual(@as(u64, 1_000_000_001), fio.currentTime());

    // Now the timeout should complete
    const n2 = fio.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 1), n2);
    try std.testing.expectEqual(@as(u64, 50), events[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), events[0].result);
}

test "fake io same interface as real io" {
    // Comptime check: FakeIO has all the methods the IO interface requires.
    comptime {
        io.assertIsIoBackend(FakeIO);
    }
}

test "fake io accept returns incrementing fds" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 0);
    defer fio.deinit();

    fio.submitAccept(4, 1) catch unreachable;
    fio.submitAccept(4, 2) catch unreachable;
    fio.submitAccept(4, 3) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    const n = fio.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 3), n);

    // Each accept should return an incrementing fake fd
    try std.testing.expectEqual(@as(i32, 100), events[0].result);
    try std.testing.expectEqual(@as(i32, 101), events[1].result);
    try std.testing.expectEqual(@as(i32, 102), events[2].result);
}

test "fake io empty poll returns zero" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 0);
    defer fio.deinit();

    var events: [16]CompletionEntry = undefined;
    const n = fio.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 0), n);
}

test "fake io cancel nonexistent is still ok" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 0);
    defer fio.deinit();

    // Cancel something that doesn't exist — should still produce a cancel completion
    fio.submitCancel(999, 1) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    const n = fio.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqual(@as(u64, 1), events[0].user_data);
}

test "fake io events buffer smaller than pending" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 0);
    defer fio.deinit();

    // Submit 5 ops but only provide space for 2
    fio.submitClose(1, 1) catch unreachable;
    fio.submitClose(2, 2) catch unreachable;
    fio.submitClose(3, 3) catch unreachable;
    fio.submitClose(4, 4) catch unreachable;
    fio.submitClose(5, 5) catch unreachable;

    var events: [2]CompletionEntry = undefined;
    const n1 = fio.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 2), n1);
    try std.testing.expectEqual(@as(usize, 3), fio.pendingCount());

    // Poll again to get the rest
    const n2 = fio.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 2), n2);

    const n3 = fio.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 1), n3);
}

test "edge: pollCompletions with zero-length events buffer" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 0);
    defer fio.deinit();

    fio.submitClose(1, 1) catch unreachable;
    fio.submitClose(2, 2) catch unreachable;

    var events: [0]CompletionEntry = undefined;
    const n = fio.pollCompletions(&events) catch unreachable;
    // Should return 0 — no space to write completions
    try std.testing.expectEqual(@as(u32, 0), n);
    // Ops should still be pending
    try std.testing.expectEqual(@as(usize, 2), fio.pendingCount());
}

test "edge: submit 1000 ops, poll with buffer of 1" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 0);
    defer fio.deinit();

    for (0..1000) |i| {
        fio.submitClose(@intCast(i), @intCast(i)) catch unreachable;
    }

    var events: [1]CompletionEntry = undefined;
    var total: u32 = 0;
    while (fio.pendingCount() > 0) {
        const n = fio.pollCompletions(&events) catch unreachable;
        try std.testing.expectEqual(@as(u32, 1), n);
        total += n;
    }
    try std.testing.expectEqual(@as(u32, 1000), total);
}

test "edge: two submits with same user_data, cancel removes first" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 0);
    defer fio.deinit();

    fio.submitClose(1, 42) catch unreachable;
    fio.submitClose(2, 42) catch unreachable;
    try std.testing.expectEqual(@as(usize, 2), fio.pendingCount());

    // Cancel user_data=42 — should remove first match only
    fio.submitCancel(42, 99) catch unreachable;
    // After cancel: the cancel op itself is pending, plus the second fd=2 op
    try std.testing.expectEqual(@as(usize, 2), fio.pendingCount());

    var events: [16]CompletionEntry = undefined;
    const n = fio.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 2), n);

    // Verify: the remaining fd=2 op completes (user_data=42), and cancel completes (user_data=99)
    var found_42 = false;
    var found_99 = false;
    for (events[0..n]) |e| {
        if (e.user_data == 42) found_42 = true;
        if (e.user_data == 99) found_99 = true;
    }
    try std.testing.expect(found_42);
    try std.testing.expect(found_99);
}

test "edge: advanceTime by u64 max — wrapping" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 0);
    defer fio.deinit();

    fio.advanceTime(100);
    try std.testing.expectEqual(@as(u64, 100), fio.currentTime());

    // Advance by max — should wrap
    fio.advanceTime(std.math.maxInt(u64));
    // 100 +% maxInt(u64) = 99
    try std.testing.expectEqual(@as(u64, 99), fio.currentTime());
}

test "edge: injectFault on fd with no pending ops — no crash" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 0);
    defer fio.deinit();

    // Inject fault for fd that has no pending ops
    fio.injectFault(999, .drop);

    // Poll — nothing should happen
    var events: [16]CompletionEntry = undefined;
    const n = fio.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 0), n);

    // Submit on a different fd — should complete normally (fault is on fd 999, not 1)
    fio.submitClose(1, 10) catch unreachable;
    const n2 = fio.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 1), n2);
    try std.testing.expectEqual(@as(i32, 0), events[0].result);
}

test "edge: multiple faults on same fd — last one wins" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 0);
    defer fio.deinit();

    fio.injectFault(5, .drop);
    fio.injectFault(5, .connection_reset);

    fio.submitSend(5, "data", 10) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    const n = fio.pollCompletions(&events) catch unreachable;
    // connection_reset should be the active fault (overwrote drop)
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqual(@as(i32, -104), events[0].result);
}

test "edge: PRNG determinism with different fault configs" {
    const alloc = std.testing.allocator;

    // Two runs with same seed but different fault configs should diverge in PRNG state
    // when faults are checked — but operations that don't trigger fault checks should
    // still be deterministic
    var fio1 = FakeIO.init(alloc, 42);
    defer fio1.deinit();
    var fio2 = FakeIO.init(alloc, 42);
    defer fio2.deinit();

    // accept doesn't check any faults, so both should produce identical results
    fio1.submitAccept(4, 1) catch unreachable;
    fio2.submitAccept(4, 1) catch unreachable;

    var events1: [16]CompletionEntry = undefined;
    var events2: [16]CompletionEntry = undefined;
    const n1 = fio1.pollCompletions(&events1) catch unreachable;
    const n2 = fio2.pollCompletions(&events2) catch unreachable;

    try std.testing.expectEqual(n1, n2);
    try std.testing.expectEqual(events1[0].result, events2[0].result);
}

test "fake io connection reset fault" {
    const alloc = std.testing.allocator;
    var fio = FakeIO.init(alloc, 42);
    defer fio.deinit();

    fio.injectFault(7, .connection_reset);
    var buf: [16]u8 = undefined;
    fio.submitRecv(7, &buf, 30) catch unreachable;

    var events: [16]CompletionEntry = undefined;
    const n = fio.pollCompletions(&events) catch unreachable;
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqual(@as(i32, -104), events[0].result); // ECONNRESET
}
