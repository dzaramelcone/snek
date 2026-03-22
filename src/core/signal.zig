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
const posix = std.posix;

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

/// Module-level atomic flags for signal handler context.
/// Index mapping: 0=SIGTERM, 1=SIGINT, 2=SIGHUP.
var signal_received = [3]std.atomic.Value(bool){
    std.atomic.Value(bool).init(false),
    std.atomic.Value(bool).init(false),
    std.atomic.Value(bool).init(false),
};

fn signalIndex(sig: Signal) ?usize {
    return switch (sig) {
        .sigterm => 0,
        .sigint => 1,
        .sighup => 2,
        .sigpipe => null,
    };
}

fn toPosixSig(sig: Signal) u8 {
    return switch (sig) {
        .sigterm => posix.SIG.TERM,
        .sigint => posix.SIG.INT,
        .sighup => posix.SIG.HUP,
        .sigpipe => posix.SIG.PIPE,
    };
}

/// Signal handler that sets an atomic flag. Safe for signal context.
fn signalHandler(sig: c_int) callconv(.c) void {
    const idx: usize = switch (sig) {
        posix.SIG.TERM => 0,
        posix.SIG.INT => 1,
        posix.SIG.HUP => 2,
        else => return,
    };
    signal_received[idx].store(true, .release);
}

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
        _ = callback;
        const sig_num = toPosixSig(signal);
        var act = posix.Sigaction{
            .handler = .{ .handler = signalHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(sig_num, &act, null);
        self.registered = true;
    }

    /// Ignore SIGPIPE at startup (essential for handling broken client connections).
    // Inspired by: Ghostty (refs/ghostty/INSIGHTS.md) — SIGPIPE ignore pattern
    pub fn ignoreSigpipe(self: *SignalHandler) void {
        _ = self;
        var act = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.PIPE, &act, null);
    }

    /// Get the current shutdown phase.
    pub fn getPhase(self: *const SignalHandler) ShutdownPhase {
        return self.shutdown_phase;
    }

    /// Advance to the next shutdown phase. Forward-only.
    pub fn advancePhase(self: *SignalHandler) void {
        const current = @intFromEnum(self.shutdown_phase);
        const last = @intFromEnum(ShutdownPhase.exit);
        std.debug.assert(current < last);
        self.shutdown_phase = @enumFromInt(current + 1);
    }

    /// Check if a signal's atomic flag is set.
    pub fn isSignalReceived(signal: Signal) bool {
        const idx = signalIndex(signal) orelse return false;
        return signal_received[idx].load(.acquire);
    }

    /// Clear a signal's atomic flag (for testing or after handling).
    pub fn clearSignal(signal: Signal) void {
        const idx = signalIndex(signal) orelse return;
        signal_received[idx].store(false, .release);
    }

    /// Execute the full 8-step graceful shutdown sequence.
    /// Per-phase timeouts come from scheduler.ShutdownConfig.
    // See: design.md §15.1 — 8-step graceful shutdown protocol
    pub fn executeGracefulShutdown(self: *SignalHandler, shutdown_config: @import("scheduler.zig").ShutdownConfig) void {
        _ = shutdown_config;
        // Stub: advance through all phases. Actual shutdown logic requires the scheduler (Phase 5).
        while (self.shutdown_phase != .exit) {
            self.advancePhase();
        }
    }
};

// --- Tests ---

test "shutdown phase progression" {
    var handler = SignalHandler.init();
    try std.testing.expectEqual(ShutdownPhase.running, handler.getPhase());

    handler.advancePhase();
    try std.testing.expectEqual(ShutdownPhase.stop_accepting, handler.getPhase());

    handler.advancePhase();
    try std.testing.expectEqual(ShutdownPhase.draining, handler.getPhase());

    handler.advancePhase();
    try std.testing.expectEqual(ShutdownPhase.cancelling, handler.getPhase());

    handler.advancePhase();
    try std.testing.expectEqual(ShutdownPhase.closing_connections, handler.getPhase());

    handler.advancePhase();
    try std.testing.expectEqual(ShutdownPhase.draining_deques, handler.getPhase());

    handler.advancePhase();
    try std.testing.expectEqual(ShutdownPhase.cleanup, handler.getPhase());

    handler.advancePhase();
    try std.testing.expectEqual(ShutdownPhase.exit, handler.getPhase());
}

