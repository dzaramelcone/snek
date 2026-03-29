//! Apple ARM performance counter instrumentation via kperf/kperfdata private frameworks.
//!
//! Ported from simdjson's apple_arm_events.h (public domain, by YaoYuan <ibireme@gmail.com>).
//!
//! Requires root privileges (or a "blessed" process) on aarch64-macos.
//! On other targets, init() returns error.UnsupportedPlatform.

const std = @import("std");
const builtin = @import("builtin");

pub const Counters = struct {
    cycles: u64,
    instructions: u64,
    branches: u64,
    missed_branches: u64,

    pub fn diff(after: Counters, before: Counters) Counters {
        return .{
            .cycles = after.cycles -| before.cycles,
            .instructions = after.instructions -| before.instructions,
            .branches = after.branches -| before.branches,
            .missed_branches = after.missed_branches -| before.missed_branches,
        };
    }
};

// ---------------------------------------------------------------------------
// KPC constants
// ---------------------------------------------------------------------------

const KPC_CLASS_FIXED: u32 = 0;
const KPC_CLASS_CONFIGURABLE: u32 = 1;

const KPC_CLASS_FIXED_MASK: u32 = 1 << KPC_CLASS_FIXED; // 1
const KPC_CLASS_CONFIGURABLE_MASK: u32 = 1 << KPC_CLASS_CONFIGURABLE; // 2

const KPC_MAX_COUNTERS: usize = 32;

// ---------------------------------------------------------------------------
// Event name tables (aliases for Apple / Intel PMC names)
// ---------------------------------------------------------------------------

const EVENT_NAME_MAX = 8;

const EventAlias = struct {
    alias: []const u8,
    names: [EVENT_NAME_MAX]?[*:0]const u8,
};

const profile_events = [4]EventAlias{
    .{
        .alias = "cycles",
        .names = .{
            "FIXED_CYCLES",
            "CPU_CLK_UNHALTED.THREAD",
            "CPU_CLK_UNHALTED.CORE",
            null, null, null, null, null,
        },
    },
    .{
        .alias = "instructions",
        .names = .{
            "FIXED_INSTRUCTIONS",
            "INST_RETIRED.ANY",
            null, null, null, null, null, null,
        },
    },
    .{
        .alias = "branches",
        .names = .{
            "INST_BRANCH",
            "BR_INST_RETIRED.ALL_BRANCHES",
            "INST_RETIRED.ANY",
            null, null, null, null, null,
        },
    },
    .{
        .alias = "branch-misses",
        .names = .{
            "BRANCH_MISPRED_NONSPEC",
            "BRANCH_MISPREDICT",
            "BR_MISP_RETIRED.ALL_BRANCHES",
            "BR_INST_RETIRED.MISPRED",
            null, null, null, null,
        },
    },
};

// ---------------------------------------------------------------------------
// C function pointer types for kperf / kperfdata
// ---------------------------------------------------------------------------

const KpcConfigT = u64;

// kperf function pointer types
const KpcForceAllCtrsSetFn = *const fn (c_int) callconv(.c) c_int;
const KpcForceAllCtrsGetFn = *const fn (*c_int) callconv(.c) c_int;
const KpcSetCountingFn = *const fn (u32) callconv(.c) c_int;
const KpcSetThreadCountingFn = *const fn (u32) callconv(.c) c_int;
const KpcSetConfigFn = *const fn (u32, [*]KpcConfigT) callconv(.c) c_int;
const KpcGetThreadCountersFn = *const fn (u32, u32, [*]u64) callconv(.c) c_int;

// kperfdata function pointer types
const KpepDbCreateFn = *const fn (?[*:0]const u8, *?*anyopaque) callconv(.c) c_int;
const KpepDbFreeFn = *const fn (?*anyopaque) callconv(.c) void;
const KpepDbEventFn = *const fn (?*anyopaque, [*:0]const u8, *?*anyopaque) callconv(.c) c_int;
const KpepConfigCreateFn = *const fn (?*anyopaque, *?*anyopaque) callconv(.c) c_int;
const KpepConfigFreeFn = *const fn (?*anyopaque) callconv(.c) void;
const KpepConfigAddEventFn = *const fn (?*anyopaque, *?*anyopaque, u32, ?*u32) callconv(.c) c_int;
const KpepConfigForceCountersFn = *const fn (?*anyopaque) callconv(.c) c_int;
const KpepConfigKpcClassesFn = *const fn (?*anyopaque, *u32) callconv(.c) c_int;
const KpepConfigKpcCountFn = *const fn (?*anyopaque, *usize) callconv(.c) c_int;
const KpepConfigKpcMapFn = *const fn (?*anyopaque, [*]usize, usize) callconv(.c) c_int;
const KpepConfigKpcFn = *const fn (?*anyopaque, [*]KpcConfigT, usize) callconv(.c) c_int;

