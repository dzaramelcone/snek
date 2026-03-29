const std = @import("std");
const apple_perf = @import("apple_perf.zig");

pub fn main() !void {
    var pe = apple_perf.PerfEvents.init() catch |err| {
        std.debug.print("PMU init failed: {s}\n", .{@errorName(err)});
        std.debug.print("(need sudo on macOS)\n", .{});
        return;
    };
    defer pe.deinit();

    // 100K iterations
    const before1 = try pe.read();
    var sum1: u64 = 0;
    for (0..100_000) |i| {
        sum1 +%= i *% i;
        std.mem.doNotOptimizeAway(&sum1);
    }
    const after1 = try pe.read();
    const d1 = apple_perf.Counters.diff(after1, before1);

    // 1M iterations
    const before2 = try pe.read();
    var sum2: u64 = 0;
    for (0..1_000_000) |i| {
        sum2 +%= i *% i;
        std.mem.doNotOptimizeAway(&sum2);
    }
    const after2 = try pe.read();
    const d2 = apple_perf.Counters.diff(after2, before2);

    std.debug.print("\n=== 100K iterations ===\n", .{});
    std.debug.print("  cycles:       {d}\n", .{d1.cycles});
    std.debug.print("  instructions: {d}\n", .{d1.instructions});
    std.debug.print("  branches:     {d}\n", .{d1.branches});
    std.debug.print("  branch_miss:  {d}\n", .{d1.missed_branches});
    std.debug.print("  L1D miss:     {d}\n", .{d1.cache_misses});
    std.debug.print("  TLB miss:     {d}\n", .{d1.tlb_misses});
    std.debug.print("  IPC:          {d}.{d:0>2}\n", .{ d1.instructions / (d1.cycles | 1), (d1.instructions * 100 / (d1.cycles | 1)) % 100 });

    std.debug.print("\n=== 1M iterations ===\n", .{});
    std.debug.print("  cycles:       {d}\n", .{d2.cycles});
    std.debug.print("  instructions: {d}\n", .{d2.instructions});
    std.debug.print("  branches:     {d}\n", .{d2.branches});
    std.debug.print("  branch_miss:  {d}\n", .{d2.missed_branches});
    std.debug.print("  L1D miss:     {d}\n", .{d2.cache_misses});
    std.debug.print("  TLB miss:     {d}\n", .{d2.tlb_misses});
    std.debug.print("  IPC:          {d}.{d:0>2}\n", .{ d2.instructions / (d2.cycles | 1), (d2.instructions * 100 / (d2.cycles | 1)) % 100 });

    std.debug.print("\n10x more work -> {d}.{d:0>1}x more cycles\n", .{
        d2.cycles / (d1.cycles | 1),
        (d2.cycles * 10 / (d1.cycles | 1)) % 10,
    });
}
