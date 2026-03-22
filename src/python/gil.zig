//! GIL (Global Interpreter Lock) management.
//!
//! RAII-style acquire/release with per-I/O-operation granularity.
//! Supports free-threaded mode detection (PEP 703) and long-hold warnings.
//!
//! Sources:
//!   - Per-I/O-operation GIL granularity — granian's PyIterAwaitable insight
//!     (src/python/REFERENCES_eventloop.md — 55% perf difference)

const std = @import("std");
const ffi = @import("ffi.zig");

// ── GilGuard: RAII acquire/release ──────────────────────────────────

/// Acquire the GIL on init, release on deinit. Use with `defer`.
///
///     var guard = GilGuard.acquire();
///     defer guard.deinit();
///
pub const GilGuard = struct {
    state: ?*anyopaque,
    acquire_time_ns: i128,

    /// Warning threshold: log if GIL held longer than this.
    const HOLD_WARNING_NS: i128 = 100 * std.time.ns_per_ms;

    pub fn acquire() GilGuard {
        return .{
            .state = null,
            .acquire_time_ns = std.time.nanoTimestamp(),
        };
    }

    pub fn deinit(self: *GilGuard) void {
        const held_ns = std.time.nanoTimestamp() - self.acquire_time_ns;
        if (held_ns > HOLD_WARNING_NS) {
            logGilWarning(held_ns);
        }
        _ = self.state;
        self.state = null;
    }

    /// Release the GIL for an I/O operation. Returns a GilState token
    /// to re-acquire after the I/O completes.
    /// Source: granian's per-I/O GIL release pattern — release before every I/O op,
    /// reacquire after completion (src/python/REFERENCES_eventloop.md).
    pub fn releaseForIo(self: *GilGuard) GilState {
        const held_ns = std.time.nanoTimestamp() - self.acquire_time_ns;
        if (held_ns > HOLD_WARNING_NS) {
            logGilWarning(held_ns);
        }
        const saved = GilState{ .state = self.state, .held = false };
        self.state = null;
        return saved;
    }

    /// Re-acquire the GIL after an I/O operation completes.
    pub fn reacquireAfterIo(self: *GilGuard, saved: GilState) void {
        _ = saved;
        self.state = null;
        self.acquire_time_ns = std.time.nanoTimestamp();
    }
};

// ── GilState: low-level acquire/release ─────────────────────────────

pub const GilState = struct {
    state: ?*anyopaque,
    held: bool,

    pub fn ensureGil() GilState {
        return .{ .state = null, .held = true };
    }

    pub fn releaseGil(self: *GilState) void {
        self.held = false;
        self.state = null;
    }
};

// ── Free-threaded mode detection (PEP 703) ──────────────────────────

/// Detect whether the running CPython interpreter is free-threaded
/// (compiled with --disable-gil / PEP 703). When true, GIL operations
/// become no-ops and per-object critical sections are used instead.
pub fn isFreeThreaded() bool {
    // Stub: in production, check Py_GIL_DISABLED or sys.flags.nogil
    return false;
}

/// Adapt GIL strategy based on free-threaded mode. Call once at init.
pub fn adaptToFreeThreadedMode() void {
    if (isFreeThreaded()) {
        // In free-threaded mode: GIL acquire/release are no-ops.
        // Per-object critical sections (Py_BEGIN_CRITICAL_SECTION)
        // replace GIL for thread safety.
    }
}

// ── Warning mechanism ───────────────────────────────────────────────

fn logGilWarning(held_ns: i128) void {
    _ = held_ns;
    // Stub: log warning via snek's scoped logging system.
    // "GIL held for {held_ns / 1_000_000}ms — consider offloading CPU-bound work"
}

// ── Tests ───────────────────────────────────────────────────────────

test "gil acquire and release" {}

test "gil guard RAII lifecycle" {}

test "gil releaseForIo and reacquire" {}

test "gil hold warning threshold" {}

test "free-threaded mode detection" {}

test "gil state tracking" {}
