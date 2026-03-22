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
const c = ffi.c;

// PyEval_SaveThread/RestoreThread return/accept *PyThreadState, but
// PyThreadState contains an opaque sub-struct that @cImport can't embed.
// Use extern declarations with *anyopaque instead.
pub extern fn PyEval_SaveThread() ?*anyopaque;
pub extern fn PyEval_RestoreThread(?*anyopaque) void;

// ── GIL state type from CPython ─────────────────────────────────────

pub const GilStateEnum = c.PyGILState_STATE;

// ── GilGuard: RAII acquire/release ──────────────────────────────────

/// Acquire the GIL on init, release on deinit. Use with `defer`.
///
///     var guard = GilGuard.acquire();
///     defer guard.release();
///
pub const GilGuard = struct {
    state: GilStateEnum,
    acquire_time_ns: i128,

    /// Warning threshold: log if GIL held longer than 100ms.
    const HOLD_WARNING_NS: i128 = 100 * std.time.ns_per_ms;

    /// Acquire the GIL. Must be paired with release().
    pub fn acquire() GilGuard {
        return .{
            .state = c.PyGILState_Ensure(),
            .acquire_time_ns = std.time.nanoTimestamp(),
        };
    }

    /// Release the GIL. Logs a warning if held longer than 100ms.
    pub fn release(self: *GilGuard) void {
        const held_ns = std.time.nanoTimestamp() - self.acquire_time_ns;
        if (held_ns > HOLD_WARNING_NS) {
            logGilWarning(held_ns);
        }
        c.PyGILState_Release(self.state);
    }

    /// Release the GIL temporarily for an I/O operation.
    /// Returns a SavedGil token to re-acquire after I/O completes.
    ///
    /// Source: granian's per-I/O GIL release pattern — release before every
    /// I/O op, reacquire after completion (src/python/REFERENCES_eventloop.md).
    pub fn releaseForIo(self: *GilGuard) SavedGil {
        const held_ns = std.time.nanoTimestamp() - self.acquire_time_ns;
        if (held_ns > HOLD_WARNING_NS) {
            logGilWarning(held_ns);
        }
        const saved = PyEval_SaveThread();
        return .{
            .thread_state = saved,
            .guard = self,
        };
    }
};

/// Token for re-acquiring the GIL after an I/O operation.
pub const SavedGil = struct {
    thread_state: ?*anyopaque,
    guard: *GilGuard,

    /// Re-acquire the GIL after I/O completes.
    pub fn reacquire(self: *SavedGil) void {
        PyEval_RestoreThread(self.thread_state);
        self.guard.acquire_time_ns = std.time.nanoTimestamp();
    }
};

// ── Standalone GIL acquire/release ──────────────────────────────────

/// Low-level GIL ensure — for use outside GilGuard.
pub fn ensure() GilStateEnum {
    return c.PyGILState_Ensure();
}

/// Low-level GIL release — for use outside GilGuard.
pub fn gilRelease(state: GilStateEnum) void {
    c.PyGILState_Release(state);
}

// ── Free-threaded mode detection (PEP 703) ──────────────────────────

/// Detect whether the running CPython interpreter is free-threaded
/// (compiled with --disable-gil / PEP 703). When true, GIL operations
/// become effectively no-ops.
pub fn isFreeThreaded() bool {
    // Check Py_GIL_DISABLED at runtime via sys.flags if available.
    // For Python < 3.13 this is always false.
    const sys = ffi.importModule("sys") catch return false;
    defer ffi.decref(sys);
    const flags = ffi.getAttr(sys, "flags") catch return false;
    defer ffi.decref(flags);
    // In free-threaded builds, sys.flags has a 'nogil' attribute set to True.
    // If the attribute doesn't exist, we're on a standard build.
    _ = ffi.getAttr(flags, "nogil") catch return false;
    return true;
}

// ── Warning mechanism ───────────────────────────────────────────────

fn logGilWarning(held_ns: i128) void {
    const held_ms = @divTrunc(held_ns, std.time.ns_per_ms);
    std.log.warn("GIL held for {d}ms — consider offloading CPU-bound work", .{held_ms});
}

// ── Tests ───────────────────────────────────────────────────────────

test "gil ensure and release" {
    ffi.init();
    defer ffi.deinit();

    const state = ensure();
    gilRelease(state);
}

test "gil guard RAII lifecycle" {
    ffi.init();
    defer ffi.deinit();

    var guard = GilGuard.acquire();
    // Do some Python work under the GIL
    try ffi.runString("x = 42");
    guard.release();
}

test "gil guard with defer" {
    ffi.init();
    defer ffi.deinit();

    {
        var guard = GilGuard.acquire();
        defer guard.release();
        try ffi.runString("y = 100");
    }
    // GIL released here by defer
}

test "gil releaseForIo and reacquire" {
    ffi.init();
    defer ffi.deinit();

    var guard = GilGuard.acquire();
    defer guard.release();

    // Release GIL for simulated I/O
    var saved = guard.releaseForIo();
    // ... I/O would happen here ...
    saved.reacquire();

    // Verify Python still works after reacquire
    try ffi.runString("io_test = True");
}

test "gil hold warning threshold" {
    // Verify the constant is set correctly (100ms)
    std.testing.expectEqual(
        @as(i128, 100 * std.time.ns_per_ms),
        GilGuard.HOLD_WARNING_NS,
    ) catch unreachable;
}

test "free-threaded mode detection" {
    ffi.init();
    defer ffi.deinit();

    // On standard CPython 3.14, this should be false
    // (unless built with --disable-gil)
    const ft = isFreeThreaded();
    _ = ft; // We just verify it doesn't crash
}

test "gil state multiple cycles" {
    ffi.init();
    defer ffi.deinit();

    // Multiple acquire/release cycles
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const state = ensure();
        gilRelease(state);
    }
}
