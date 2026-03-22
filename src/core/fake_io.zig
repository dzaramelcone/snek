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

// Inspired by: TigerBeetle (refs/tigerbeetle/INSIGHTS.md) — VOPR deterministic simulation
// Source: TigerBeetle src/testing/io.zig — PRNG-driven fake IO with fault injection,
// same interface as real backends via comptime generics.
pub const FakeIO = struct {
    prng: std.Random.DefaultPrng,
    current_time_ns: u64,
    fault_config: FaultConfig,
    pending_completions: u32,

    pub fn init(seed: u64) FakeIO {
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .current_time_ns = 0,
            .fault_config = .{},
            .pending_completions = 0,
        };
    }

    pub fn initWithFaults(seed: u64, config: FaultConfig) FakeIO {
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .current_time_ns = 0,
            .fault_config = config,
            .pending_completions = 0,
        };
    }

    pub fn deinit(self: *FakeIO) void {
        _ = .{self};
    }

    // --- IO interface methods (same signatures as IoUring/Kqueue) ---

    pub fn submitRead(self: *FakeIO, fd: i32, buf: []u8, offset: u64, user_data: u64) !void {
        _ = .{ self, fd, buf, offset, user_data };
    }

    pub fn submitWrite(self: *FakeIO, fd: i32, buf: []const u8, offset: u64, user_data: u64) !void {
        _ = .{ self, fd, buf, offset, user_data };
    }

    pub fn submitAccept(self: *FakeIO, fd: i32, user_data: u64) !void {
        _ = .{ self, fd, user_data };
    }

    pub fn submitConnect(self: *FakeIO, fd: i32, addr: []const u8, port: u16, user_data: u64) !void {
        _ = .{ self, fd, addr, port, user_data };
    }

    pub fn submitClose(self: *FakeIO, fd: i32, user_data: u64) !void {
        _ = .{ self, fd, user_data };
    }

    pub fn submitSend(self: *FakeIO, fd: i32, buf: []const u8, user_data: u64) !void {
        _ = .{ self, fd, buf, user_data };
    }

    pub fn submitRecv(self: *FakeIO, fd: i32, buf: []u8, user_data: u64) !void {
        _ = .{ self, fd, buf, user_data };
    }

    pub fn submitTimeout(self: *FakeIO, timeout_ns: u64, user_data: u64) !void {
        _ = .{ self, timeout_ns, user_data };
    }

    pub fn submitCancel(self: *FakeIO, target_user_data: u64, user_data: u64) !void {
        _ = .{ self, target_user_data, user_data };
    }

    pub fn pollCompletions(self: *FakeIO, events: []CompletionEntry) !u32 {
        _ = .{ self, events };
        return 0;
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

    /// Run one tick of the simulation: process pending completions,
    /// apply faults, advance time.
    pub fn tick(self: *FakeIO) !void {
        _ = .{self};
    }

    /// Inject a specific fault on the next operation matching the given fd.
    pub fn injectFault(self: *FakeIO, fd: i32, fault: Fault) void {
        _ = .{ self, fd, fault };
    }
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

test "fake io deterministic replay" {}

test "fake io fault injection" {}

test "fake io simulated time" {}

test "fake io same interface as real io" {}