// ---------------------------------------------------------------------------
// Resolved function pointers (stored in PerfEvents)
// ---------------------------------------------------------------------------

const KperfFns = struct {
    kpc_force_all_ctrs_set: KpcForceAllCtrsSetFn,
    kpc_force_all_ctrs_get: KpcForceAllCtrsGetFn,
    kpc_set_counting: KpcSetCountingFn,
    kpc_set_thread_counting: KpcSetThreadCountingFn,
    kpc_set_config: KpcSetConfigFn,
    kpc_get_thread_counters: KpcGetThreadCountersFn,
};

const KperfdataFns = struct {
    kpep_db_create: KpepDbCreateFn,
    kpep_db_free: KpepDbFreeFn,
    kpep_db_event: KpepDbEventFn,
    kpep_config_create: KpepConfigCreateFn,
    kpep_config_free: KpepConfigFreeFn,
    kpep_config_add_event: KpepConfigAddEventFn,
    kpep_config_force_counters: KpepConfigForceCountersFn,
    kpep_config_kpc_classes: KpepConfigKpcClassesFn,
    kpep_config_kpc_count: KpepConfigKpcCountFn,
    kpep_config_kpc_map: KpepConfigKpcMapFn,
    kpep_config_kpc: KpepConfigKpcFn,
};

// ---------------------------------------------------------------------------
// dlopen / dlsym helpers
// ---------------------------------------------------------------------------

const DlHandle = *anyopaque;

fn dlopen_checked(path: [*:0]const u8) error{DlopenFailed}!DlHandle {
    const handle = std.c.dlopen(path, .{ .LAZY = true });
    if (handle) |h| return h;
    return error.DlopenFailed;
}

fn dlsym_checked(comptime T: type, handle: DlHandle, name: [*:0]const u8) error{DlsymFailed}!T {
    const raw = std.c.dlsym(handle, name);
    if (raw) |ptr| return @ptrCast(@alignCast(ptr));
    return error.DlsymFailed;
}

fn load_kperf_fns(handle: DlHandle) error{DlsymFailed}!KperfFns {
    return .{
        .kpc_force_all_ctrs_set = try dlsym_checked(KpcForceAllCtrsSetFn, handle, "kpc_force_all_ctrs_set"),
        .kpc_force_all_ctrs_get = try dlsym_checked(KpcForceAllCtrsGetFn, handle, "kpc_force_all_ctrs_get"),
        .kpc_set_counting = try dlsym_checked(KpcSetCountingFn, handle, "kpc_set_counting"),
        .kpc_set_thread_counting = try dlsym_checked(KpcSetThreadCountingFn, handle, "kpc_set_thread_counting"),
        .kpc_set_config = try dlsym_checked(KpcSetConfigFn, handle, "kpc_set_config"),
        .kpc_get_thread_counters = try dlsym_checked(KpcGetThreadCountersFn, handle, "kpc_get_thread_counters"),
    };
}

fn load_kperfdata_fns(handle: DlHandle) error{DlsymFailed}!KperfdataFns {
    return .{
        .kpep_db_create = try dlsym_checked(KpepDbCreateFn, handle, "kpep_db_create"),
        .kpep_db_free = try dlsym_checked(KpepDbFreeFn, handle, "kpep_db_free"),
        .kpep_db_event = try dlsym_checked(KpepDbEventFn, handle, "kpep_db_event"),
        .kpep_config_create = try dlsym_checked(KpepConfigCreateFn, handle, "kpep_config_create"),
        .kpep_config_free = try dlsym_checked(KpepConfigFreeFn, handle, "kpep_config_free"),
        .kpep_config_add_event = try dlsym_checked(KpepConfigAddEventFn, handle, "kpep_config_add_event"),
        .kpep_config_force_counters = try dlsym_checked(KpepConfigForceCountersFn, handle, "kpep_config_force_counters"),
        .kpep_config_kpc_classes = try dlsym_checked(KpepConfigKpcClassesFn, handle, "kpep_config_kpc_classes"),
        .kpep_config_kpc_count = try dlsym_checked(KpepConfigKpcCountFn, handle, "kpep_config_kpc_count"),
        .kpep_config_kpc_map = try dlsym_checked(KpepConfigKpcMapFn, handle, "kpep_config_kpc_map"),
        .kpep_config_kpc = try dlsym_checked(KpepConfigKpcFn, handle, "kpep_config_kpc"),
    };
}

// ---------------------------------------------------------------------------
// PerfEvents — public API
// ---------------------------------------------------------------------------

