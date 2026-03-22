# `worker_lifecycle.tla` Review

## Conclusion

`worker_lifecycle.tla` is a useful narrow spec for one concurrency protocol:

- `start()` publishes `running = TRUE` before worker execution begins
- workers recheck `running` after announcing intent to park
- `stop()` wakes parked workers and `join()` waits for termination

It is **not sufficient** as the complete scheduler and worker design spec for snek.

The file models a lifecycle race and a futex park/wake handshake. It does not model the scheduler architecture described in `design.md`, and it does not cover enough safety or liveness properties to justify calling it the full design spec.

## What The Current Spec Does Well

The current TLA+ model correctly focuses on a real and important bug class:

- startup/shutdown ordering races
- workers parking while shutdown is in progress
- workers waking after `stop()`
- proving that `start -> stop -> join` is the intended lifecycle

As a regression model for the specific `running` / `park_state` protocol, it is good.

## Why It Fails As A Complete Scheduler Spec

## 1. It does not model the scheduler, only worker lifecycle

Current state:

- `running`
- `park_state`
- `worker_pc`
- `main_pc`
- `deque_has_work : BOOLEAN`

That state is enough to model "has some work or not." It is not enough to model:

- multiple tasks
- queue depth
- task identity
- queue ownership
- stealing
- overflow
- starvation
- dispatch policy

The design in `design.md` commits to:

- one Chase-Lev deque per worker
- random victim selection for stealing
- fixed queue capacities
- an accept queue
- TCP backlog as a third backpressure stage

None of that exists in the current TLA model.

## 2. Three-tier backpressure is unmodeled

The runtime design depends on boundedness:

1. worker deque fills
2. accept queue fills
3. TCP backlog absorbs pressure

The current spec has no:

- queue capacities
- accept queue
- dispatch refusal
- overflow behavior
- backlog state

That means it cannot verify basic scheduler safety claims such as:

- internal bounded queues never overflow
- pressure propagates rather than panicking or silently dropping work
- workers stop accepting when full
- shutdown behaves sensibly with queued but unstarted work

## 3. Work stealing is absent

The design explicitly calls for work stealing. The spec contains no actions for:

- steal attempt
- victim choice
- steal success/failure
- owner vs thief semantics
- split between local pop and remote steal
- fairness between local and stolen work

Without these, the file cannot serve as the worker/scheduler design spec. At best it is a precondition model for a later scheduler spec.

## 4. Idle strategy is incomplete

The design says workers should:

- spin briefly
- then park on a futex
- wake on new work or I/O completion

The current spec models only:

- awake
- preparing to park
- parked

It omits:

- spin-before-park behavior
- I/O completions as a wake source
- throttled wakeups
- thundering-herd avoidance
- interactions between wake policy and scheduler utilization

That matters because the scheduler references emphasize wake throttling and search/wake discipline as first-order design choices, not incidental implementation details.

## 5. Liveness claims are weaker than they appear

The model uses weak fairness on:

- `MainStart`
- `MainStop`
- `MainJoin`
- worker internal steps

That is acceptable for a small protocol model, but it means some liveness properties are partly assumptions about the environment and main thread behavior.

For example, `EventuallyDone` is true because the spec assumes the main thread will eventually take `MainStop` and `MainJoin` when enabled. That does not establish that the real runtime:

- cannot deadlock during shutdown
- cannot livelock under steal/search behavior
- cannot strand queued work forever
- cannot starve one worker while others continue progressing

For a full scheduler spec, those are the important liveness questions.

## 6. Safety coverage is too shallow

The spec currently checks typing and a trivial terminated-worker property.

It does not state or check stronger scheduler properties such as:

- no task is executed twice
- no task is lost
- after stop, no new task begins execution
- every queued task is either executed or explicitly cancelled
- queue occupancy remains within configured bounds
- stealing preserves task ownership invariants
- shutdown does not admit new work after the cutoff point

These are the kinds of properties a complete design spec needs to make explicit.

## 7. Shutdown is under-modeled relative to the actual design

The runtime design has staged graceful shutdown:

- stop accepting new work
- drain HTTP requests
- close WebSockets
- wait for background tasks up to a timeout
- cancel stragglers

The TLA+ file only models:

- `MainStop`
- `MainJoin`

It has no representation of:

- in-flight requests
- background tasks
- cancellable vs non-cancellable work
- drain deadlines
- partial completion during shutdown
- rejection of post-shutdown submissions

That gap is large enough that the current file cannot be the authoritative shutdown spec either.

## 8. It does not match the strongest formal-verification inspiration in the repo

The references note that TLA+ is especially useful when proving that an optimized scheduler preserves the behavior of a simpler reference scheduler.

The current spec has:

- no abstract reference scheduler
- no refinement relation
- no distinction between abstract task execution and optimized implementation policy

So it is not yet using TLA+ in the strongest way suggested by the project references.

## What A Complete Scheduler/Worker Spec Must Add

At minimum, the next spec layer needs:

## 1. Task identity

Use task IDs or a finite task set instead of `BOOLEAN` queue occupancy.

This is necessary to express:

- no duplication
- no loss
- completion
- cancellation

## 2. Real queue structure

Model:

- per-worker local deque contents
- accept queue contents
- queue capacities
- possibly a simplified backlog capacity

Even abstract bounded sequences or sets are better than a single work bit.

## 3. Scheduler actions

Add actions for:

- local push
- local pop
- steal attempt
- steal success
- steal failure
- accept-to-worker dispatch
- reject-on-backpressure

## 4. Idle and wake policy

Add explicit worker states for:

- spinning
- searching
- parked
- runnable
- processing

And model wake sources:

- new task arrival
- I/O completion
- shutdown wake

## 5. Shutdown phases

Represent:

- accepting vs not accepting
- queued vs in-flight vs completed vs cancelled work
- grace period vs forced termination

## 6. Stronger safety invariants

Examples:

- each task is in exactly one state
- queue sizes never exceed capacity
- a stopped worker never starts a fresh task
- a task cannot be completed twice

## 7. Stronger liveness properties

Examples:

- if a task remains runnable and shutdown has not begun, it is eventually executed
- if shutdown begins, every in-flight worker eventually terminates
- a parked worker with pending assigned work is eventually woken
- bounded stealing/search does not permanently starve a worker

## Recommended Spec Structure

Do not stretch `worker_lifecycle.tla` into the only spec.

Instead:

1. Keep `worker_lifecycle.tla` as the narrow protocol spec for the `running` / `park_state` handshake.
2. Add a second scheduler-level spec that models task movement, bounded queues, steal/search behavior, and shutdown.
3. Optionally add a simpler reference scheduler and check that the optimized scheduler preserves its externally visible behavior.

That split keeps the current file valuable while avoiding the false claim that it already specifies the whole scheduler.

## Bottom Line

If `worker_lifecycle.tla` is treated as:

- a focused lifecycle-race spec: acceptable
- the complete scheduler and worker design spec: insufficient

The danger is not that the current spec is wrong. The danger is that it is too small for the claims being attached to it.
