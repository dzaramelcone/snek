# Scheduler/Worker Spec vs Implementation Gap Audit — Status Tracker

Original audit: 2026-03-22
Status update: 2026-03-22

## Verification Run (updated)

- `scheduler.tla` model checks cleanly: 668,190 states, 155,243 distinct, depth 29. ✅
- `worker_lifecycle.tla` model checks cleanly: 441,761 states, 57,204 distinct, depth 22. ✅
- `zig test src/core/worker.zig`: 76 tests pass. ✅
- `zig test src/core/scheduler.zig`: 129 tests pass. ✅ (previously failing test fixed)
- All tests pass on Linux (Docker, io_uring kernel 6.10.14). ✅

## Findings Status

### 1. High: drain-first shutdown — ✅ FIXED

Workers now call `drainLoop()` after the main `while (running)` loop exits.
`drainLoop` keeps popping from local deque and stealing from other workers
until no work remains. The previously failing test now passes. Workers drain
all remaining work before terminating.

**Test**: `audit: drain-first shutdown processes all remaining work` — pushes
100 items, starts, immediately stops, verifies all 100 processed.

### 2. High: work stealing absent — ✅ FIXED

Added `trySteal()` method to WorkerThread. Iterates up to 3 victims starting
from a deterministic offset (worker id + 1) to avoid herding. `runLoop` now
does: pop → steal → park. Workers also steal during drain (shutdown).

**Tests**: `audit: work stealing moves items between workers`,
`audit: trySteal returns null when no victims have work`,
`audit: trySteal skips self`,
`audit: work stealing happens during runLoop` (end-to-end: all work pushed
to worker 0, verifies worker 1 steals and processes some).

**Still incomplete**: `steal_attempts` and `steal_successes` metrics are NOT
incremented by `trySteal()`. The metrics struct exposes them but they remain
zero. See finding 13.

### 3. High: lost-wake race in park — ✅ FIXED

`park()` now rechecks `self.local_deque.len() > 0` after storing
`park_state=1`. If work arrived between the failed `pop()` and the park
intent publication, park is cancelled (park_state reset to 0) and the
worker returns to processing. Matches `scheduler.tla WorkerPark`.

**Test**: `audit: park rechecks deque (lost wakeup prevention)` — pushes to
deque then calls park(), verifies it returns without blocking.

**Still incomplete**: `worker_lifecycle.tla` has NOT been updated to include
the deque recheck. The two specs are still inconsistent on this point.
See finding 15.

### 4. High: no real coroutine execution path — ❌ NOT FIXED

Workers still invoke an optional `work_callback` on raw `u64` values.
There is no integration with `CoroutineFrame.resume()` or
`CoroutineFrame.complete()`. The scheduler pushes `@intFromPtr(frame)`
and workers receive `u64` — no frame lifecycle tracking.

**Reason**: Coroutine integration requires the Python FFI bridge (Phase 12-13).
The current callback-based approach is a placeholder. The real execution path
will call `frame.resume()` which calls into Python via `coro.send()`.

**Deferred to**: Phase 12-13 (Python integration).

### 5. High: single ownership not enforced in code — ⚠️ PARTIALLY ADDRESSED

The spec's `SingleOwnership` invariant is verified by TLC (668K states).
The implementation maintains ownership structurally: the intrusive
`FrameQueue` moves pointers (not copies), `push` sets `link.next = null`,
and `pop` clears `head.next`. However:

- **No runtime guard** against double-enqueue of the same frame.
  `FrameQueue.push()` does not check if the frame is already enqueued.
  Double-enqueue corrupts the intrusive linked list.
- **No task state tracking** at runtime. The frame's actual location
  (accept queue / worker deque / processing / completed) is not recorded.
- **Deque stores raw u64**, losing type information entirely.

**Deferred to**: Phase 12-13. **Recommended approach: adopt zap's intrusive
task model.** Make the queued object itself the authoritative task node —
the `CoroutineFrame` embeds its queue link and is recovered via
`@fieldParentPtr`. No raw `u64` tokens, no separate ownership tracking
needed. See `specs/zap_comparison.md` §3 (Task Model and Ownership) and
`refs/zap/src/thread_pool.zig` for the reference implementation.

### 6. High: frame lifetime contract unsafe — ❌ NOT FIXED

`spawnCoroutine()` accepts arbitrary `*CoroutineFrame` including stack
frames. If the caller's stack frame is deallocated before a worker
dereferences the `u64`, the runtime has a use-after-free.

