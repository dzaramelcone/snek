const std = @import("std");
const driver = @import("../python/driver.zig");
const perf = @import("../observe/perf.zig");

const log = std.log.scoped(.@"snek/pipeline");

pub const Stats = struct {
    cycles: u64 = 0,
    completions: u64 = 0,
    http_requests: u64 = 0,
    ns_io: u64 = 0,
    ns_classify: u64 = 0,
    ns_parse: u64 = 0,
    ns_handle_prep: u64 = 0,
    ns_handle_py: u64 = 0,
    ns_py_call: u64 = 0,
    ns_py_lookup: u64 = 0,
    ns_py_arg_build: u64 = 0,
    ns_py_resume: u64 = 0,
    ns_py_yield_consume: u64 = 0,
    ns_py_request_obj: u64 = 0,
    ns_py_invoke_total: u64 = 0,
    ns_py_result: u64 = 0,
    ns_py_result_response: u64 = 0,
    ns_py_result_yield: u64 = 0,
    py_no_args: u64 = 0,
    py_params_only: u64 = 0,
    py_request: u64 = 0,
    py_invocations: u64 = 0,
    py_coroutines: u64 = 0,
    py_sync_responses: u64 = 0,
    py_async_immediate_returns: u64 = 0,
    py_redis_yields: u64 = 0,
    py_pg_yields: u64 = 0,
    ns_redis: u64 = 0,
    ns_pg_wire: u64 = 0,
    ns_pg_flush: u64 = 0,
    pg_rows: u64 = 0,
    ns_send: u64 = 0,
    pg_recv_ops: u64 = 0,
    pg_recv_bytes: u64 = 0,
    /// CQE batch size histogram: <32, 32-63, 64-127, 128-255, 256-511, 512+
    cqe_batch_hist: [6]u64 = .{0} ** 6,
    pmu: if (has_pmu) PmuState else void = if (has_pmu) .{} else {},

    pub const has_pmu = perf.Backend != void;

    const PmuState = struct {
        backend: ?perf.Backend = null,
        cpu_cycles: u64 = 0,
        instructions: u64 = 0,
        branches: u64 = 0,
        branch_misses: u64 = 0,
        cache_misses: u64 = 0,
        tlb_misses: u64 = 0,
    };

    pub fn initPmu(self: *Stats) void {
        if (comptime !has_pmu) return;
        if (perf.Backend.init()) |pe| {
            self.pmu.backend = pe;
            log.info("PMU counters enabled", .{});
        } else |err| {
            log.info("PMU unavailable: {s}", .{@errorName(err)});
        }
    }

    pub fn deinitPmu(self: *Stats) void {
        if (comptime !has_pmu) return;
        if (self.pmu.backend) |*p| perf.deinit(p);
    }

    pub fn pmuRead(self: *Stats) if (has_pmu) ?perf.Counters else void {
        if (comptime !has_pmu) return {};
        if (self.pmu.backend) |*p| return perf.read(p);
        return null;
    }

    pub fn pmuAccum(self: *Stats, before: anytype, after: anytype) void {
        if (comptime !has_pmu) return;
        const b = before orelse return;
        const a = after orelse return;
        const d = perf.Counters.diff(a, b);
        self.pmu.cpu_cycles += d.cycles;
        self.pmu.instructions += d.instructions;
        self.pmu.branches += d.branches;
        self.pmu.branch_misses += d.missed_branches;
        self.pmu.cache_misses += d.cache_misses;
        self.pmu.tlb_misses += d.tlb_misses;
    }

    pub fn recordBatchSize(self: *Stats, n: usize) void {
        const bucket: usize = if (n < 32) 0 else if (n < 64) 1 else if (n < 128) 2 else if (n < 256) 3 else if (n < 512) 4 else 5;
        self.cqe_batch_hist[bucket] += 1;
    }

    pub fn accumInvokeMetrics(self: *Stats, metrics: *const driver.InvokeMetrics) void {
        self.py_invocations += metrics.invocations;
        self.py_coroutines += metrics.coroutines;
        self.py_sync_responses += metrics.sync_responses;
        self.py_async_immediate_returns += metrics.async_immediate_returns;
        self.py_redis_yields += metrics.redis_yields;
        self.py_pg_yields += metrics.pg_yields;
        self.ns_py_lookup += metrics.ns_lookup;
        self.ns_py_arg_build += metrics.ns_arg_build;
        self.ns_py_call += metrics.ns_call;
        self.ns_py_resume += metrics.ns_resume;
        self.ns_py_yield_consume += metrics.ns_yield_consume;
    }

    pub fn resetWindow(self: *Stats) void {
        self.completions = 0;
        self.http_requests = 0;
        self.ns_io = 0;
        self.ns_classify = 0;
        self.ns_parse = 0;
        self.ns_handle_prep = 0;
        self.ns_handle_py = 0;
        self.ns_py_call = 0;
        self.ns_py_lookup = 0;
        self.ns_py_arg_build = 0;
        self.ns_py_resume = 0;
        self.ns_py_yield_consume = 0;
        self.ns_py_request_obj = 0;
        self.ns_py_invoke_total = 0;
        self.ns_py_result = 0;
        self.ns_py_result_response = 0;
        self.ns_py_result_yield = 0;
        self.py_no_args = 0;
        self.py_params_only = 0;
        self.py_request = 0;
        self.py_invocations = 0;
        self.py_coroutines = 0;
        self.py_sync_responses = 0;
        self.py_async_immediate_returns = 0;
        self.py_redis_yields = 0;
        self.py_pg_yields = 0;
        self.ns_redis = 0;
        self.ns_pg_wire = 0;
        self.ns_pg_flush = 0;
        self.pg_rows = 0;
        self.ns_send = 0;
        self.pg_recv_ops = 0;
        self.pg_recv_bytes = 0;
        self.cqe_batch_hist = .{0} ** 6;
    }

    pub fn dump(self: *Stats) void {
        const ns_handle = self.ns_handle_prep + self.ns_handle_py;
        const total = self.ns_io + self.ns_classify + self.ns_parse + ns_handle + self.ns_redis + self.ns_pg_wire + self.ns_pg_flush + self.ns_send;
        const cqes = self.completions;
        const us = struct {
            fn f(ns: u64) u64 {
                return ns / 1000;
            }
        }.f;
        log.info(
            "PROFILE  cycles={d}  cqes={d}  http={d}  total={d}us  io={d}us  classify={d}us  parse={d}us  handle={d}us(prep={d} py={d})  redis={d}us  pg={d}us({d}rows)  pg_flush={d}us  send={d}us  pg_recv={d}/{d}B",
            .{
                self.cycles,
                cqes,
                self.http_requests,
                us(total),
                us(self.ns_io),
                us(self.ns_classify),
                us(self.ns_parse),
                us(ns_handle),
                us(self.ns_handle_prep),
                us(self.ns_handle_py),
                us(self.ns_redis),
                us(self.ns_pg_wire),
                self.pg_rows,
                us(self.ns_pg_flush),
                us(self.ns_send),
                self.pg_recv_ops,
                self.pg_recv_bytes,
            },
        );
        log.info(
            "BATCH_HIST  <32={d}  32-63={d}  64-127={d}  128-255={d}  256-511={d}  512+={d}",
            .{
                self.cqe_batch_hist[0],
                self.cqe_batch_hist[1],
                self.cqe_batch_hist[2],
                self.cqe_batch_hist[3],
                self.cqe_batch_hist[4],
                self.cqe_batch_hist[5],
            },
        );
        if (self.py_invocations > 0) {
            const invoke_known = self.ns_py_lookup + self.ns_py_arg_build + self.ns_py_call + self.ns_py_resume + self.ns_py_yield_consume;
            const invoke_other = self.ns_py_invoke_total -| invoke_known;
            self.dumpPyProfile(invoke_other, us);
        }
        if (comptime has_pmu) {
            if (self.pmu.cpu_cycles > 0) {
                log.info(
                    "PMU  cycles={d}  insn={d}  IPC={d}.{d:0>2}  branches={d}  mispredict={d}  L1miss={d}  TLBmiss={d}",
                    .{
                        self.pmu.cpu_cycles,
                        self.pmu.instructions,
                        self.pmu.instructions / (self.pmu.cpu_cycles | 1),
                        (self.pmu.instructions * 100 / (self.pmu.cpu_cycles | 1)) % 100,
                        self.pmu.branches,
                        self.pmu.branch_misses,
                        self.pmu.cache_misses,
                        self.pmu.tlb_misses,
                    },
                );
            }
            self.pmu = .{ .backend = self.pmu.backend };
        }
        self.resetWindow();
    }

    fn dumpPyProfile(self: *Stats, invoke_other: u64, us: fn (u64) u64) void {
        log.info(
            "PYPROFILE  invocations={d}  coro={d}  noargs={d}  params={d}  request={d}  sync={d}  async_return={d}  yield_redis={d}  yield_pg={d}",
            .{
                self.py_invocations,
                self.py_coroutines,
                self.py_no_args,
                self.py_params_only,
                self.py_request,
                self.py_sync_responses,
                self.py_async_immediate_returns,
                self.py_redis_yields,
                self.py_pg_yields,
            },
        );
        log.info(
            "PYPROFILE  reqobj={d}us  invoke={d}us(other={d}us)  result={d}us(resp={d}us yield={d}us)  lookup={d}us  args={d}us  call={d}us  resume={d}us  yield_consume={d}us",
            .{
                us(self.ns_py_request_obj),
                us(self.ns_py_invoke_total),
                us(invoke_other),
                us(self.ns_py_result),
                us(self.ns_py_result_response),
                us(self.ns_py_result_yield),
                us(self.ns_py_lookup),
                us(self.ns_py_arg_build),
                us(self.ns_py_call),
                us(self.ns_py_resume),
                us(self.ns_py_yield_consume),
            },
        );
    }
};
