# zap Comparison: Spec and Implementation Choices vs snek

Date: 2026-03-22

Compared against:

- `refs/zap` at commit `97d4b4d`
- [`refs/zap/README.md`](../refs/zap/README.md)
- [`refs/zap/blog.md`](../refs/zap/blog.md)
- [`refs/zap/src/thread_pool.zig`](../refs/zap/src/thread_pool.zig)
- [`refs/zap/src/thread_pool_go_based.zig`](../refs/zap/src/thread_pool_go_based.zig)
- [`specs/scheduler.tla`](./scheduler.tla)
- `specs/worker_lifecycle.tla` (archived — superseded by `scheduler.tla`)
- [`src/core/scheduler.zig`](../src/core/scheduler.zig)
- [`src/core/worker.zig`](../src/core/worker.zig)
- [`src/core/deque.zig`](../src/core/deque.zig)

## Executive Summary

zap is strong prior art for a high-performance Zig thread pool, but it is not close to a drop-in match for snek’s current scheduler design.

The biggest differences are:

1. zap has a narrative design doc plus source, not a formal executable spec.
2. zap does not use a textbook Chase-Lev deque as its full scheduling structure.
3. zap is a generic intrusive task thread pool, not an HTTP-runtime scheduler with an explicit accept queue and drain-first shutdown semantics.
4. zap chooses more runtime cleverness than snek currently does: lazy spawning, wake throttling, spurious-empty tolerance, and a hybrid queue structure.
5. snek’s current spec is stronger on correctness guarantees than zap’s documented design, especially around drain-first shutdown and explicit task lifecycle.

## Verification Notes

- `refs/zap` cloned successfully into `refs/zap/`.
- I did not find a formal spec or TLA model in zap.
- I did not find unit tests in zap’s repository under `src/` or `benchmarks/`; the repo appears to center the implementation, blog explanation, and benchmarks.
- `zig test src/core/scheduler.zig` currently passes in snek.

## 1. Spec Style

### zap

zap’s “spec” is informal and implementation-adjacent:

