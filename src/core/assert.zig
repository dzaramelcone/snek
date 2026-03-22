//! Inline assert that avoids the overhead of std.debug.assert in ReleaseFast.
//! Ghostty found std.debug.assert has 15-20% overhead in hot paths because
//! it is not always inlined. This module provides an always-inline variant.
//!
//! Usage: `assert.check(condition)` in hot paths (HTTP parsing, routing, scheduling).
//! In Debug mode, delegates to std.debug.assert for full diagnostics.
//! In Release modes, compiles to `if (!ok) unreachable;` which the optimizer removes
//! entirely in ReleaseFast and traps in ReleaseSafe.

const std = @import("std");
const builtin = @import("builtin");

/// Always-inline assert for hot paths. Zero overhead in ReleaseFast.
/// Traps in ReleaseSafe. Full diagnostics in Debug.
// Inspired by: Ghostty (refs/ghostty/INSIGHTS.md) — std.debug.assert 15-20% overhead finding
// Ghostty discovered std.debug.assert is not always inlined, causing measurable overhead in hot paths.
pub const check = switch (builtin.mode) {
    .Debug => std.debug.assert,
    .ReleaseSmall, .ReleaseSafe, .ReleaseFast => struct {
        inline fn assert(ok: bool) void {
            if (!ok) unreachable;
        }
    }.assert,
};

/// Assert with a message for cold paths. Not performance-critical.
/// Always uses std.debug.assert behavior.
pub const checkMsg = std.debug.assert;

test "inline assert passes on true" {
    check(true);
}

test "inline assert compiles in all modes" {
    check(1 + 1 == 2);
}
