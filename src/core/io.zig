//! Platform-specific async I/O backend abstraction.
//! Uses comptime platform switch (Ghostty pattern), not tagged union.
//!
//! `pub fn IoBackend(comptime is_test: bool) type` selects the backend:
//!   - Test mode: FakeIO (deterministic PRNG-driven, for simulation testing)
//!   - Linux:     io_uring (completion-based, production target)
//!   - macOS:     kqueue (readiness-based, dev fallback)
//!   - Other:     @compileError
//!
//! All subsystems are parameterized on `comptime IO: type`. This is the #1
//! architectural decision — enables VOPR-style deterministic simulation testing.

const std = @import("std");
const builtin = @import("builtin");
const io_uring = @import("io_uring.zig");
const kqueue = @import("kqueue.zig");
const fake_io = @import("fake_io.zig");

/// Comptime platform switch for the I/O backend.
/// In test mode, always uses FakeIO for deterministic simulation.
/// In production, selects io_uring (Linux) or kqueue (macOS).
// Inspired by: Ghostty (refs/ghostty/INSIGHTS.md) — comptime platform switch pattern
// Uses comptime if/switch instead of runtime tagged union for zero-cost backend selection.
pub fn IoBackend(comptime is_test: bool) type {
    if (is_test) {
        return fake_io.FakeIO;
    }
    return switch (builtin.os.tag) {
        .linux => io_uring.IoUring,
        .macos => kqueue.Kqueue,
        else => @compileError("unsupported platform: snek requires Linux (io_uring) or macOS (kqueue)"),
    };
}

/// The default production backend for the current platform.
pub const Backend = IoBackend(false);

/// The test/simulation backend (always FakeIO).
pub const TestBackend = IoBackend(true);

pub const IoOp = enum {
    read,
    write,
    accept,
    connect,
    close,
    send,
    recv,
    send_zc,
    timeout,
    cancel,
};

pub const CompletionEvent = struct {
    fd: i32,
    result: i32,
    user_data: u64,
    op: IoOp,
};

/// Uniform IO backend configuration. Each backend uses what it needs.
pub const IoConfig = struct {
    allocator: std.mem.Allocator = std.heap.smp_allocator,
    id: u64 = 0,
    ring_size: u32 = 256,
};

/// Verify that a type satisfies the IO interface at comptime.
/// All IO backends (FakeIO, IoUring) must implement these methods
/// with compatible signatures. This is the contract that enables
/// `Scheduler(comptime IO: type)` to work with any backend.
// Inspired by: TigerBeetle — comptime interface verification pattern
pub fn assertIsIoBackend(comptime IO: type) void {
    comptime {
        // Uniform init/deinit
        _ = @as(fn (IoConfig) anyerror!IO, IO.init);
        // Submit operations: each takes *IO, fd, relevant params, user_data
        _ = @as(fn (*IO, i32, []u8, u64, u64) anyerror!void, IO.submitRead);
        _ = @as(fn (*IO, i32, []const u8, u64, u64) anyerror!void, IO.submitWrite);
        _ = @as(fn (*IO, i32, u64) anyerror!void, IO.submitAccept);
        _ = @as(fn (*IO, i32, []const u8, u16, u64) anyerror!void, IO.submitConnect);
        _ = @as(fn (*IO, i32, u64) anyerror!void, IO.submitClose);
        _ = @as(fn (*IO, i32, []const u8, u64) anyerror!void, IO.submitSend);
        _ = @as(fn (*IO, i32, []u8, u64) anyerror!void, IO.submitRecv);
        _ = @as(fn (*IO, u64, u64) anyerror!void, IO.submitTimeout);
        _ = @as(fn (*IO, u64, u64) anyerror!void, IO.submitCancel);
        // Poll for completions
        _ = @as(fn (*IO, []fake_io.CompletionEntry) anyerror!u32, IO.pollCompletions);
    }
}

test "io backend comptime selection" {
    // Verify that IoBackend(true) always resolves to FakeIO.
    const TestIO = IoBackend(true);
    comptime {
        std.debug.assert(TestIO == fake_io.FakeIO);
    }
}

test "io backend platform selection" {
    // On macOS, production backend should be Kqueue
    if (builtin.os.tag == .macos) {
        comptime {
            std.debug.assert(Backend == kqueue.Kqueue);
        }
    }
    // On Linux, production backend should be IoUring
    if (builtin.os.tag == .linux) {
        comptime {
            std.debug.assert(Backend == io_uring.IoUring);
        }
    }
}

test "FakeIO satisfies IO interface" {
    // This is a comptime check — if it compiles, FakeIO has the right signatures.
    comptime {
        assertIsIoBackend(fake_io.FakeIO);
    }
}

test "io backend submit and poll" {
    const alloc = std.testing.allocator;
    var io = fake_io.FakeIO.init(.{ .allocator = alloc, .id = 42 });
    defer io.deinit();

    var buf: [64]u8 = undefined;
    io.submitRead(3, &buf, 0, 100) catch unreachable;
    io.submitWrite(3, "hello", 0, 101) catch unreachable;
    io.submitAccept(4, 102) catch unreachable;

    var events: [16]fake_io.CompletionEntry = undefined;
    const n = io.pollCompletions(&events) catch unreachable;
    // Should have completed the 3 submitted operations
    try std.testing.expect(n == 3);

    // Verify user_data is preserved
    var found_100 = false;
    var found_101 = false;
    var found_102 = false;
    for (events[0..n]) |e| {
        if (e.user_data == 100) found_100 = true;
        if (e.user_data == 101) found_101 = true;
        if (e.user_data == 102) found_102 = true;
    }
    try std.testing.expect(found_100);
    try std.testing.expect(found_101);
    try std.testing.expect(found_102);
}

test "edge: assertIsIoBackend catches missing methods" {
    // We can't test comptime errors at runtime, but we CAN verify the mechanism
    // by confirming that a struct missing a method would fail the @as coercion.
    // This test documents the contract. If someone removes a method from FakeIO,
    // the "FakeIO satisfies IO interface" test above will fail to compile.
    //
    // Verify the positive case works at comptime:
    comptime {
        assertIsIoBackend(fake_io.FakeIO);
    }
    // The negative case (struct missing submitRead) can't be tested without
    // causing a compile error, which is the intended behavior.
}

test "io backend cancel" {
    const alloc = std.testing.allocator;
    var io = fake_io.FakeIO.init(.{ .allocator = alloc, .id = 99 });
    defer io.deinit();

    // Submit a timeout, then cancel it
    io.submitTimeout(1_000_000_000, 200) catch unreachable;
    io.submitCancel(200, 201) catch unreachable;

    var events: [16]fake_io.CompletionEntry = undefined;
    const n = io.pollCompletions(&events) catch unreachable;
    // Should get completion for the cancel op; the timeout should be removed
    try std.testing.expect(n >= 1);

    // The cancel completion should be present
    var found_cancel = false;
    for (events[0..n]) |e| {
        if (e.user_data == 201) {
            found_cancel = true;
            try std.testing.expect(e.result == 0); // cancel succeeded
        }
    }
    try std.testing.expect(found_cancel);
}