- README states the goal as an efficient Zig runtime/thread pool, not a formally checked scheduler model: [`refs/zap/README.md#L3`](../refs/zap/README.md#L3)
- `blog.md` presents the algorithm as evolving pseudocode and implementation rationale: [`refs/zap/blog.md#L116`](../refs/zap/blog.md#L116), [`refs/zap/blog.md#L384`](../refs/zap/blog.md#L384), [`refs/zap/blog.md#L453`](../refs/zap/blog.md#L453)

There is no formal state machine, no invariant suite, and no model-checked liveness/safety claims.

### snek

snek has explicit formal scheduler models:

- scheduler lifecycle, dispatch, steal, park/wake, drain-first shutdown: [`specs/scheduler.tla#L103`](./scheduler.tla#L103)
- worker lifecycle protocol: [`specs/worker_lifecycle.tla#L43`](./worker_lifecycle.tla#L43)

### Comparison

zap optimizes for implementation clarity and performance exploration.

snek optimizes for an explicit correctness contract.

This is a real tradeoff:

- zap’s approach is easier to evolve quickly and keep mentally aligned with code.
- snek’s approach is much better if you want to prove shutdown, ownership, and wakeup properties.

## 2. Queue Topology

### zap

zap uses a hybrid structure:

- per-thread bounded local buffer: [`refs/zap/src/thread_pool.zig#L316`](../refs/zap/src/thread_pool.zig#L316), [`refs/zap/src/thread_pool.zig#L591`](../refs/zap/src/thread_pool.zig#L591)
- per-thread unbounded intrusive queue: [`refs/zap/src/thread_pool.zig#L315`](../refs/zap/src/thread_pool.zig#L315), [`refs/zap/src/thread_pool.zig#L491`](../refs/zap/src/thread_pool.zig#L491)
- global intrusive queue on the pool: [`refs/zap/src/thread_pool.zig#L12`](../refs/zap/src/thread_pool.zig#L12)

The worker dequeue order is:

1. local buffer
2. local queue
3. global queue
4. other threads’ queues
5. other threads’ buffers

See: [`refs/zap/src/thread_pool.zig#L343`](../refs/zap/src/thread_pool.zig#L343)

This is not a pure Chase-Lev design. It is a bounded-buffer plus overflow-queue design with batched stealing.

### snek

snek’s formal scheduler uses:

- a bounded accept queue: [`specs/scheduler.tla#L115`](./scheduler.tla#L115)
- one bounded per-worker deque: [`specs/scheduler.tla#L162`](./scheduler.tla#L162)
- explicit worker stealing from other workers’ deques: [`specs/scheduler.tla#L188`](./scheduler.tla#L188)

The current implementation follows that direction:

- accept queue in scheduler: [`src/core/scheduler.zig#L63`](../src/core/scheduler.zig#L63)
- round-robin dispatch into worker local deques: [`src/core/scheduler.zig#L100`](../src/core/scheduler.zig#L100)
- local deque plus `trySteal()` in workers: [`src/core/worker.zig#L100`](../src/core/worker.zig#L100)

### Comparison

zap has a richer and more pragmatic queue topology than snek:

- zap separates fast local bounded storage from overflow storage.
- snek keeps a cleaner formal model by using one deque per worker plus a separate accept queue.

For an HTTP runtime, snek’s explicit accept queue is valuable because it models backpressure between accept/read and execution. zap’s generic pool does not need that separation.

## 3. Task Model and Ownership

### zap

zap’s task model is intrusive and explicit:

- `Task` embeds a `Node` and a callback: [`refs/zap/src/thread_pool.zig#L60`](../refs/zap/src/thread_pool.zig#L60)
- `Batch` schedules explicit task groups: [`refs/zap/src/thread_pool.zig#L67`](../refs/zap/src/thread_pool.zig#L67)
- callbacks recover their owner via `@fieldParentPtr`, as described in the blog: [`refs/zap/blog.md#L33`](../refs/zap/blog.md#L33)

This is a strong implementation choice:

- no opaque `u64` task tokens
- no ambiguous ownership model
- no separate “task state” bookkeeping inside the pool

### snek

snek’s implementation still uses raw frame pointers encoded as integers when dispatching to workers:

- scheduler pushes `@intFromPtr(frame)`: [`src/core/scheduler.zig#L112`](../src/core/scheduler.zig#L112)
- worker callback consumes `u64`: [`src/core/worker.zig#L128`](../src/core/worker.zig#L128)

The spec, however, models explicit task lifecycle states:

- `in_accept_queue`
- `in_worker_deque`
- `processing`
- `completed`

See: [`specs/scheduler.tla#L50`](./scheduler.tla#L50)

### Comparison

zap is simpler and sharper here.

Its task interface is lower-level than snek’s coroutine ambitions, but the ownership model is cleaner. snek’s spec is stronger, but the runtime task surface is still more ad hoc than zap’s.

If snek wants to keep coroutine frames, it would still benefit from adopting zap’s discipline:

- make the queued object itself the authoritative task node
- avoid raw integer task tokens
- make the execution callback path explicit

## 4. Stealing Policy

### zap

zap’s worker pop path steals in this order:

- peer queue first
- peer buffer second

See: [`refs/zap/src/thread_pool.zig#L373`](../refs/zap/src/thread_pool.zig#L373)

It traverses the thread stack using a rotating target pointer, not a formally random victim selector:

- [`refs/zap/src/thread_pool.zig#L369`](../refs/zap/src/thread_pool.zig#L369)

It also steals half the target buffer at a time to amortize steal cost:

- blog rationale: [`refs/zap/blog.md#L185`](../refs/zap/blog.md#L185)
- implementation: [`refs/zap/src/thread_pool.zig#L747`](../refs/zap/src/thread_pool.zig#L747)

### snek

snek’s formal model abstracts stealing existentially:

- [`specs/scheduler.tla#L192`](./scheduler.tla#L192)

The current implementation uses a simpler deterministic bounded scan:

- up to 3 victims
- sequential from `self.id + 1`

See: [`src/core/worker.zig#L104`](../src/core/worker.zig#L104)

### Comparison

zap’s stealing is more mature and more throughput-oriented:

- it steals from multiple storage tiers
- it steals batches from buffers
- it is integrated into its queue topology

snek’s current stealing is simpler and easier to reason about, but weaker as a performance design.

If snek’s goal is formal verifiability first, the current bounded-victim design is fine.
If the goal is eventual production throughput, zap’s tiered steal approach is better prior art than textbook Chase-Lev alone.

## 5. Wakeup and Idle Strategy

### zap

zap’s most distinctive choice is wake throttling via a packed `Sync` word:

- `state`, `notified`, `idle`, `spawned`: [`refs/zap/src/thread_pool.zig#L15`](../refs/zap/src/thread_pool.zig#L15)
- waking-thread algorithm: [`refs/zap/blog.md#L419`](../refs/zap/blog.md#L419)
- notification algorithm: [`refs/zap/src/thread_pool.zig#L120`](../refs/zap/src/thread_pool.zig#L120)

Core idea:

- at most one “waking thread” is allowed to fan out further wakeups
- `notified` prevents missed wakeups
- wakeups are throttled to avoid a thundering herd

### snek

snek’s spec and implementation are much simpler:

- worker park state is per-worker and binary: [`specs/scheduler.tla#L216`](./scheduler.tla#L216), [`src/core/worker.zig#L81`](../src/core/worker.zig#L81)
- the scheduler dispatch path wakes the target worker directly: [`specs/scheduler.tla#L115`](./scheduler.tla#L115), [`src/core/scheduler.zig#L112`](../src/core/scheduler.zig#L112)

There is no global wake-throttling state or “waking thread” concept.

### Comparison

zap is clearly more advanced here.

But it is also much harder to specify and validate formally.

For snek:

- if correctness and explicit lifecycle modeling matter most, the current per-worker park/wake model is simpler
- if high-load scheduler efficiency matters more, zap’s wake-throttling is the more sophisticated design

This is probably the single biggest algorithmic simplification opportunity for snek: either stay with simple per-worker wakeups, or fully commit to a zap-style wake-throttled design. Mixing the two would be awkward.

## 6. Thread Creation Policy

### zap

zap lazily spawns workers from `notify()` when needed:

- [`refs/zap/src/thread_pool.zig#L146`](../refs/zap/src/thread_pool.zig#L146)
- [`refs/zap/src/thread_pool.zig#L169`](../refs/zap/src/thread_pool.zig#L169)

It explicitly handles thread spawn failure by undoing the spawned count:

- blog rationale: [`refs/zap/blog.md#L437`](../refs/zap/blog.md#L437)
- implementation fallback path: [`refs/zap/src/thread_pool.zig#L171`](../refs/zap/src/thread_pool.zig#L171)

### snek

snek eagerly starts the whole worker pool in `run()`:

- [`src/core/scheduler.zig#L143`](../src/core/scheduler.zig#L143)
- worker pool start: [`src/core/worker.zig#L243`](../src/core/worker.zig#L243)

Current snek code is now failure-atomic on partial start:

- rollback path: [`src/core/worker.zig#L248`](../src/core/worker.zig#L248)

### Comparison

zap is more resource-efficient and adaptive.

snek is simpler and easier to fit to the TLA lifecycle.

For a backend HTTP framework, fixed workers per core is often the better default. zap’s lazy spawn is useful, but it is not obviously necessary for snek’s target architecture.

## 7. Shutdown Semantics

### zap

zap’s shutdown is pool-centric, not drain-centric:

- `shutdown()` flips the global state and wakes idle threads: [`refs/zap/src/thread_pool.zig#L237`](../refs/zap/src/thread_pool.zig#L237)
- workers exit when `wait()` returns `error.Shutdown`: [`refs/zap/src/thread_pool.zig#L180`](../refs/zap/src/thread_pool.zig#L180), [`refs/zap/src/thread_pool.zig#L328`](../refs/zap/src/thread_pool.zig#L328)
- join is coordinated after all workers unregister: [`refs/zap/src/thread_pool.zig#L298`](../refs/zap/src/thread_pool.zig#L298)

The blog’s shutdown section is about safe teardown of the pool and threads, not completion of all accepted work: [`refs/zap/blog.md#L443`](../refs/zap/blog.md#L443)

### snek

snek’s scheduler spec is explicitly drain-first:

- shutdown enters draining: [`specs/scheduler.tla#L129`](./scheduler.tla#L129)
- join requires empty accept queue and empty worker deques: [`specs/scheduler.tla#L141`](./scheduler.tla#L141)
- workers are only allowed to exit after no work remains anywhere: [`specs/scheduler.tla#L244`](./scheduler.tla#L244)

The implementation now moves toward that contract:

- accept queue drains in `run()`: [`src/core/scheduler.zig#L150`](../src/core/scheduler.zig#L150)
- workers drain local and stolen work after `running` goes false: [`src/core/worker.zig#L143`](../src/core/worker.zig#L143)

### Comparison

snek’s shutdown contract is stronger and more appropriate for HTTP request handling.

zap’s shutdown is appropriate for a generic task pool, but would be too weak if snek needs “accepted requests complete before exit.”

This is one area where snek should not regress toward zap.

## 8. Formal Guarantees vs Practical Heuristics

### zap

zap explicitly allows spurious-empty behavior and relies on `notify()` / `wait()` to make that safe:

- blog rationale: [`refs/zap/blog.md#L205`](../refs/zap/blog.md#L205)
- implementation comment: [`refs/zap/src/thread_pool.zig#L343`](../refs/zap/src/thread_pool.zig#L343)

This is a practical lock-free implementation choice.

### snek

snek’s spec tries to state explicit temporal properties:

- all tasks complete: [`specs/scheduler.tla#L387`](./scheduler.tla#L387)
- parked worker wakes: [`specs/scheduler.tla#L395`](./scheduler.tla#L395)
- no starvation: [`specs/scheduler.tla#L405`](./scheduler.tla#L405)

### Comparison

zap accepts weaker local semantics in exchange for a simpler and faster implementation path.

snek’s TLA work is trying to prove a stronger end-to-end story.

This suggests a useful rule:

- if snek wants zap’s implementation style, the spec should be relaxed to model spurious empty and heuristic stealing more explicitly
- if snek wants the current formal guarantees, it should keep a simpler runtime than zap

## 9. What zap Suggests We Should Change

Good candidates to adopt from zap:

1. Make the queued work object intrusive and explicit instead of relying on raw `u64` task tokens.
2. Be more explicit about the dequeue order in the spec and implementation.
3. Decide whether wake throttling is worth the complexity before adding more scheduler cleverness.
4. Treat “implementation blog + code + benchmarks” as useful engineering artifacts even when the formal spec remains the source of truth.

## 10. What We Should Not Copy Blindly

1. zap’s shutdown semantics.
   snek’s drain-first HTTP/runtime goals are stricter and should stay stricter.

2. zap’s lack of a formal spec.
   snek has already invested in formal scheduler modeling; dropping that would be a regression in rigor.

3. zap’s queue topology wholesale.
   snek’s accept queue is domain-specific and useful for explicit backpressure between network ingress and execution.

## Bottom Line

zap is best understood as proof that a serious Zig work-stealing pool does not need to be “pure Chase-Lev.”

Its main lessons for snek are:

- intrusive task ownership is cleaner than opaque task tokens
- wake throttling is a real design dimension, not just an optimization
- hybrid queue structures can outperform a cleaner textbook deque design

But snek’s formal scheduler and graceful-shutdown goals are stronger than zap’s documented contract. So the right move is not “become zap.” The right move is:

1. keep snek’s stronger formal contract,
2. borrow zap’s best implementation ideas selectively,
3. simplify where possible by reducing the gap between the formal model and the runtime, not by importing more cleverness than the spec can comfortably explain.