No ownership contract is documented or enforced. `CoroutinePool` exists
but is not used by the scheduler path.

**Deferred to**: Phase 12-13. **Recommended approach**: scheduler allocates
frames from `CoroutinePool`, giving the pool ownership of lifetime. Combined
with the intrusive task model (finding 5), the frame IS the queued object —
allocated from the pool, enqueued by reference, recovered via
`@fieldParentPtr`, returned to pool on completion. See
`specs/zap_comparison.md` §3 and `refs/zap/blog.md` §fieldParentPtr.

### 7. High: cancellation not implemented end-to-end — ❌ NOT FIXED

`cancelCoroutine()` marks the frame as cancelled and increments a metric.
It does NOT:
- Remove the frame from the accept queue
- Remove it from any worker deque
- Prevent a worker from executing it

Workers never check `frame.state` or `isCancelled()` before processing.
The callback receives a raw `u64`, not a `*CoroutineFrame`.

**Deferred to**: Phase 12-13. With the intrusive task model (finding 5),
workers receive `*CoroutineFrame` directly (via `@fieldParentPtr`), not
`u64`. They can check `frame.isCancelled()` before calling `frame.resume()`.
Cancelled frames skip execution and return to the pool.

### 8. High: startup/shutdown race — ✅ FIXED

- `shut_down` changed from `bool` to `std.atomic.Value(bool)`.
  All reads use `.load(.acquire)`, all writes use `.store(true, .release)`.
- `run()` stores `running=true` BEFORE `pool.start()`, then rechecks
  `shut_down`. If shutdown already ran, running is reset to false.
- `running` was already `std.atomic.Value(bool)` (fixed in earlier commit).

**Tests**: `audit: shut_down is atomic` (type check),
`audit: startup race — running stored before pool.start` (spawn run()
thread, immediately shutdown, verify no hang).

### 9. High: WorkerPool.start() not failure-atomic — ✅ FIXED

Added `spawned` counter and `errdefer` block. On spawn failure:
1. Stop all already-spawned workers (`w.stop()`)
2. Join their threads (`w.thread.?.join()`)
3. Reset all workers' `running` flags to false

**No test**: Testing thread spawn failure is difficult without a custom
allocator or mock. The errdefer logic is structurally correct.

### 10. High: pre-start work allowed but specs forbid it — ⚠️ ACKNOWLEDGED, NOT RECONCILED

The implementation intentionally allows `spawnCoroutine()` before `run()`.
The accept queue is a buffer. Both specs forbid work arrival before start.

This is a deliberate design divergence:
- Implementation: spawn buffers work, run() dispatches it
- Spec: work only arrives after MainStart

**Action needed**: Either update `scheduler.tla` to allow pre-start
buffering (add a `NewTask` action for `main_pc = "ready"`), or tighten
the implementation to reject spawn before run. The current tests rely on
pre-start spawning.

### 11. Medium-high: accept queue not thread-safe — ⚠️ ACKNOWLEDGED, NOT FIXED

The `FrameQueue` is an unsynchronized intrusive linked list.
`spawnCoroutine()` and `tick()` both mutate it without locks.

