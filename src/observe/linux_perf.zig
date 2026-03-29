//! Linux performance counter instrumentation via perf_event_open.
//!
//! Ported from simdjson's linux-perf-events.h.
//! Requires perf_event_paranoid <= 1 (or root).
//! On non-Linux targets, init() returns error.UnsupportedPlatform.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Counters = @import("apple_perf.zig").Counters;

// perf_event_attr constants
const PERF_TYPE_HARDWARE: u32 = 0;
const PERF_COUNT_HW_CPU_CYCLES: u64 = 0;
const PERF_COUNT_HW_INSTRUCTIONS: u64 = 1;
const PERF_COUNT_HW_CACHE_REFERENCES: u64 = 2;
const PERF_COUNT_HW_CACHE_MISSES: u64 = 3;
const PERF_COUNT_HW_BRANCH_INSTRUCTIONS: u64 = 4;
const PERF_COUNT_HW_BRANCH_MISSES: u64 = 5;

const PERF_FORMAT_GROUP: u64 = 1 << 3;
const PERF_FORMAT_ID: u64 = 1 << 6;

const PERF_EVENT_IOC_ENABLE: u32 = 0x2400;
const PERF_EVENT_IOC_DISABLE: u32 = 0x2401;
const PERF_EVENT_IOC_RESET: u32 = 0x2403;
const PERF_EVENT_IOC_ID: u32 = 0x2407;
const PERF_IOC_FLAG_GROUP: u32 = 1;

// Minimal perf_event_attr (only fields we use)
const PerfEventAttr = extern struct {
    type_: u32 = PERF_TYPE_HARDWARE,
    size: u32 = @sizeOf(PerfEventAttr),
    config: u64 = 0,
    sample_period: u64 = 0,
    sample_type: u64 = 0,
    read_format: u64 = PERF_FORMAT_GROUP | PERF_FORMAT_ID,
    flags: u64 = (1 << 0) | (1 << 5) | (1 << 6), // disabled | exclude_kernel | exclude_hv
    wakeup_events: u32 = 0,
    bp_type: u32 = 0,
    config1: u64 = 0,
    config2: u64 = 0,
    branch_sample_type: u64 = 0,
    sample_regs_user: u64 = 0,
    sample_stack_user: u32 = 0,
    clockid: i32 = 0,
    sample_regs_intr: u64 = 0,
    aux_watermark: u32 = 0,
    sample_max_stack: u16 = 0,
    __reserved_2: u16 = 0,
    aux_sample_size: u32 = 0,
    __reserved_3: u32 = 0,
    sig_data: u64 = 0,
    config3: u64 = 0,
};

const NUM_EVENTS = 6;
const events = [NUM_EVENTS]u64{
    PERF_COUNT_HW_CPU_CYCLES,
    PERF_COUNT_HW_INSTRUCTIONS,
    PERF_COUNT_HW_BRANCH_INSTRUCTIONS,
    PERF_COUNT_HW_BRANCH_MISSES,
    PERF_COUNT_HW_CACHE_MISSES,
    6, // PERF_COUNT_HW_BUS_CYCLES as TLB proxy (no direct HW TLB miss counter)
};

pub const PerfEvents = struct {
    group_fd: i32,
    ids: [NUM_EVENTS]u64,

    pub const InitError = error{
        UnsupportedPlatform,
        PerfEventOpenFailed,
        IoctlFailed,
    };

    pub fn init() InitError!PerfEvents {
        if (comptime builtin.os.tag != .linux)
            return error.UnsupportedPlatform;

        var group_fd: i32 = -1;
        var ids: [NUM_EVENTS]u64 = .{0} ** NUM_EVENTS;

        for (events, 0..) |config, i| {
            var attr = PerfEventAttr{};
            attr.config = config;

            const fd = perf_event_open(&attr, 0, -1, group_fd, 0);
            if (fd < 0) return error.PerfEventOpenFailed;

            if (ioctl_id(fd, &ids[i]) < 0) return error.IoctlFailed;

            if (group_fd == -1) group_fd = fd;
        }

        return .{ .group_fd = group_fd, .ids = ids };
    }

    pub fn deinit(self: *PerfEvents) void {
        if (comptime builtin.os.tag != .linux) return;
        posix.close(@intCast(self.group_fd));
        self.* = undefined;
    }

    pub fn read(self: *PerfEvents) error{ReadCountersFailed}!Counters {
        if (comptime builtin.os.tag != .linux) return error.ReadCountersFailed;
        _ = ioctl_group(self.group_fd, PERF_EVENT_IOC_DISABLE);

        // Read format: { nr, { value, id } * nr }
        var buf: [1 + NUM_EVENTS * 2]u64 = undefined;
        const n = posix.read(@intCast(self.group_fd), std.mem.asBytes(&buf)) catch return error.ReadCountersFailed;
        if (n == 0) return error.ReadCountersFailed;

        var result: [NUM_EVENTS]u64 = .{0} ** NUM_EVENTS;
        const nr: usize = @intCast(buf[0]);
        for (0..nr) |j| {
            const value = buf[1 + j * 2];
            const id = buf[1 + j * 2 + 1];
            for (0..NUM_EVENTS) |k| {
                if (self.ids[k] == id) {
                    result[k] = value;
                    break;
                }
            }
        }

        _ = ioctl_group(self.group_fd, PERF_EVENT_IOC_ENABLE);

        return .{
            .cycles = result[0],
            .instructions = result[1],
            .branches = result[2],
            .missed_branches = result[3],
            .cache_misses = result[4],
            .tlb_misses = result[5],
        };
    }

    fn perf_event_open(attr: *PerfEventAttr, pid: i32, cpu: i32, group_fd: i32, flags: u32) i32 {
        const rc = std.os.linux.syscall5(
            .perf_event_open,
            @intFromPtr(attr),
            @bitCast(@as(i64, pid)),
            @bitCast(@as(i64, cpu)),
            @bitCast(@as(i64, group_fd)),
            flags,
        );
        const signed: isize = @bitCast(rc);
        if (signed < 0) return -1;
        return @intCast(signed);
    }

    fn ioctl_id(fd: i32, id: *u64) i32 {
        const rc = std.os.linux.syscall3(
            .ioctl,
            @bitCast(@as(i64, fd)),
            PERF_EVENT_IOC_ID,
            @intFromPtr(id),
        );
        const signed: isize = @bitCast(rc);
        if (signed < 0) return -1;
        return @intCast(signed);
    }

    fn ioctl_group(fd: i32, request: u32) i32 {
        const rc = std.os.linux.syscall3(
            .ioctl,
            @bitCast(@as(i64, fd)),
            request,
            PERF_IOC_FLAG_GROUP,
        );
        const signed: isize = @bitCast(rc);
        if (signed < 0) return -1;
        return @intCast(signed);
    }
};
