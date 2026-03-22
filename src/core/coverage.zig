//! Coverage marks for test-to-code traceability (TigerBeetle pattern).
//! Production code calls `mark()` at interesting code paths.
//! Tests call `check()` to assert those paths were exercised.
//!
//! In non-test builds, marks compile to no-ops (zero overhead).
//! In test builds, marks set a thread-local flag that tests can query.

const std = @import("std");
const builtin = @import("builtin");

/// Maximum number of distinct coverage marks. Increase if needed.
const max_marks: usize = 256;

/// Mark storage — only exists in test builds.
var hit_flags: if (builtin.is_test) [max_marks]bool else void =
    if (builtin.is_test) [_]bool{false} ** max_marks else {};

/// Mark a code path. In non-test builds, compiles to nothing.
/// The `id` must be a comptime-known string that maps to a stable index.
// Inspired by: TigerBeetle (refs/tigerbeetle/INSIGHTS.md) — coverage marks for test-to-code traceability
// Production code marks interesting paths; tests assert those paths were exercised. Zero-cost in non-test builds.
pub inline fn mark(comptime name: []const u8) void {
    if (builtin.is_test) {
        const index = comptimeIndex(name);
        hit_flags[index] = true;
    }
}

/// Check that a coverage mark was hit. Returns a checker with `.expectHit()`.
/// Only meaningful in test builds.
pub inline fn check(comptime name: []const u8) Checker {
    return .{ .index = comptimeIndex(name) };
}

pub const Checker = struct {
    index: usize,

    /// Assert that the mark was hit since the last reset.
    pub fn expectHit(self: Checker) !void {
        if (builtin.is_test) {
            if (!hit_flags[self.index]) {
                return error.CoverageMarkNotHit;
            }
        }
    }

    /// Assert that the mark was NOT hit since the last reset.
    pub fn expectNotHit(self: Checker) !void {
        if (builtin.is_test) {
            if (hit_flags[self.index]) {
                return error.CoverageMarkUnexpectedlyHit;
            }
        }
    }
};

/// Reset all marks. Call at the start of each test.
pub fn reset() void {
    if (builtin.is_test) {
        @memset(&hit_flags, false);
    }
}

/// Comptime hash of mark name to a stable index.
fn comptimeIndex(comptime name: []const u8) comptime_int {
    comptime {
        var hash: usize = 5381;
        for (name) |c| {
            hash = ((hash << 5) +% hash) +% c;
        }
        return hash % max_marks;
    }
}

test "mark and check" {
    reset();
    mark("test_path");
    try check("test_path").expectHit();
}

test "unmarked path" {
    reset();
    try check("never_hit_path").expectNotHit();
}
