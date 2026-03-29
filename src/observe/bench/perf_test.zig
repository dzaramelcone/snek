const std = @import("std");
const perf = @import("perf.zig");

fn doWork(n: u64) u64 {
    var sum: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        sum +%= i *% i;
    }
    return sum;
}

pub fn main() !void {
    const events = &[_]perf.Event{ .cpu_cycles, .instructions, .cache_misses, .branch_misses };
    var group = perf.Group(events).init() catch |err| {
        std.debug.print("perf init failed: {s}\n", .{@errorName(err)});
        std.debug.print("(need: perf_event_paranoid <= 1, or run as root)\n", .{});
        return;
    };
    defer group.deinit();

    try group.enable();
    const result1 = doWork(100_000);
    std.mem.doNotOptimizeAway(result1);
    try group.disable();
    const r1 = try group.read();

    try group.enable();
    const result2 = doWork(1_000_000);
    std.mem.doNotOptimizeAway(result2);
    try group.disable();
    const r2 = try group.read();

    std.debug.print("\n=== 100K iterations ===\n", .{});
    std.debug.print("  cycles:       {d}\n", .{r1.cpu_cycles});
    std.debug.print("  instructions: {d}\n", .{r1.instructions});
    std.debug.print("  cache_misses: {d}\n", .{r1.cache_misses});
    std.debug.print("  branch_miss:  {d}\n", .{r1.branch_misses});
    std.debug.print("  IPC:          {d}.{d:0>2}\n", .{ r1.instructions / (r1.cpu_cycles | 1), (r1.instructions * 100 / (r1.cpu_cycles | 1)) % 100 });

    std.debug.print("\n=== 1M iterations ===\n", .{});
    std.debug.print("  cycles:       {d}\n", .{r2.cpu_cycles});
    std.debug.print("  instructions: {d}\n", .{r2.instructions});
    std.debug.print("  cache_misses: {d}\n", .{r2.cache_misses});
    std.debug.print("  branch_miss:  {d}\n", .{r2.branch_misses});
    std.debug.print("  IPC:          {d}.{d:0>2}\n", .{ r2.instructions / (r2.cpu_cycles | 1), (r2.instructions * 100 / (r2.cpu_cycles | 1)) % 100 });

    std.debug.print("\n10x more work → {d}.{d:0>1}x more cycles\n", .{
        r2.cpu_cycles / (r1.cpu_cycles | 1),
        (r2.cpu_cycles * 10 / (r1.cpu_cycles | 1)) % 10,
    });
}
