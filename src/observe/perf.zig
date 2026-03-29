//! Unified hardware performance counter interface.
//!
//! Comptime-selects the platform backend:
//!   - macOS aarch64: Apple kpc (private kperf framework)
//!   - Linux: perf_event_open syscall
//!   - Other: unsupported (init returns null)

const builtin = @import("builtin");

pub const Counters = @import("apple_perf.zig").Counters;

pub const Backend = if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)
    @import("apple_perf.zig").PerfEvents
else if (builtin.os.tag == .linux)
    @import("linux_perf.zig").PerfEvents
else
    void;

/// Try to initialize hardware performance counters.
/// Returns null if unsupported or insufficient privileges — not an error.
pub fn init() ?Backend {
    if (Backend == void) return null;
    return Backend.init() catch null;
}

pub fn deinit(pe: *Backend) void {
    pe.deinit();
}

pub fn read(pe: *Backend) ?Counters {
    return pe.read() catch null;
}
