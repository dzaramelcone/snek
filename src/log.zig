//! Custom log function for snek.
//!
//! Format: [timestamp] [t:thread_id] [loop:N] [LEVEL] scope | message
//! debug level is stripped in ReleaseFast (zero cost).
//!
//! The loop counter tracks event loop iterations (reap cycles).
//! Call bumpLoop() from the reap point to increment it.

const std = @import("std");

threadlocal var loop_count: u64 = 0;

pub fn bumpLoop() void {
    loop_count += 1;
}

pub fn getLoopCount() u64 {
    return loop_count;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const scope_name = if (@tagName(scope).len > 0) @tagName(scope) else "default";
    const level_name = comptime switch (level) {
        .debug => "DBG",
        .info => "INF",
        .warn => "WRN",
        .err => "ERR",
    };

    const ts = std.time.milliTimestamp();
    const tid = std.Thread.getCurrentId();
    const lc = loop_count;

    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d}] [t:{d}] [loop:{d}] [{s}] {s} | " ++ fmt ++ "\n", .{ ts, tid, lc, level_name, scope_name } ++ args) catch return;
    const stderr = std.fs.File.stderr();
    stderr.writeAll(line) catch return;
}