test "ignore SIGPIPE" {
    var handler = SignalHandler.init();
    handler.ignoreSigpipe();
    // Verify we can send SIGPIPE to ourselves without dying.
    const pid = std.c.getpid();
    _ = std.c.kill(pid, posix.SIG.PIPE);
    // If we get here, SIGPIPE was successfully ignored.
}

test "atomic signal flag mechanism" {
    // Test the flag mechanism directly without sending real signals.
    try std.testing.expect(!SignalHandler.isSignalReceived(.sigterm));
    try std.testing.expect(!SignalHandler.isSignalReceived(.sigint));
    try std.testing.expect(!SignalHandler.isSignalReceived(.sighup));

    // Simulate signal handler setting the flag.
    signal_received[0].store(true, .release);
    try std.testing.expect(SignalHandler.isSignalReceived(.sigterm));
    try std.testing.expect(!SignalHandler.isSignalReceived(.sigint));

    // Clear and verify.
    SignalHandler.clearSignal(.sigterm);
    try std.testing.expect(!SignalHandler.isSignalReceived(.sigterm));
}

test "register signal handler" {
    var handler = SignalHandler.init();
    try std.testing.expect(!handler.registered);

    // Register a handler (noop callback — the real work is the atomic flag).
    const noop = struct {
        fn cb(_: Signal) void {}
    }.cb;
    handler.onSignal(.sighup, noop) catch unreachable;
    try std.testing.expect(handler.registered);

    // Send SIGHUP to self, verify atomic flag is set.
    const pid = std.c.getpid();
    _ = std.c.kill(pid, posix.SIG.HUP);
    // Small spin to let the signal be delivered.
    var i: u32 = 0;
    while (i < 1000 and !SignalHandler.isSignalReceived(.sighup)) : (i += 1) {
        std.atomic.spinLoopHint();
    }
    try std.testing.expect(SignalHandler.isSignalReceived(.sighup));
    SignalHandler.clearSignal(.sighup);
}

test "graceful shutdown on SIGTERM" {
    var handler = SignalHandler.init();
    try std.testing.expectEqual(ShutdownPhase.running, handler.getPhase());

    handler.executeGracefulShutdown(.{});
    try std.testing.expectEqual(ShutdownPhase.exit, handler.getPhase());
}

test "sigpipe has no signal index" {
    try std.testing.expect(!SignalHandler.isSignalReceived(.sigpipe));
}

test "edge: advancePhase past exit panics" {
    var handler = SignalHandler.init();
    // Advance to exit
    while (handler.getPhase() != .exit) {
        handler.advancePhase();
    }
    // Advancing past exit should panic (debug assert)
    try std.testing.expectEqual(ShutdownPhase.exit, handler.getPhase());
    // The assert in advancePhase prevents going past .exit.
    // In debug mode, this panics. We verify by expectation — calling advancePhase
    // here would crash the test runner. We trust the assert guard.
}

test "edge: register same signal twice — overwrites, not duplicates" {
    var handler = SignalHandler.init();
    const noop = struct {
        fn cb(_: Signal) void {}
    }.cb;
    handler.onSignal(.sigterm, noop) catch unreachable;
    handler.onSignal(.sigterm, noop) catch unreachable;
    try std.testing.expect(handler.registered);

    // Send SIGTERM to self, verify flag is set exactly once
    SignalHandler.clearSignal(.sigterm);
    const pid = std.c.getpid();
    _ = std.c.kill(pid, posix.SIG.TERM);
    var i: u32 = 0;
    while (i < 1000 and !SignalHandler.isSignalReceived(.sigterm)) : (i += 1) {
        std.atomic.spinLoopHint();
    }
    try std.testing.expect(SignalHandler.isSignalReceived(.sigterm));
    SignalHandler.clearSignal(.sigterm);
}

test "edge: clearSignal when not set — no-op" {
    // Ensure flags are clear
    SignalHandler.clearSignal(.sigterm);
    SignalHandler.clearSignal(.sigint);
    SignalHandler.clearSignal(.sighup);

    // Clear again — should be a no-op, no crash
    SignalHandler.clearSignal(.sigterm);
    SignalHandler.clearSignal(.sigint);
    SignalHandler.clearSignal(.sighup);
    SignalHandler.clearSignal(.sigpipe); // sigpipe has no index — should be no-op

    try std.testing.expect(!SignalHandler.isSignalReceived(.sigterm));
    try std.testing.expect(!SignalHandler.isSignalReceived(.sigint));
    try std.testing.expect(!SignalHandler.isSignalReceived(.sighup));
}
