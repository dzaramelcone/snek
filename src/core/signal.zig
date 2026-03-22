//! Unix signal handling for graceful shutdown.
//! Handles SIGTERM, SIGINT, SIGHUP for shutdown and cert reload.
//! Ignores SIGPIPE (Ghostty pattern — broken client connections).
//!
//! 8-step graceful shutdown protocol (from design.md):
//!   1. Signal received (SIGTERM/SIGINT)
//!   2. Stop accepting new connections (close listen fd)
//!   3. Set shutdown flag on all workers
//!   4. Wait for in-flight requests to complete (with timeout)
//!   5. Cancel remaining coroutines
//!   6. Close all client connections
//!   7. Drain worker deques
//!   8. Exit process

const std = @import("std");

pub const Signal = enum {
    sigterm,
    sigint,
    sighup,
    sigpipe,
};

pub const ShutdownPhase = enum {
    running,
    stop_accepting,
    draining,
    cancelling,
    closing_connections,
    draining_deques,
    cleanup,
    exit,
};

pub const SignalCallback = *const fn (signal: Signal) void;

pub const SignalHandler = struct {
    registered: bool,
    shutdown_phase: ShutdownPhase,

    pub fn init() SignalHandler {
        return .{
            .registered = false,
            .shutdown_phase = .running,
        };
    }

    pub fn deinit(self: *SignalHandler) void {
        _ = .{self};
    }

    pub fn onSignal(self: *SignalHandler, signal: Signal, callback: SignalCallback) !void {
        _ = .{ self, signal, callback };
    }

    /// Ignore SIGPIPE at startup (essential for handling broken client connections).
    // Inspired by: Ghostty (refs/ghostty/INSIGHTS.md) — SIGPIPE ignore pattern
    pub fn ignoreSigpipe(self: *SignalHandler) !void {
        _ = .{self};
    }

    /// Get the current shutdown phase.
    pub fn getPhase(self: *const SignalHandler) ShutdownPhase {
        return self.shutdown_phase;
    }

    /// Advance to the next shutdown phase.
    pub fn advancePhase(self: *SignalHandler) void {
        _ = .{self};
    }

    /// Execute the full 8-step graceful shutdown sequence.
    /// Per-phase timeouts come from scheduler.ShutdownConfig:
    ///   http_drain_timeout_ms, ws_drain_timeout_ms, task_drain_timeout_ms,
    ///   force_shutdown_timeout_ms.
    // See: design.md §15.1 — 8-step graceful shutdown protocol
    pub fn executeGracefulShutdown(self: *SignalHandler, shutdown_config: @import("scheduler.zig").ShutdownConfig) !void {
        _ = .{ self, shutdown_config };
    }
};

test "register signal handler" {}

test "graceful shutdown on SIGTERM" {}

test "ignore SIGPIPE" {}

test "shutdown phase progression" {}
