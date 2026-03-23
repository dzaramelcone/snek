# Scheduler/Worker Benchmark and Verification Plan

Date: 2026-03-22

Companion docs:

- [`scheduler_worker_gap_audit.md`](./scheduler_worker_gap_audit.md)
- [`scheduler_worker_gap_audit_status.md`](./scheduler_worker_gap_audit_status.md)
- [`zap_comparison.md`](./zap_comparison.md)

## Goal

Optimize the scheduler and worker runtime for throughput, tail latency, and resource efficiency without losing correctness.

Simplicity is not a goal by itself. Simplicity only matters when it:

- improves measured performance,
- improves correctness confidence,
- reduces tuning/debugging cost enough to matter operationally.

## Decision Rule

Use two different standards:

1. **Must prove**
   Safety and lifecycle properties that cannot be left to benchmarking.

2. **Must measure**
   Policy and heuristic choices whose value is empirical.

Do not try to use formal methods to settle questions that are fundamentally performance questions.
Do not use benchmarks to justify correctness assumptions.

## What Must Be Proved

The formal and test verification scope should stay focused on these properties:

1. No task is lost.
2. No task executes twice.
3. Accepted work is either completed or explicitly cancelled according to the contract.
4. Shutdown cannot free scheduler/worker state while worker threads still use it.
5. Wakeup protocol cannot strand runnable work indefinitely due to a missed wake.
6. Queue capacity and backpressure invariants hold.
7. Ownership of a task/frame is unambiguous at all times.

These are the properties that belong in TLA, deterministic simulation, and invariant-heavy tests.

## What Must Be Measured

The following are scheduler policy questions and should be benchmark-driven:

1. Queue topology.
   - pure bounded deque per worker
   - deque plus accept queue
   - zap-style bounded local buffer plus overflow queue

2. Steal strategy.
   - 3 victims vs all victims
   - deterministic scan vs randomized scan
   - single-item steal vs half-buffer steal

3. Wake strategy.
   - simple direct wake
   - spin-then-park
   - zap-style wake throttling with a waking thread

4. Thread policy.
   - eager start
   - lazy spawn
   - fixed worker count vs adaptive

5. Shutdown behavior under load.
   - strict drain-first
   - drain with timeouts
   - selective cancellation after deadline

## Scheduler Variants To Benchmark

Keep the comparison set small and purposeful.

### Variant A: Current snek baseline

- accept queue
- bounded per-worker Chase-Lev deque
- direct dispatch
- direct wake
- current 3-victim steal scan

Use this as the control.

### Variant B: Current baseline plus better instrumentation

Same algorithm as A, but with complete metrics:

- enqueue count
- completion count
- steal attempts
- steal successes
- wake count
- park count
- shutdown drain time

This should be the first step before any deeper scheduler changes.

### Variant C: zap-inspired hybrid

- bounded local buffer per worker
- overflow intrusive queue per worker
- optional global intrusive queue
- queue-first then buffer steal order
- batch stealing

Do not add wake throttling in the same step. Isolate the queue-topology effect first.

### Variant D: wake-throttled scheduler

Take the best of A or C and add:

- one-word sync state
- waking-thread throttling
- explicit notified bit

This isolates the wake policy effect from the queue topology effect.

### Variant E: simple mutex/reference scheduler

- one central mutex queue, or
- one per-worker mutex queue with no stealing

This is not for production. It is a correctness reference and a performance floor.

## Benchmark Suite

Use both microbenchmarks and macrobenchmarks. Neither is enough alone.

## 1. Microbenchmarks

These should run entirely inside `src/core` without Python or HTTP.

### 1.1 Empty/cheap task throughput

Measure:

- tasks/sec
- ns/task
- CPU usage

Workload:

- N tiny no-op tasks
- 1, 2, 4, 8, ... worker counts

Purpose:

- expose queue and wake overhead directly

### 1.2 Skewed workload stealing

Measure:

- makespan
- steal attempts
- steal successes
- fraction of work executed off-owner

Workload:

- all tasks injected into one worker
- mixed short and long task costs

Purpose:

- evaluate steal policy and victim selection

### 1.3 Burst enqueue latency

Measure:

- enqueue-to-start latency
- enqueue-to-complete latency
- p50/p95/p99/p99.9

Workload:

- large bursts followed by idle gaps

Purpose:

- expose wake path and backlog behavior

### 1.4 Saturation/backpressure

Measure:

- throughput at steady saturation
- queue depth over time
- failed enqueue/backpressure count
- scheduler main-loop CPU burn

Workload:

- producer rate above worker consumption rate

Purpose:

- compare accept-queue and worker-queue behavior under load

### 1.5 Park/wake overhead

Measure:

- time to resume parked worker
- park/wake count
- useful work after wake

Workload:

- sparse intermittent tasks

Purpose:

- compare direct wake vs throttled wake vs spin-then-park

### 1.6 Shutdown under load

Measure:

- time from shutdown signal to quiescence
- tasks completed after shutdown
- tasks cancelled after shutdown
- worker drain time

Workload:

- shutdown during active burst
- shutdown during saturation
- shutdown while workers are mostly idle

Purpose:

- validate drain policy cost and correctness envelope

## 2. Macrobenchmarks

These should resemble backend HTTP runtime behavior.

### 2.1 HTTP-shaped mixed workload

Task classes:

- 80% short request handlers
- 15% medium handlers
- 5% long handlers

Measure:

- requests/sec
- p50/p95/p99/p99.9 latency
- worker utilization
- scheduler overhead

### 2.2 Bursty traffic

Pattern:

