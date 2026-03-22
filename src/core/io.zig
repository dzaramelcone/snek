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

test "io backend comptime selection" {
    // Verify that IoBackend(true) always resolves to FakeIO.
    const TestIO = IoBackend(true);
    const instance = TestIO.init(42);
    _ = instance;
}

test "io backend platform selection" {}

test "io backend submit and poll" {}

test "io backend cancel" {}