Currently safe because `spawnCoroutine()` and `tick()` are called from
the same thread (the scheduler's main thread). If we ever allow
multi-producer spawning, this needs a lock or MPSC queue.

**Deferred to**: When multi-producer is needed (currently single-producer).

### 12. Medium-high: graceful shutdown stubbed — ⚠️ PARTIALLY ADDRESSED

`gracefulShutdown()` is now just `shutdown()` — both signal via atomic
flags and `run()` handles the drain. Workers drain their deques and steal
remaining work before exiting (finding 1 fix).

**Still incomplete**:
- `ShutdownConfig` timeout knobs are unused. No per-phase timeouts.
- `signal.zig`'s `executeGracefulShutdown` is still a stub.
- No distinction between HTTP drain, WebSocket drain, and task drain.

**Deferred to**: Phase 6+ (when we have real connections with timeouts).

### 13. Medium-high: metrics incomplete and misleading — ⚠️ PARTIALLY ADDRESSED

- `coroutines_spawned`: ✅ incremented on spawn
- `coroutines_cancelled`: ✅ incremented on cancel (idempotent)
- `backpressure_events`: ✅ incremented on accept queue full
- `accept_queue_depth`: ✅ updated on enqueue and dispatch
- `poll_count`: ✅ incremented per tick

**Still zero / not incremented**:
- `coroutines_completed`: ❌ never incremented (no completion tracking)
- `steal_attempts`: ❌ never incremented (trySteal doesn't record)
- `steal_successes`: ❌ never incremented (trySteal doesn't record)

**Action needed**: Add steal metrics to `trySteal()`. Completion tracking
requires coroutine lifecycle integration (Phase 12-13).

### 14. Medium: main loop busy-spins under backpressure — ❌ NOT FIXED

When all worker deques are full, `tick()` stops dispatching.
`run()` only yields when `accept_queue.len == 0`. Under saturation,
the main loop spins on `tick()` + `Thread.yield()` with a non-empty
accept queue but no dispatchable workers.

**Action needed**: Yield or sleep briefly when dispatch makes no progress
(accept queue non-empty but no frames dispatched in this tick).

### 15. Medium: worker_lifecycle.tla and scheduler.tla not reconciled — ❌ NOT FIXED

`worker_lifecycle.tla` still:
- Does not model deque recheck in park (finding 3 is fixed in code but
  not reflected in this spec)
- Forbids work before start (implementation allows it)
- Has no steal action
- Has no drain model

`scheduler.tla` is the authoritative spec. `worker_lifecycle.tla` is now
a historical artifact of the narrow lifecycle race proof. It should either
be updated to be consistent with `scheduler.tla` or archived with a note
that `scheduler.tla` supersedes it.

### 16. Medium: tests don't cover critical concurrency hazards — ⚠️ PARTIALLY ADDRESSED

**Now covered by tests**:
- ✅ Lost-wake race (park deque recheck)
- ✅ Work stealing correctness
- ✅ Drain-first shutdown
- ✅ Startup/shutdown race
- ✅ Atomic shut_down type

**Still not covered**:
- ❌ Duplicate-frame enqueue (intrusive list corruption)
- ❌ Partial WorkerPool.start() failure (thread spawn mock needed)
- ❌ Concurrent spawnCoroutine() from multiple producers
- ❌ Cancellation honored before execution

### 17. Low: dead configuration surface — ❌ NOT FIXED

`SchedulerConfig.tcp_backlog` is unused. `ThreadConfig.affinity`,
`ThreadConfig.priority`, `ThreadConfig.name` are dead fields.
`setAffinity()` and `pinToCore()` are stubs.

**Deferred to**: Phase 6+ (TCP networking will use `tcp_backlog`).

## Summary

| Finding | Severity | Status |
|---------|----------|--------|
| 1. Drain-first shutdown | High | ✅ Fixed |
| 2. Work stealing | High | ✅ Fixed (metrics incomplete) |
| 3. Lost-wake race | High | ✅ Fixed (worker_lifecycle.tla not updated) |
| 4. Coroutine execution path | High | ❌ Deferred to Phase 12-13 |
| 5. Single ownership enforcement | High | ⚠️ Structural only, no runtime guard |
| 6. Frame lifetime contract | High | ❌ Deferred to Phase 12-13 |
| 7. End-to-end cancellation | High | ❌ Deferred to Phase 12-13 |
| 8. Startup/shutdown race | High | ✅ Fixed |
| 9. start() failure rollback | High | ✅ Fixed |
| 10. Pre-start work vs spec | High | ⚠️ Acknowledged divergence |
| 11. Accept queue thread safety | Med-High | ⚠️ Safe for single-producer |
| 12. Graceful shutdown timeouts | Med-High | ⚠️ Drain works, timeouts stubbed |
| 13. Metrics incomplete | Med-High | ⚠️ 5/8 metrics working |
| 14. Busy-spin under backpressure | Medium | ❌ Not fixed |
| 15. Spec reconciliation | Medium | ❌ Not fixed |
| 16. Test coverage gaps | Medium | ⚠️ 5/9 hazards covered |
| 17. Dead config surface | Low | ❌ Deferred |

**Fixed**: 4 of 17 (findings 1, 2, 3, 8, 9)
**Partially addressed**: 5 of 17 (findings 5, 10, 11, 12, 13, 16)
**Not fixed / deferred**: 8 of 17 (findings 4, 6, 7, 14, 15, 17)

The core scheduler correctness gaps (stealing, draining, park race, atomics)
are resolved. The remaining gaps fall into two categories:
- **Phase 12-13 work** (coroutine lifecycle, ownership, cancellation) —
  structurally requires Python integration
- **Polish** (metrics, spec reconciliation, dead config, busy-spin) —
  important but not blocking forward progress