- idle
- burst
- idle
- burst

Purpose:

- evaluate wake strategy and queue refill policy

### 2.3 Hot-key / imbalanced traffic

Pattern:

- many requests hash to same worker or same routing shard

Purpose:

- evaluate steal effectiveness under pathological skew

### 2.4 Long-tail handlers

Pattern:

- mostly short handlers plus rare long CPU-bound work

Purpose:

- measure fairness and tail amplification

### 2.5 Graceful shutdown scenario

Pattern:

- sustained traffic
- trigger shutdown
- observe accepted vs rejected vs completed work

Purpose:

- confirm operational contract, not just throughput

## Metrics To Add Before Serious Benchmarking

The scheduler runtime should expose at least:

1. tasks enqueued
2. tasks dispatched
3. tasks started
4. tasks completed
5. tasks cancelled
6. steal attempts
7. steal successes
8. worker parks
9. worker wakes
10. backpressure events
11. accept queue depth high-water mark
12. per-worker deque depth high-water mark
13. shutdown start timestamp
14. shutdown completed timestamp

Without this, benchmark results will be hard to interpret.

## Benchmark Methodology

Use a fixed methodology or the comparisons will be noisy.

1. Run on both macOS and Linux.
   Linux matters most for production-style runtime conclusions.

2. Record hardware and kernel.
   Include core count, SMT on/off, CPU model, kernel version.

3. Pin worker count explicitly.
   Do not auto-detect during benchmark comparisons.

4. Warm up before sampling.
   At least one untimed warmup run.

5. Run multiple repetitions.
   Minimum 10 per scenario.

6. Report distributions, not just means.
   Means hide tail-latency regressions.

7. Keep benchmark harness deterministic where possible.
   Especially for skewed-workload and shutdown tests.

8. Version-lock benchmark inputs.
   Same task count, same worker count, same seed.

## Verification Plan

## 1. Formal Verification

Keep the TLA scope narrow and honest.

### scheduler.tla should remain authoritative for:

- task ownership
- queue movement
- wake semantics
- shutdown drain semantics

### worker_lifecycle.tla should either:

- be reconciled with `scheduler.tla`, or
- be archived as a historical narrow race proof

Do not maintain two partially-overlapping sources of truth indefinitely.

### Formal properties to keep checking

1. single ownership
2. no double execution
3. bounded queues
4. no work before the allowed lifecycle state
5. parked worker eventually wakes when signaled
6. draining shutdown eventually reaches done

### Formal properties to avoid over-modeling

Do not try to model:

- exact victim order
- exact wake-throttling heuristic
- exact spin count
- exact thread spawn heuristics

Those should be abstracted unless they directly affect correctness.

## 2. Reference Implementation / Differential Testing

Build a simple reference scheduler with obviously-correct behavior:

- single mutex queue, or
- per-worker mutex queue without stealing

Use it only for:

- small-state deterministic runs
- comparison against production scheduler outputs

Check:

- same completed task set
- same cancellation behavior
- same shutdown outcome

This is the fastest way to catch “clever scheduler” regressions.

## 3. Deterministic Simulation

Use `FakeIO` and synthetic tasks to run deterministic scheduler scenarios.

Add tests for:

1. duplicate enqueue rejection or detection
2. cancellation before dispatch
3. cancellation after dispatch but before execution
4. shutdown during saturation
5. shutdown while stealing is in progress
6. pre-start buffering if retained as a design choice

## 4. Fuzzing / Randomized Stress

Add randomized stress harnesses that vary:

- task count
- enqueue timing
- worker count
- shutdown timing
- cancellation timing
- task cost distribution

Assertions:

- no hangs
- no loss
- no duplicates
- no use-after-free

## 5. Performance-Gated Correctness

For every scheduler variant that enters benchmark comparison:

1. pass TLA model checks
2. pass deterministic stress suite
3. pass randomized stress suite
4. then run perf benchmarks

Do not benchmark variants that have not cleared correctness gates.

## Rollout Order

Follow this order to avoid combinatorial churn.

### Phase 1: Instrument current scheduler

- complete metrics
- benchmark harness
- baseline numbers

### Phase 2: Lock down correctness

- reconcile `worker_lifecycle.tla`
- add differential tests
- add deterministic and randomized shutdown tests

### Phase 3: Queue topology experiment

- implement zap-inspired hybrid queue variant
- benchmark against baseline

### Phase 4: Wake strategy experiment

- add wake-throttled variant
- benchmark against best queue topology

### Phase 5: Promote only if it wins

A variant should only replace the baseline if it provides:

- clear throughput gain, or
- clear tail-latency gain, or
- clear CPU-efficiency gain

without weakening:

- correctness guarantees
- shutdown contract
- debuggability

## Promotion Criteria

Suggested bar for adopting a new scheduler variant:

1. at least 10-15% throughput win on at least one representative macrobenchmark, or
2. at least 15-20% p99 improvement on at least one representative macrobenchmark, or
3. at least 10% CPU reduction at equal throughput

and:

4. no correctness regressions
5. no materially worse shutdown behavior
6. no severe tail regressions in other benchmark classes

If the gains are smaller than that, keep the simpler/firmer design.

## Practical Recommendation

The immediate next step should be:

1. finish runtime metrics,
2. build the benchmark harness around the current scheduler,
3. record a baseline,
4. implement one zap-inspired hybrid variant,
5. compare using the same workload matrix,
6. only then decide whether to change the queue topology or wake strategy.

This keeps the work falsifiable and prevents spending weeks “improving” a scheduler without evidence that it helps the backend framework where it matters.
