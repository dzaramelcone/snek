const std = @import("std");
const serialize = @import("serialize");

const SAMPLES = 21; // odd for clean median
const ITERS_PER_SAMPLE = 100_000;

const Impl = struct {
    name: []const u8,
    func: *const fn ([]u8, []const u8) serialize.SerializeError!usize,
};

const impls = [_]Impl{
    .{ .name = "scalar", .func = serialize.writeJsonEscapedScalar },
    .{ .name = "speculative", .func = serialize.writeJsonEscapedSpeculative },
    .{ .name = "find-memcpy", .func = serialize.writeJsonEscaped },
};

fn lessThan(_: void, a: u64, b: u64) bool {
    return a < b;
}

fn runSuite(comptime label: []const u8, input: []const u8, output: []u8) void {
    // 1. Correctness gate: all implementations must produce identical output
    const ref_len = impls[0].func(output, input) catch {
        std.debug.print("  {s}: scalar FAILED\n", .{label});
        return;
    };
    var ref_copy: [65536]u8 = undefined;
    @memcpy(ref_copy[0..ref_len], output[0..ref_len]);

    for (impls[1..]) |impl| {
        const len = impl.func(output, input) catch {
            std.debug.print("  {s}: {s} FAILED (error)\n", .{ label, impl.name });
            return;
        };
        if (len != ref_len or !std.mem.eql(u8, output[0..len], ref_copy[0..ref_len])) {
            std.debug.print("  {s}: {s} MISMATCH (got {d} bytes, expected {d})\n", .{ label, impl.name, len, ref_len });
            return;
        }
    }

    // 2. Benchmark each implementation
    std.debug.print("  {s:<12} ({d}B → {d}B)\n", .{ label, input.len, ref_len });

    for (impls) |impl| {
        var samples: [SAMPLES]u64 = undefined;

        for (&samples) |*sample| {
            // Warmup (same buffer, primes cache)
            for (0..100) |_| {
                const len = impl.func(output, input) catch 0;
                std.mem.doNotOptimizeAway(len);
                std.mem.doNotOptimizeAway(&output);
            }

            var timer = std.time.Timer.start() catch return;
            for (0..ITERS_PER_SAMPLE) |_| {
                const len = impl.func(output, input) catch 0;
                std.mem.doNotOptimizeAway(len);
                std.mem.doNotOptimizeAway(&output);
            }
            sample.* = timer.read();
        }

        std.mem.sort(u64, &samples, {}, lessThan);

        const median_ns = samples[SAMPLES / 2];
        const p10_ns = samples[SAMPLES / 5]; // ~10th percentile
        const p90_ns = samples[SAMPLES - 1 - SAMPLES / 5]; // ~90th percentile
        const ns_per_op = @as(f64, @floatFromInt(median_ns)) / @as(f64, ITERS_PER_SAMPLE);
        const throughput_mbs = @as(f64, @floatFromInt(input.len)) * @as(f64, ITERS_PER_SAMPLE) /
            (@as(f64, @floatFromInt(median_ns)) / 1_000_000_000.0) / (1024.0 * 1024.0);
        const p10_op = @as(f64, @floatFromInt(p10_ns)) / @as(f64, ITERS_PER_SAMPLE);
        const p90_op = @as(f64, @floatFromInt(p90_ns)) / @as(f64, ITERS_PER_SAMPLE);

        std.debug.print("    {s:<14} {d:>7.1} ns/op  [{d:.1}–{d:.1}]  {d:>8.1} MB/s\n", .{
            impl.name,
            ns_per_op,
            p10_op,
            p90_op,
            throughput_mbs,
        });
    }
}

pub fn main() !void {
    var output: [65536]u8 = undefined;

    // 1. Clean ASCII
    const clean_short: []const u8 = "hello world";
    const clean_64: []const u8 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789  ";
    var clean_1k: [1024]u8 = undefined;
    @memset(&clean_1k, 'x');

    // 2. Mixed (~5% escapes)
    var mixed_64: [64]u8 = undefined;
    @memset(&mixed_64, 'a');
    mixed_64[12] = '"';
    mixed_64[31] = '\\';
    mixed_64[47] = '\n';
    var mixed_1k: [1024]u8 = undefined;
    @memset(&mixed_1k, 'z');
    for (0..1024) |i| {
        if (i % 20 == 0) mixed_1k[i] = '"';
        if (i % 20 == 10) mixed_1k[i] = '\n';
    }

    // 3. Worst case (every byte needs escaping)
    var worst_64: [64]u8 = undefined;
    @memset(&worst_64, '"');
    var worst_1k: [1024]u8 = undefined;
    @memset(&worst_1k, '\\');

    // 4. High bytes (>= 0x80)
    var high_64: [64]u8 = undefined;
    for (0..64) |i| high_64[i] = @intCast(0x80 + (i % 128));

    std.debug.print("\n=== JSON Escape Benchmark (vec_len={}, {d} samples × {d} iters) ===\n\n", .{
        serialize.vec_len, SAMPLES, ITERS_PER_SAMPLE,
    });

    std.debug.print("--- Clean ASCII (no escapes) ---\n", .{});
    runSuite("clean-11B", clean_short, output[0..]);
    runSuite("clean-64B", clean_64, output[0..]);
    runSuite("clean-1KB", clean_1k[0..], output[0..]);

    std.debug.print("\n--- Mixed (~5%% escapes) ---\n", .{});
    runSuite("mixed-64B", mixed_64[0..], output[0..]);
    runSuite("mixed-1KB", mixed_1k[0..], output[0..]);

    std.debug.print("\n--- Worst case (100%% escapes) ---\n", .{});
    runSuite("worst-64B", worst_64[0..], output[0..]);
    runSuite("worst-1KB", worst_1k[0..], output[0..]);

    std.debug.print("\n--- High bytes (>= 0x80, passthrough) ---\n", .{});
    runSuite("high-64B", high_64[0..], output[0..]);

    std.debug.print("\n", .{});
}