pub const PerfEvents = struct {
    kperf: KperfFns,
    kperfdata: KperfdataFns,
    handle_kperf: DlHandle,
    handle_kperfdata: DlHandle,
    counter_map: [KPC_MAX_COUNTERS]usize,
    classes: u32,

    pub const InitError = error{
        UnsupportedPlatform,
        DlopenFailed,
        DlsymFailed,
        KpcPermissionDenied,
        KpepDbCreateFailed,
        KpepConfigCreateFailed,
        KpepConfigForceCountersFailed,
        EventNotFound,
        KpepConfigAddEventFailed,
        KpepConfigKpcClassesFailed,
        KpepConfigKpcCountFailed,
        KpepConfigKpcMapFailed,
        KpepConfigKpcFailed,
        KpcForceAllCtrsFailed,
        KpcSetConfigFailed,
        KpcSetCountingFailed,
        KpcSetThreadCountingFailed,
    };

    pub fn init() InitError!PerfEvents {
        if (comptime builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) {
            return error.UnsupportedPlatform;
        }

        // Load frameworks
        const handle_kperf = try dlopen_checked("/System/Library/PrivateFrameworks/kperf.framework/kperf");
        const handle_kperfdata = try dlopen_checked("/System/Library/PrivateFrameworks/kperfdata.framework/kperfdata");

        const kperf = try load_kperf_fns(handle_kperf);
        const kperfdata = try load_kperfdata_fns(handle_kperfdata);

        // Check permission
        var force_ctrs: c_int = 0;
        if (kperf.kpc_force_all_ctrs_get(&force_ctrs) != 0) {
            return error.KpcPermissionDenied;
        }

        // Load PMC database for current CPU
        var db: ?*anyopaque = null;
        if (kperfdata.kpep_db_create(null, &db) != 0) {
            return error.KpepDbCreateFailed;
        }

        // Create config
        var cfg: ?*anyopaque = null;
        if (kperfdata.kpep_config_create(db, &cfg) != 0) {
            kperfdata.kpep_db_free(db);
            return error.KpepConfigCreateFailed;
        }

        if (kperfdata.kpep_config_force_counters(cfg) != 0) {
            kperfdata.kpep_config_free(cfg);
            kperfdata.kpep_db_free(db);
            return error.KpepConfigForceCountersFailed;
        }

        // Resolve events from the database
        var ev_arr: [profile_events.len]?*anyopaque = .{null} ** profile_events.len;
        for (&profile_events, 0..) |*alias, i| {
            ev_arr[i] = find_event(kperfdata, db, alias) orelse {
                kperfdata.kpep_config_free(cfg);
                kperfdata.kpep_db_free(db);
                return error.EventNotFound;
            };
        }

        // Add events to config
        for (&ev_arr) |*ev_ptr| {
            if (kperfdata.kpep_config_add_event(cfg, ev_ptr, 0, null) != 0) {
                kperfdata.kpep_config_free(cfg);
                kperfdata.kpep_db_free(db);
                return error.KpepConfigAddEventFailed;
            }
        }

        // Extract KPC configuration
        var classes: u32 = 0;
        if (kperfdata.kpep_config_kpc_classes(cfg, &classes) != 0) {
            kperfdata.kpep_config_free(cfg);
            kperfdata.kpep_db_free(db);
            return error.KpepConfigKpcClassesFailed;
        }

        var reg_count: usize = 0;
        if (kperfdata.kpep_config_kpc_count(cfg, &reg_count) != 0) {
            kperfdata.kpep_config_free(cfg);
            kperfdata.kpep_db_free(db);
            return error.KpepConfigKpcCountFailed;
        }

        var counter_map: [KPC_MAX_COUNTERS]usize = .{0} ** KPC_MAX_COUNTERS;
        if (kperfdata.kpep_config_kpc_map(cfg, &counter_map, @sizeOf([KPC_MAX_COUNTERS]usize)) != 0) {
            kperfdata.kpep_config_free(cfg);
            kperfdata.kpep_db_free(db);
            return error.KpepConfigKpcMapFailed;
        }

        var regs: [KPC_MAX_COUNTERS]KpcConfigT = .{0} ** KPC_MAX_COUNTERS;
        if (kperfdata.kpep_config_kpc(cfg, &regs, @sizeOf([KPC_MAX_COUNTERS]KpcConfigT)) != 0) {
            kperfdata.kpep_config_free(cfg);
            kperfdata.kpep_db_free(db);
            return error.KpepConfigKpcFailed;
        }

        // Free config and db — we have what we need
        kperfdata.kpep_config_free(cfg);
        kperfdata.kpep_db_free(db);

        // Apply config to kernel
        if (kperf.kpc_force_all_ctrs_set(1) != 0) {
            return error.KpcForceAllCtrsFailed;
        }

        if ((classes & KPC_CLASS_CONFIGURABLE_MASK) != 0 and reg_count > 0) {
            if (kperf.kpc_set_config(classes, &regs) != 0) {
                return error.KpcSetConfigFailed;
            }
        }

        // Start counting
        if (kperf.kpc_set_counting(classes) != 0) {
            return error.KpcSetCountingFailed;
        }
        if (kperf.kpc_set_thread_counting(classes) != 0) {
            return error.KpcSetThreadCountingFailed;
        }

        return .{
            .kperf = kperf,
            .kperfdata = kperfdata,
            .handle_kperf = handle_kperf,
            .handle_kperfdata = handle_kperfdata,
            .counter_map = counter_map,
            .classes = classes,
        };
    }

    pub fn deinit(self: *PerfEvents) void {
        // Stop counting (best-effort, ignore errors during teardown)
        _ = self.kperf.kpc_set_counting(0);
        _ = self.kperf.kpc_set_thread_counting(0);
        _ = self.kperf.kpc_force_all_ctrs_set(0);

        _ = std.c.dlclose(self.handle_kperfdata);
        _ = std.c.dlclose(self.handle_kperf);
        self.* = undefined;
    }

    /// Read the current thread's performance counters (snapshot).
    pub fn start(self: *PerfEvents) error{ReadCountersFailed}!Counters {
        return self.read();
    }

    /// Read the current thread's performance counters.
    pub fn read(self: *PerfEvents) error{ReadCountersFailed}!Counters {
        var counters: [KPC_MAX_COUNTERS]u64 = .{0} ** KPC_MAX_COUNTERS;
        if (self.kperf.kpc_get_thread_counters(0, KPC_MAX_COUNTERS, &counters) != 0) {
            return error.ReadCountersFailed;
        }
        // Map order matches profile_events: [0]=cycles, [1]=instructions, [2]=branches, [3]=branch-misses
        return .{
            .cycles = counters[self.counter_map[0]],
            .instructions = counters[self.counter_map[1]],
            .branches = counters[self.counter_map[2]],
            .missed_branches = counters[self.counter_map[3]],
        };
    }

    pub fn diff(after: Counters, before: Counters) Counters {
        return Counters.diff(after, before);
    }

    fn find_event(kperfdata: KperfdataFns, db: ?*anyopaque, alias: *const EventAlias) ?*anyopaque {
        for (alias.names) |maybe_name| {
            const name = maybe_name orelse break;
            var ev: ?*anyopaque = null;
            if (kperfdata.kpep_db_event(db, name, &ev) == 0) {
                return ev;
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "diff computes correctly" {
    const before = Counters{
        .cycles = 100,
        .instructions = 200,
        .branches = 50,
        .missed_branches = 5,
    };
    const after = Counters{
        .cycles = 350,
        .instructions = 600,
        .branches = 120,
        .missed_branches = 12,
    };
    const d = Counters.diff(after, before);
    try std.testing.expectEqual(@as(u64, 250), d.cycles);
    try std.testing.expectEqual(@as(u64, 400), d.instructions);
    try std.testing.expectEqual(@as(u64, 70), d.branches);
    try std.testing.expectEqual(@as(u64, 7), d.missed_branches);
}

test "diff saturates on underflow" {
    const before = Counters{ .cycles = 100, .instructions = 200, .branches = 50, .missed_branches = 5 };
    const after = Counters{ .cycles = 50, .instructions = 100, .branches = 20, .missed_branches = 2 };
    const d = Counters.diff(after, before);
    try std.testing.expectEqual(@as(u64, 0), d.cycles);
    try std.testing.expectEqual(@as(u64, 0), d.instructions);
    try std.testing.expectEqual(@as(u64, 0), d.branches);
    try std.testing.expectEqual(@as(u64, 0), d.missed_branches);
}

test "init on supported platform" {
    // This test will only meaningfully run on aarch64-macos with root.
    // On other platforms it verifies the comptime gate works.
    if (comptime builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) {
        // Verify we get the expected error on unsupported platforms.
        const result = PerfEvents.init();
        try std.testing.expectError(error.UnsupportedPlatform, result);
        return;
    }

    // On macOS aarch64: try to init. If we lack root, we expect a permission error.
    var pe = PerfEvents.init() catch |err| {
        // Permission or framework errors are acceptable in non-root test environments.
        switch (err) {
            error.KpcPermissionDenied,
            error.DlopenFailed,
            error.DlsymFailed,
            => return, // Skip — not an environment we can test in
            else => return err,
        }
    };
    defer pe.deinit();

    // Verify counters increase between reads
    const before = try pe.start();
    // Do some work to burn cycles
    var sum: u64 = 0;
    for (0..10_000) |i| {
        sum +%= i;
    }
    std.mem.doNotOptimizeAway(sum);
    const after = try pe.read();
    const d = Counters.diff(after, before);

    // Cycles and instructions should have increased
    try std.testing.expect(d.cycles > 0);
    try std.testing.expect(d.instructions > 0);
}
