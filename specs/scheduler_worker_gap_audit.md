# Scheduler/Worker Spec vs Implementation Gap Audit

Date: 2026-03-22

## Scope

Audited:

- [`specs/scheduler.tla`](./scheduler.tla)
- [`specs/scheduler.cfg`](./scheduler.cfg)
- [`specs/worker_lifecycle.tla`](./worker_lifecycle.tla)
- [`specs/worker_lifecycle.cfg`](./worker_lifecycle.cfg)
- [`src/core/scheduler.zig`](../src/core/scheduler.zig)
- [`src/core/worker.zig`](../src/core/worker.zig)
- [`src/core/deque.zig`](../src/core/deque.zig)
- [`src/core/coroutine.zig`](../src/core/coroutine.zig)
- [`src/core/signal.zig`](../src/core/signal.zig)

## Verification Run

- `scheduler.tla` model checks cleanly under [`scheduler.cfg`](./scheduler.cfg): 668,190 generated states, 155,243 distinct states, depth 29.
- `worker_lifecycle.tla` model checks cleanly under [`worker_lifecycle.cfg`](./worker_lifecycle.cfg): 441,761 generated states, 57,204 distinct states, depth 22.
- `zig test src/core/worker.zig` passes.
- `zig test src/core/scheduler.zig` currently fails in [`src/core/scheduler.zig#L432`](../src/core/scheduler.zig#L432) with `expected 5, found 4`.

## Findings

1. High: drain-first shutdown is specified but not implemented.
The spec requires shutdown to drain accepted work before join. [`scheduler.tla#L133`](./scheduler.tla#L133) moves into draining, [`scheduler.tla#L143`](./scheduler.tla#L143) only allows join after the accept queue is empty, all worker deques are empty, and all workers are terminated, and [`scheduler.tla#L244`](./scheduler.tla#L244) blocks worker exit while work remains elsewhere. The implementation only drains the accept queue in [`src/core/scheduler.zig#L139`](../src/core/scheduler.zig#L139), then calls [`src/core/worker.zig#L195`](../src/core/worker.zig#L195), which flips each worker’s `running` flag false and joins. The worker loop in [`src/core/worker.zig#L95`](../src/core/worker.zig#L95) exits on the next loop check instead of draining its local deque. This is already visible as a live failing test in [`src/core/scheduler.zig#L468`](../src/core/scheduler.zig#L468).

2. High: work stealing required by the scheduler spec is entirely absent in the runtime.
The authoritative scheduler spec models stealing in [`scheduler.tla#L188`](./scheduler.tla#L188) and bases steady-state progress on it in [`scheduler.tla#L405`](./scheduler.tla#L405). The implementation never calls `steal()` from [`src/core/deque.zig#L104`](../src/core/deque.zig#L104). The worker loop only does local pop or park in [`src/core/worker.zig#L95`](../src/core/worker.zig#L95), and the scheduler never records steal attempts or successes despite exposing those metrics in [`src/core/scheduler.zig#L17`](../src/core/scheduler.zig#L17). Today, the runtime is a per-worker local queue executor, not the modeled work-stealing scheduler.

3. High: the park path still has a lost-wake race against incoming work.
The scheduler spec’s park transition explicitly rechecks both `running` and the local deque after storing `park_state = 1` in [`scheduler.tla#L221`](./scheduler.tla#L221). The implementation only rechecks `running` in [`src/core/worker.zig#L77`](../src/core/worker.zig#L77). If a pusher runs between the worker’s failed `pop()` and the later `park_state.store(1)`, [`src/core/worker.zig#L214`](../src/core/worker.zig#L214) can push and wake, then the worker overwrites `park_state` back to `1` and sleeps despite a non-empty local deque. `worker_lifecycle.tla` is also too weak here: [`worker_lifecycle.tla#L108`](./worker_lifecycle.tla#L108) only rechecks `running`, not deque state, so the two specs are inconsistent with each other.

4. High: the implementation still has no real coroutine execution path.
The spec models `processing` and `completed` task states in [`scheduler.tla#L50`](./scheduler.tla#L50), [`scheduler.tla#L176`](./scheduler.tla#L176), and [`scheduler.tla#L387`](./scheduler.tla#L387). The implementation pushes raw frame pointers as `u64` in [`src/core/scheduler.zig#L109`](../src/core/scheduler.zig#L109) and the worker loop only invokes an optional callback in [`src/core/worker.zig#L97`](../src/core/worker.zig#L97). Workers default to `work_callback = null` in [`src/core/worker.zig#L52`](../src/core/worker.zig#L52), so in the default runtime path they simply consume queued items and do nothing with them. There is also no integration with [`CoroutineFrame.resume`](../src/core/coroutine.zig#L61) or [`CoroutineFrame.complete`](../src/core/coroutine.zig#L78). The current scheduler can move opaque work tokens around, but it does not implement the modeled task lifecycle.

5. High: single ownership and no-loss are modeled in the spec but not enforced in the code.
The spec makes single-location task ownership a checked invariant in [`scheduler.tla#L355`](./scheduler.tla#L355). The implementation has no corresponding ownership state. [`spawnCoroutine`](../src/core/scheduler.zig#L163) blindly enqueues the frame, and [`FrameQueue.push`](../src/core/coroutine.zig#L185) has no guard against inserting the same frame twice. Because the queue is intrusive, double-enqueueing the same frame can corrupt the list, violate uniqueness, or strand tasks. The same lack of ownership tracking applies after dispatch: worker deques store raw `u64` values and no runtime state records whether a frame is in the accept queue, in a worker deque, processing, or completed.

6. High: the frame lifetime contract is unsafe and undocumented.
The scheduler stores task pointers as integers with [`@intFromPtr`](../src/core/scheduler.zig#L110) and the tests validate the cast round-trip in [`src/core/scheduler.zig#L361`](../src/core/scheduler.zig#L361). There is no owning pool or pinning in the scheduler path even though [`CoroutinePool`](../src/core/coroutine.zig#L128) exists. `spawnCoroutine()` accepts arbitrary `*CoroutineFrame` in [`src/core/scheduler.zig#L163`](../src/core/scheduler.zig#L163), including stack frames. If the caller drops that frame before a worker touches it, the runtime will dereference a dangling pointer. The current API exposes asynchronous raw-pointer ownership without any contract or enforcement.

7. High: cancellation is exposed as API surface but is not implemented end-to-end.
[`cancelCoroutine`](../src/core/scheduler.zig#L174) only marks the frame cancelled and increments a metric. It does not remove the frame from the accept queue, remove it from any worker deque, or prevent a worker from executing it later. The worker path never checks `frame.state`, [`CoroutineFrame.isCancelled`](../src/core/coroutine.zig#L90), or the cancellation token before running user work. The only place cancellation is honored is inside [`CoroutineFrame.resume`](../src/core/coroutine.zig#L61), which the scheduler/worker path never calls.

8. High: startup and shutdown are still raceable across threads.
The scheduler comments explicitly say `running` may be written from a signal-handler thread in [`src/core/scheduler.zig#L55`](../src/core/scheduler.zig#L55). But `run()` sets `running = true` only after [`pool.start()`](../src/core/scheduler.zig#L130), while `shutdown()` can concurrently set `running = false` in [`src/core/scheduler.zig#L148`](../src/core/scheduler.zig#L148). A shutdown arriving during startup can be overwritten by the later `running.store(true)`. Separately, `shut_down` is a plain `bool` in [`src/core/scheduler.zig#L58`](../src/core/scheduler.zig#L58), so `shutdown()` and `spawnCoroutine()` can race on non-atomic state.

9. High: `WorkerPool.start()` is not failure-atomic.
The spec treats start as one atomic lifecycle step in [`worker_lifecycle.tla#L46`](./worker_lifecycle.tla#L46). The implementation sets `running = true` for every worker in [`src/core/worker.zig#L184`](../src/core/worker.zig#L184) and then spawns threads one by one in [`src/core/worker.zig#L187`](../src/core/worker.zig#L187). If one later `std.Thread.spawn` fails, already-started threads keep running, no rollback occurs, the pool state never becomes `.started`, and `deinit()` can free worker resources while threads are still live. This is a hard lifecycle violation.

10. High: the implementation deliberately allows pre-start work, but both specs forbid it.
[`scheduler.tla#L264`](./scheduler.tla#L264) only allows `NewTask` in `main_pc = "started"`, and [`worker_lifecycle.tla#L128`](./worker_lifecycle.tla#L128) only allows `WorkArrives` while `main_pc = "started"`. The implementation intentionally accepts work before `run()` in [`src/core/scheduler.zig#L160`](../src/core/scheduler.zig#L160), and the tests lock that in via [`src/core/scheduler.zig#L474`](../src/core/scheduler.zig#L474). Worker tests also push directly into worker deques before `start()` in [`src/core/worker.zig#L307`](../src/core/worker.zig#L307). Either the specs must be widened to model pre-start buffering, or the implementation and tests must be tightened to match the current TLA contracts.

11. Medium-high: the accept queue path is not thread-safe.
The spec models `NewTask` as an action on shared state and relies on checked invariants for boundedness and ownership. The implementation’s accept queue is an unsynchronized intrusive linked list in [`src/core/coroutine.zig#L172`](../src/core/coroutine.zig#L172). `spawnCoroutine()` mutates it in [`src/core/scheduler.zig#L169`](../src/core/scheduler.zig#L169) while `tick()` pops from it in [`src/core/scheduler.zig#L109`](../src/core/scheduler.zig#L109), with no lock or atomic protocol. The capacity check and enqueue are also not atomic. If more than one producer is ever allowed, the queue, its `len`, and the backpressure accounting become data-racy.

12. Medium-high: graceful shutdown control is mostly stubbed despite being part of the public surface.
`ShutdownConfig` exposes four timeout knobs in [`src/core/scheduler.zig#L28`](../src/core/scheduler.zig#L28), but none are used by the scheduler loop. [`gracefulShutdown`](../src/core/scheduler.zig#L156) is just `shutdown()`. [`signal.zig`](../src/core/signal.zig#L139) advertises the full 8-step shutdown protocol, but [`executeGracefulShutdown`](../src/core/signal.zig#L142) ignores the config and just advances enum phases. The control plane claims staged draining and cancellation behavior that the scheduler implementation does not perform.

13. Medium-high: the metrics surface is incomplete and currently misleading.
[`SchedulerMetrics`](../src/core/scheduler.zig#L17) exposes `coroutines_completed`, `steal_attempts`, and `steal_successes`, but none are ever incremented anywhere in `src/core`. `accept_queue_depth` is just a snapshot updated by enqueue and dispatch in [`src/core/scheduler.zig#L119`](../src/core/scheduler.zig#L119) and [`src/core/scheduler.zig#L171`](../src/core/scheduler.zig#L171), not a synchronized measurement. `backpressure_events` only counts accept-queue rejection in [`src/core/scheduler.zig#L165`](../src/core/scheduler.zig#L165), not the all-workers-full condition in [`src/core/scheduler.zig#L116`](../src/core/scheduler.zig#L116). The API looks more complete than the implementation is.

14. Medium: the main loop busy-spins under worker-side backpressure.
When all worker deques are full, [`tick()`](../src/core/scheduler.zig#L116) stops dispatching and leaves work in the accept queue. [`run()`](../src/core/scheduler.zig#L135) only yields when `accept_queue.len == 0`, so under saturation it will spin continuously while workers drain. That does not violate the abstract spec, but it is a real operational gap in the current implementation of the stated backpressure strategy.

15. Medium: the worker lifecycle spec and the scheduler spec are not aligned enough to serve as one coherent authority.
`worker_lifecycle.tla` is still a narrow lifecycle race model. It starts workers in `"idle"` in [`worker_lifecycle.tla#L35`](./worker_lifecycle.tla#L35), models no deque recheck in park in [`worker_lifecycle.tla#L108`](./worker_lifecycle.tla#L108), and forbids work arrival before start in [`worker_lifecycle.tla#L128`](./worker_lifecycle.tla#L128). `scheduler.tla` has a stronger park rule in [`scheduler.tla#L221`](./scheduler.tla#L221) and a richer drain model in [`scheduler.tla#L133`](./scheduler.tla#L133). The implementation currently matches neither spec completely. If both files are meant to guide implementation, they need a single reconciled contract.

16. Medium: the tests do not cover several of the most important concurrency hazards.
The current tests do not exercise the lost-wake race, duplicate-frame enqueue, partial `WorkerPool.start()` failure, concurrent `spawnCoroutine()` producers, or the startup/shutdown race where `shutdown()` arrives before `run()` stores `running = true`. The only directly visible shutdown-drain defect is the currently failing test in [`src/core/scheduler.zig#L432`](../src/core/scheduler.zig#L432). The passing TLA models should not be treated as proof for these missing runtime behaviors because the runtime does not yet implement the modeled state transitions.

17. Low: some public configuration and worker-thread knobs are currently dead surface.
[`SchedulerConfig.tcp_backlog`](../src/core/scheduler.zig#L35) is unused. `ThreadConfig` exposes affinity, priority, and name in [`src/core/worker.zig#L13`](../src/core/worker.zig#L13), but [`setAffinity`](../src/core/worker.zig#L112), [`pinToCore`](../src/core/worker.zig#L118), and thread naming/priority behavior are stubs or ignored. This is not the primary correctness risk, but it contributes to the gap between the advertised runtime surface and the implemented one.

## Bottom Line

The TLA specs now model a substantially stronger scheduler/worker design than the Zig runtime actually implements. The current code still behaves like an early local-queue executor with park/wake, not the modeled drain-first work-stealing scheduler. The most important implementation blockers are:

1. implement real steal/drain behavior in workers,
2. fix the park lost-wake race by rechecking the local deque after publishing park intent,
3. give the scheduler a real owned task lifecycle instead of raw pointer tokens,
4. make shutdown and startup race-safe,
5. make the queueing/cancellation/metrics surfaces reflect real runtime behavior.
