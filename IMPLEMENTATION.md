# IMPLEMENTATION.md

**Status:** Active
**Last updated:** 2026-03-21

Complete implementation roadmap for snek — from stubs to shipping.

---

## Philosophy

1. **Domain-by-domain, bottom-up.** Build the lowest-level primitives first. Every layer depends only on completed layers below it. Never reach up.

2. **Tests first, then minimum viable implementation.** Write the test stubs (already present in each `.zig` file), make them fail, then write the smallest possible implementation that passes. No speculative code.

3. **Extreme verification at every step:**
   - **TLA+ models** for concurrent subsystems (scheduler, deque, pool, connection pool)
   - **Benchmarks** against existing implementations cited in REFERENCES.md
   - **valgrind/ASan** for memory correctness; Zig's `testing.allocator` for leak detection
   - **VOPR simulation** for correctness under faults (deterministic replay from a single `u64` seed)
   - **Conformance suites** where applicable (Autobahn, h2spec, testssl.sh)

4. **UAT: step-through debugging, binary sampling, stack traces.** Every phase includes manual verification — not just automated tests.

5. **Cite sources for every design choice.** Every implementation decision points back to a specific finding in `REFERENCES.md`, `INSIGHTS.md`, or `GAPS_RESEARCH.md`.

6. **Document completions in single readable one-liners** in the Implementation Journal at the bottom of this file.

7. **Absolute minimum Zig code to get it working.** No premature optimization. No clever tricks until benchmarks demand them. The simplicity criterion: if removing code produces equal results, remove it.

8. **Integration tests after each domain.** Each completed level gets an integration test proving it works with the levels below.

9. **End-to-end happy path as the final boss.** `pip install snek` → write app → `snek run` → serves traffic → all conformance suites pass → benchmarks meet targets.

---

## DAG (Dependency Graph)

```
                            ┌─────────────────────────────────────────────────────────────┐
                            │                    Level 0 (no deps)                        │
                            │  assert · coverage · static_alloc · pool (HiveArray) · arena│
                            └────────────────────────┬────────────────────────────────────┘
                                                     │
                            ┌────────────────────────▼────────────────────────────────────┐
                            │                Level 1 (depends on L0)                      │
                            │              deque · buffer · timer                         │
                            └────────────────────────┬────────────────────────────────────┘
                                                     │
                      ┌──────────────────────────────▼──────────────────────────────┐
                      │                  Level 2 (depends on L1)                    │
                      │        io (platform abstraction) · fake_io · signal         │
                      └──────────────────────────────┬──────────────────────────────┘
                                                     │
                      ┌──────────────────────────────▼──────────────────────────────┐
                      │                  Level 3 (depends on L2)                    │
                      │               io_uring · kqueue                             │
                      └──────────────────────────────┬──────────────────────────────┘
                                                     │
                      ┌──────────────────────────────▼──────────────────────────────┐
                      │                  Level 4 (depends on L3)                    │
                      │               worker · coroutine                            │
                      └──────────────────────────────┬──────────────────────────────┘
                                                     │
                      ┌──────────────────────────────▼──────────────────────────────┐
                      │                  Level 5 (depends on L4)                    │
                      │                    scheduler                                │
                      └────────┬─────────────────────┬──────────────────────────────┘
                               │                     │
              ┌────────────────▼───────┐   ┌────────▼────────────────────────────┐
              │   Level 6 (L5)         │   │  Level 10 (L5, independent of HTTP) │
              │    net/tcp             │   │  db/auth · db/wire · redis/protocol │
              └────────┬───────────────┘   └────────┬────────────────────────────┘
                       │                            │
              ┌────────▼───────────────┐   ┌────────▼────────────────────────────┐
              │   Level 7 (L6)         │   │  Level 11 (L10)                     │
              │  net/tls · net/http1   │   │  db/{types,query,pipeline,pool,     │
              │  net/smuggling         │   │     notify,schema}                  │
              └────────┬───────────────┘   │  redis/{connection,pool,commands,   │
                       │                   │        pubsub,lua}                  │
              ┌────────▼───────────────┐   └────────┬────────────────────────────┘
              │   Level 8 (L7)         │            │
              │  http/{router,request, │            │
              │   response,cookies}    │            │
              └────────┬───────────────┘            │
                       │                            │
              ┌────────▼───────────────┐            │
              │   Level 9 (L8)         │            │
              │  http/{compress,       │            │
              │   validate,middleware} │            │
              │  json/{parse,serialize}│            │
              └────────┬───────────────┘            │
                       │                            │
                       │  ╔════════════════════╗    │
                       │  ║ MILESTONE: snek    ║    │
                       │  ║ serves "hello      ║    │
                       │  ║ world" over HTTP   ║    │
                       │  ╚════════════════════╝    │
                       │                            │
                       │                  ╔═════════╧════════════╗
                       │                  ║ MILESTONE: Postgres  ║
                       │                  ║ and Redis work       ║
                       │                  ║ standalone           ║
                       │                  ╚═════════╤════════════╝
                       │                            │
              ┌────────▼────────────────────────────▼────────────┐
              │              Level 12 (L9 + L11)                 │
              │          python/ffi · python/gil                 │
              └────────────────────────┬─────────────────────────┘
                                       │
              ┌────────────────────────▼─────────────────────────┐
              │              Level 13 (L12)                      │
              │  python/{coerce,driver,module,context,inject}    │
              └────────────────────────┬─────────────────────────┘
                                       │
                             ╔═════════╧════════════╗
                             ║ MILESTONE: snek runs ║
                             ║ Python handlers      ║
                             ╚═════════╤════════════╝
                                       │
              ┌────────────────────────▼─────────────────────────┐
              │              Level 14 (L13)                      │
              │  security/{cors,headers,jwt}                     │
              │  config/{toml,env}                               │
              │  observe/{log,metrics,health,trace}              │
              │  serve/{static,client}                           │
              └────────────────────────┬─────────────────────────┘
                                       │
              ┌────────────────────────▼─────────────────────────┐
              │              Level 15 (L14)                      │
              │  cli/{main,commands}                             │
              │  net/{http2,websocket}                           │
              └────────────────────────┬─────────────────────────┘
                                       │
                             ╔═════════╧════════════╗
                             ║ MILESTONE: snek is   ║
                             ║ production-usable    ║
                             ╚═════════╤════════════╝
                                       │
              ┌────────────────────────▼─────────────────────────┐
              │              Level 16 (L15)                      │
              │  testing/{simulation,client,conformance}         │
              │  Python package (snek.Model, DI, OpenAPI, docs)  │
              └────────────────────────┬─────────────────────────┘
                                       │
                             ╔═════════╧════════════╗
                             ║ MILESTONE: snek is   ║
                             ║ shippable            ║
                             ╚════════════════════════╝
```

**Parallelism:** Levels 6-9 (HTTP path) and Levels 10-11 (DB/Redis path) are fully independent and can be built in parallel once Level 5 is complete.

---

## Phases

### Phase 0: Foundations (Level 0)

**Goal:** Implement the zero-dependency primitives that everything else builds on.

**Dependencies:** None.

**Files:**
- `src/core/assert.zig`
- `src/core/coverage.zig`
- `src/core/static_alloc.zig`
- `src/core/pool.zig`
- `src/core/arena.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Not applicable (no concurrency).
2. **Unit tests:**
   - `assert.zig`: Verify `snek_assert` crashes on false, passes on true. Test format string args.
   - `coverage.zig`: Mark a path, check it was hit, check unhit paths are detected.
   - `static_alloc.zig`: Allocate in `init` state, transition to `static`, verify allocation panics, transition to `deinit`, verify frees work. Leak detection via `testing.allocator`.
   - `pool.zig` (HiveArray): Acquire all slots, verify exhaustion returns null, release and reacquire. Test `count()` and `available()` at each step. Edge: capacity=1, capacity=64 (bitset boundary).
   - `arena.zig`: Allocate, reset with retention, verify retained pages aren't munmapped. Leak detection.
3. **Benchmarks:** HiveArray acquire/release vs `std.heap.MemoryPool` — target O(1) via leading-zeros intrinsic. Reference: TigerBeetle IOPSType (`refs/tigerbeetle/INSIGHTS.md` §12).
4. **Memory verification:** All tests run with `testing.allocator`. `static_alloc.zig` must detect any runtime allocation after lock.
5. **VOPR simulation:** Not applicable.
6. **UAT:** Step through HiveArray bitset operations in a debugger. Verify the leading-zeros intrinsic produces correct slot indices.
7. **Conformance:** Not applicable.

**Implementation notes:**
- `static_alloc.zig`: Direct port of TigerBeetle's `static_allocator.zig` three-state machine (`init` → `static` → `deinit`). Reference: `refs/tigerbeetle/INSIGHTS.md` §6.
- `pool.zig` (HiveArray): Bun's HiveArray pattern — `std.bit_set.IntegerBitSet(capacity)` with `@clz` for O(1) first-free-bit. Reference: design.md §1.5.
- `arena.zig`: Wrap `std.heap.ArenaAllocator` with configurable `retain_allocated_bytes` on reset. Reference: `refs/http.zig/INSIGHTS.md` §6 (arena + retention pattern).
- `coverage.zig`: Port TigerBeetle's `testing/marks.zig` — lightweight `mark()`/`check()` pairs. Reference: `refs/tigerbeetle/INSIGHTS.md` §2.
- Minimum viable scope: Each file is self-contained. No cross-file dependencies within this phase.

**Completion criteria:**
- [ ] `zig build test` passes for all five files
- [ ] `static_alloc` panics on runtime allocation after lock (verified by test)
- [ ] `HiveArray` acquire/release cycle for full capacity works
- [ ] `coverage` marks are traceable from test to code path
- [ ] Zero leaks reported by `testing.allocator`

**Journal entry format:** `[DATE] Phase 0.N: <one-liner describing what was completed>`

---

### Phase 1: Core Data Structures (Level 1)

**Goal:** Implement the concurrent deque, buffer management, and timer wheel that the scheduler depends on.

**Dependencies:** Phase 0 complete (assert, pool, arena).

**Files:**
- `src/core/deque.zig`
- `src/core/buffer.zig`
- `src/core/timer.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Model Chase-Lev deque with two processes (owner + thief). Properties to verify:
   - **Safety:** No item is ever returned by both `pop()` and `steal()`.
   - **Linearizability:** Every successful operation corresponds to a unique item.
   - **No lost items:** Every pushed item is eventually popped or stolen (liveness under fairness).
   - **Overflow correctness:** Wrapping arithmetic on `top`/`bottom` produces correct length even across `usize` wraparound.
2. **Unit tests:**
   - `deque.zig`: Push N items, pop N items (owner-only). Push N, steal N (thief-only). Concurrent push/steal with `std.Thread`. Empty deque pop returns null. Empty deque steal returns null. Wraparound test: push/pop 2^16 items to force index wrapping.
   - `buffer.zig`: Four buffer types (pooled, dynamic, static, arena). Grow/resize. Pool exhaustion → dynamic fallback. Release pooled buffer back to pool. Reference: `refs/http.zig/INSIGHTS.md` §6.
   - `timer.zig`: Insert timer, advance time, verify expiration callback. Cancel timer before expiration. Multiple timers with different deadlines. Timer wheel wrap-around.
3. **Benchmarks:**
   - Chase-Lev push/pop throughput vs Crossbeam deque (Rust). Target: competitive on single-thread, within 2x on contended steal. Reference: `src/core/REFERENCES.md` §1.2-1.3 (Crossbeam).
   - Timer insertion/expiration: O(1) amortized.
4. **Memory verification:** valgrind on deque stress test (1M push/pop cycles). ASan on buffer grow/release.
5. **VOPR simulation:** Not yet (deferred to scheduler phase). But Chase-Lev gets a property-based fuzz test with random interleaving.
6. **UAT:** Inspect atomic ordering of deque operations in disassembly. Verify `acquire`/`release`/`seq_cst` fences are where expected.
7. **Conformance:** Not applicable.

**Implementation notes:**
- `deque.zig`: Chase-Lev with C11 atomics, using Zig's wrapping arithmetic (`+%`, `-%`) to avoid the Le et al. integer overflow bug. Reference: `src/core/REFERENCES.md` §1.2, specifically the Andy Wingo analysis at `wingolog.org/archives/2022/10/03/...`. The fix is already documented in the stub's header comment.
- `buffer.zig`: Four-type buffer system from `refs/http.zig/INSIGHTS.md` §6. Comptime conditional locking: `if (is_threaded) Mutex else void`.
- `timer.zig`: Hierarchical timing wheel (Varghese & Lauck). Simple enough: 256-slot wheel with overflow list. Reference: `src/core/REFERENCES.md` §8 (Adaptive Scheduling).
- Known pitfall: Chase-Lev `steal()` must use `cmpxchgStrong` on `top`, not `cmpxchgWeak`, to avoid ABA on high contention.

**Completion criteria:**
- [ ] TLA+ model verified (no safety violations in 10M states)
- [ ] Chase-Lev passes concurrent stress test (4 threads, 1M ops)
- [ ] Buffer pool typed correctly: pooled items returned, dynamic items freed
- [ ] Timer wheel fires callbacks at correct virtual time
- [ ] Zero leaks, zero ASan findings

**Journal entry format:** `[DATE] Phase 1.N: <one-liner>`

---

### Phase 2: I/O Abstraction (Level 2)

**Goal:** Define the Generic-over-IO interface, implement FakeIO for testing, and add signal handling.

**Dependencies:** Phase 1 complete (buffer for I/O buffers).

**Files:**
- `src/core/io.zig`
- `src/core/fake_io.zig`
- `src/core/signal.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Not applicable (interfaces, not concurrent logic).
2. **Unit tests:**
   - `io.zig`: Compile-time assertion that both `IoUring` and `FakeIO` satisfy the `IO` interface contract (duck-typing via comptime).
   - `fake_io.zig`: Deterministic replay — same seed produces same sequence of completions. Submit read, get predetermined bytes. Submit write, verify bytes are captured. Fault injection: configurable error returns. Simulated latency via virtual clock.
   - `signal.zig`: Register SIGTERM handler, send signal, verify handler fires. Verify SIGINT double-tap behavior (second signal = immediate exit).
3. **Benchmarks:** Not applicable (interfaces and fakes).
4. **Memory verification:** FakeIO must work with `testing.allocator` — no leaks.
5. **VOPR simulation:** FakeIO IS the simulation infrastructure. Verify seed reproducibility: run the same sequence twice with the same seed, assert identical results.
6. **UAT:** Step through FakeIO completion delivery. Verify virtual clock advances correctly.
7. **Conformance:** Not applicable.

**Implementation notes:**
- `io.zig`: Platform dispatch via `switch (builtin.target.os.tag)`. Reference: `refs/tigerbeetle/INSIGHTS.md` §1 (platform dispatch pattern). Define the `Completion` struct following TigerBeetle's pattern: `io`, `result`, `operation` (tagged union), `context` (`?*anyopaque`), `callback` (function pointer). Type erasure via comptime `erase_types`. Reference: `refs/tigerbeetle/INSIGHTS.md` §11.
- `fake_io.zig`: ~200 lines. PRNG-driven completion delivery. Three-queue architecture (unqueued, submitted, completed) matching production. Reference: `refs/tigerbeetle/INSIGHTS.md` §2 (VOPR mock IO).
- `signal.zig`: `std.posix.sigaction` for SIGTERM/SIGINT. Write to a self-pipe or eventfd to wake the event loop.
- Minimum viable: FakeIO must support `accept`, `recv`, `send`, `close`, `timeout`. File I/O deferred.

**Completion criteria:**
- [ ] `FakeIO` is seed-reproducible (same seed = same execution)
- [ ] Both `IoUring` and `FakeIO` compile against the same `comptime IO: type` consumers
- [ ] Signal handler fires and sets shutdown flag
- [ ] Completion callback type erasure works (comptime verified)

**Journal entry format:** `[DATE] Phase 2.N: <one-liner>`

---

### Phase 3: Platform I/O Backends (Level 3)

**Goal:** Implement the real io_uring and kqueue backends behind the Generic-over-IO interface.

**Dependencies:** Phase 2 complete (io.zig interface).

**Files:**
- `src/core/io_uring.zig`
- `src/core/kqueue.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Model the three-queue architecture (unqueued → kernel → completed) for io_uring. Properties: no SQE leak (every submitted SQE eventually completes or is cancelled), no CQE overflow without detection.
2. **Unit tests:**
   - `io_uring.zig`: Submit a read on a pipe, verify completion. Submit accept on a listening socket, connect from another thread, verify accept completes. Submit send + recv across a socket pair. Timeout operation. Cancel an in-flight operation. Multishot accept (if kernel supports it).
   - `kqueue.zig`: Same test suite as io_uring (they share the interface). Accept, recv, send, close, timeout, cancel.
3. **Benchmarks:**
   - io_uring: `submit_and_wait` syscall batching — measure syscalls/op with `strace`. Target: <1 syscall per I/O operation on average (via batching). Reference: `refs/tigerbeetle/INSIGHTS.md` §12 (syscall minimization).
   - kqueue: Baseline throughput for comparison. Accept that kqueue is slower; it's for macOS dev only.
4. **Memory verification:** valgrind on 10K accept/close cycles. ASan on buffer ownership across kernel boundary.
5. **VOPR simulation:** Not directly — FakeIO covers this. But verify that switching between `IoUring` and `FakeIO` in the same test binary compiles and runs correctly.
6. **UAT:** Use `strace` to verify io_uring syscall patterns. Verify `IORING_ENTER` batching. On macOS, use `dtruss` for kqueue syscalls.
7. **Conformance:** Not applicable.

**Implementation notes:**
- `io_uring.zig`: Follow TigerBeetle's linux.zig structure (~900 lines). Completion struct with type-erased callbacks. Three-queue architecture. EINTR auto-retry. `submit_and_wait` for syscall minimization. Reference: `refs/tigerbeetle/INSIGHTS.md` §1.
- `kqueue.zig`: Follow TigerBeetle's darwin.zig structure. Thread pool for file I/O (kqueue can't do async file ops). Reference: `refs/tigerbeetle/INSIGHTS.md` §1 (Darwin fallback).
- Known pitfall: io_uring registered buffers (`IORING_REGISTER_BUFFERS`) are powerful but add complexity. Defer to optimization phase.
- Known pitfall: kqueue `EV_EOF` handling differs between macOS and FreeBSD.
- Minimum viable: `accept`, `recv`, `send`, `close`, `timeout`. No SQPOLL, no registered fds, no multishot. Add those later when benchmarks demand them.

**Completion criteria:**
- [ ] io_uring backend passes all interface tests on Linux
- [ ] kqueue backend passes all interface tests on macOS
- [ ] Both backends compile behind the same `comptime IO: type` generic
- [ ] Syscall batching verified via strace (io_uring)
- [ ] EINTR auto-retry verified
- [ ] Zero leaks on 10K connection cycle

**Journal entry format:** `[DATE] Phase 3.N: <one-liner>`

---

### Phase 4: Workers and Coroutines (Level 4)

**Goal:** Implement the worker thread pool and stackless coroutine state machines.

**Dependencies:** Phase 3 complete (io_uring/kqueue backends).

**Files:**
- `src/core/worker.zig`
- `src/core/coroutine.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Model work-stealing across N workers. Properties:
   - **No starvation:** If work exists, some worker eventually executes it.
   - **No duplicate execution:** Each task is executed exactly once.
   - **Bounded steal attempts:** Thieves give up after K attempts and park.
2. **Unit tests:**
   - `worker.zig`: Spawn N workers, submit M tasks, verify all M complete. Work stealing: overload one worker, verify others steal. Worker parking: all workers idle → verify they park on futex. Worker wake: parked worker wakes on new work.
   - `coroutine.zig`: Create a coroutine frame, step through states (Ready → Running → Suspended → Completed). Verify suspend/resume preserves local state. Cancellation: cancel a suspended coroutine, verify cleanup runs. Comptime pipeline builder: chain 3 steps, verify execution order.
3. **Benchmarks:**
   - Worker throughput: tasks/sec with N workers on M tasks. Compare to Go's goroutine scheduler and Tokio's work-stealing. Reference: `src/core/REFERENCES.md` §1 (Blumofe-Leiserson bound, Rayon).
   - Coroutine frame size: measure bytes per coroutine. Target: 64-256 bytes (stackless advantage). Reference: `src/core/REFERENCES.md` §2 (stackless vs stackful table).
4. **Memory verification:** valgrind on worker lifecycle (spawn, work, shutdown). ASan on coroutine frame access after completion.
5. **VOPR simulation:** Run scheduler with FakeIO. Random task submission, random steal timing (PRNG-driven). Verify all tasks complete. Reference: `refs/tigerbeetle/INSIGHTS.md` §2 (VOPR architecture).
6. **UAT:** Step through a coroutine suspension in the debugger. Verify the state machine transition from Running to Suspended preserves locals.
7. **Conformance:** Not applicable.

**Implementation notes:**
- `worker.zig`: Each worker owns a Chase-Lev deque (Phase 1) and an IO instance (Phase 3). Random victim selection for stealing (3 attempts, then park). Idle strategy: spin briefly, then futex park. Reference: design.md §1.2 (three-tier backpressure), `src/core/REFERENCES.md` §1.3 (Rayon, Tokio patterns).
- `coroutine.zig`: Comptime pipeline builder generates enum-based state machines. Each state holds the captured locals for that suspension point. `CoroutineFrame` is the runtime handle. Reference: design.md §1.1 (stackless coroutines), `src/core/REFERENCES.md` §2 (stackless analysis).
- Known pitfall: Worker shutdown ordering — must drain deques before joining threads.
- Minimum viable: Fixed worker count (no adaptive). No CPU affinity. No NUMA awareness.

**Completion criteria:**
- [ ] TLA+ model verifies no starvation, no duplicate execution
- [ ] Work stealing functions under load imbalance
- [ ] Coroutine suspend/resume preserves state correctly
- [ ] Comptime pipeline builder chains 3+ steps
- [ ] All workers shut down cleanly (no leaked threads)

**Journal entry format:** `[DATE] Phase 4.N: <one-liner>`

---

### Phase 5: Scheduler (Level 5)

**Goal:** Implement the top-level scheduler that orchestrates workers, timers, and the accept queue.

**Dependencies:** Phase 4 complete (worker, coroutine).

**Files:**
- `src/core/scheduler.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Full scheduler model: accept queue → worker dispatch → coroutine execution → completion. Properties:
   - **Three-tier backpressure:** When workers are full, accept queue fills, then TCP backlog absorbs.
   - **Graceful shutdown:** All in-flight coroutines complete or are cancelled within timeout.
   - **Metrics accuracy:** `coroutines_spawned - coroutines_completed - coroutines_cancelled == active_count` at all times.
2. **Unit tests:**
   - Scheduler init/deinit lifecycle. Run with zero load. Run with one task. Graceful shutdown with in-flight tasks. Shutdown timeout (tasks take too long → force cancel). Metrics counters.
   - Generic over FakeIO: `Scheduler(FakeIO)` compiles and runs.
3. **Benchmarks:**
   - Throughput: coroutines spawned/completed per second. Compare to Tokio (Rust), Seastar (C++). Reference: `src/core/REFERENCES.md` §4 (Seastar benchmarks).
   - Backpressure: verify accept rate drops when workers are saturated.
4. **Memory verification:** `testing.allocator` for all scheduler internals. StaticAllocator in production mode — verify no allocation after startup.
5. **VOPR simulation:** Full simulation: FakeIO drives accept completions at random intervals, coroutines suspend/resume randomly, verify all complete or cancel on shutdown. Swarm testing: randomize worker count, deque capacity, accept queue capacity. Reference: `refs/tigerbeetle/INSIGHTS.md` §2 (swarm testing).
6. **UAT:** Start scheduler, submit tasks via FakeIO, step through one task's full lifecycle.
7. **Conformance:** Not applicable.

**Implementation notes:**
- Three-tier backpressure directly from design.md §1.2. The scheduler is the orchestrator — it owns the `WorkerPool(IO)`, `TimerWheel`, and accept queue.
- Process dies on panic (v1). No thread-level recovery. Reference: design.md §1.6, `docs/GAPS_RESEARCH.md` §4 (worker resilience — recommendation is Option A for v1).
- Auto-detect CPU count when `num_threads = 0`. Use `std.Thread.getCpuCount()`.
- The scheduler is the integration point for Phases 0-4. This is where everything comes together for the first time.

**Completion criteria:**
- [ ] TLA+ model verifies three-tier backpressure
- [ ] Scheduler runs with FakeIO (deterministic simulation)
- [ ] Graceful shutdown drains in-flight work within timeout
- [ ] Backpressure prevents accept when workers are full
- [ ] Metrics are accurate (spawned - completed - cancelled == active)
- [ ] StaticAllocator passes: zero runtime allocations in hot-path I/O buffers (per-request arenas and infrequent allocations use separate allocators)

**Journal entry format:** `[DATE] Phase 5.N: <one-liner>`

---

### Phase 6: TCP Networking (Level 6)

**Goal:** Implement non-blocking TCP accept, connections, and keepalive.

**Dependencies:** Phase 5 complete (scheduler).

**Files:**
- `src/net/tcp.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Not applicable (TCP is kernel-managed; our layer is thin).
2. **Unit tests:**
   - Listen on a port, accept a connection, recv data, send data, close. Keepalive: multiple requests on one connection. Connection limits: reject when at max. SO_REUSEPORT: multiple listeners on same port.
3. **Benchmarks:**
   - Connections/second: accept rate under load. Compare to nginx baseline. Target: 50K+ accepts/sec on Linux with io_uring.
   - Connection holding: sustain 10K idle keepalive connections.
4. **Memory verification:** Pre-allocated connection pool (HiveArray from Phase 0). Verify no allocation per connection.
5. **VOPR simulation:** FakeIO simulates accept completions, connection resets, slow clients (partial reads).
6. **UAT:** `nc` to a running TCP listener, send bytes, verify echo.
7. **Conformance:** Not applicable.

**Implementation notes:**
- Non-blocking sockets managed by io_uring/kqueue. `TCP_NODELAY` on by default. `SO_REUSEPORT` on Linux for multi-worker accept. Reference: `refs/http.zig/INSIGHTS.md` §5 (SO_REUSEPORT, EPOLLEXCLUSIVE).
- Connection pool uses HiveArray from Phase 0. Two arenas per connection (`conn_arena` + `req_arena`) from `refs/http.zig/INSIGHTS.md` §4.
- Keepalive: HTTP keepalive timeout (default 75s), TCP keepalive (SO_KEEPALIVE after 60s idle). Reference: design.md §2.1.
- Minimum viable: Accept, recv, send, close, keepalive. No connection-per-IP limits yet.

**Completion criteria:**
- [ ] TCP accept works on both io_uring and kqueue
- [ ] Keepalive connections survive multiple request cycles
- [ ] Connection pool recycles slots correctly
- [ ] Two-arena model works (conn_arena persists, req_arena resets)
- [ ] Zero per-connection allocations in steady state

**Journal entry format:** `[DATE] Phase 6.N: <one-liner>`

---

### Phase 7: HTTP/1.1 and TLS (Level 7)

**Goal:** Parse HTTP/1.1 requests, serialize responses, terminate TLS, and prevent request smuggling.

**Dependencies:** Phase 6 complete (TCP).

**Files:**
- `src/net/http1.zig`
- `src/net/tls.zig`
- `src/net/smuggling.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Model HTTP parser state machine. Properties: every byte sequence either parses to a valid request or produces an error — no ambiguous states.
2. **Unit tests:**
   - `http1.zig`: Parse GET, POST, PUT, DELETE, PATCH. Parse headers (case-insensitive, inline lowercasing). Content-Length body. Chunked transfer encoding. Partial reads (FakeReader pattern — random byte boundaries). Malformed requests (missing CRLF, bad method, truncated headers). Max header size enforcement. Max URI length. Keepalive: parse multiple requests on one connection.
   - `tls.zig`: TLS 1.2 handshake. TLS 1.3 handshake. ALPN negotiation. Certificate loading. Invalid cert → error. Self-signed cert in test mode.
   - `smuggling.zig`: CL/TE conflict → reject. TE/CL conflict → reject. Duplicate Content-Length → reject. Transfer-Encoding with non-chunked values → reject. Reference: design.md §2.3 (Kettle's 2025 research).
3. **Benchmarks:**
   - Parse throughput: requests/sec for a typical GET request. Compare to picohttpparser, llhttp. Target: competitive with picohttpparser (>2M req/sec on single core). Reference: design.md §2.3 (SIMD-accelerated parsing).
   - Response serialization: bytes/sec. IOVec writes (header + body in single writev syscall). Reference: `refs/http.zig/INSIGHTS.md` §11 (IOVec).
4. **Memory verification:** Parser operates on pre-allocated buffers. Zero allocation per request. ASan on header parsing edge cases.
5. **VOPR simulation:** FakeIO delivers random byte fragments. Parser must handle every possible byte boundary without corruption.
6. **UAT:** `curl` to a running server. Verify correct responses. `curl -v` to inspect headers.
7. **Conformance:** Not yet (Autobahn etc. are for WebSocket/H2). But run testssl.sh against TLS endpoint.

**Implementation notes:**
- `http1.zig`: Integer-cast method matching (`@bitCast(buf[0..4].*)`). Inline header lowercasing. Incremental state-machine parser (nullable fields as implicit state). Reference: `refs/http.zig/INSIGHTS.md` §1. Comptime status line generation. Pre-computed Content-Type header lines. Reference: `refs/http.zig/INSIGHTS.md` §11.
- `tls.zig`: OpenSSL via `@cImport`. Static linking. `SSL_CTX_set_min_proto_version` for TLS 1.2 minimum. Reference: design.md §2.2.
- `smuggling.zig`: Strict CL/TE validation per Kettle's research. Reject any request with both Content-Length and Transfer-Encoding. Reference: design.md §2.3.
- Known pitfall: Inline `std.debug.assert` in hot paths has 15-20% overhead even in ReleaseFast (Ghostty finding). Use `snek_assert` from Phase 0 which compiles to nothing in release.
- SIMD scanning deferred until benchmarks show it matters. Start with scalar parser.
- FakeReader pattern from `refs/http.zig/INSIGHTS.md` §12: randomly fragment reads to stress the incremental parser.

**Completion criteria:**
- [ ] Parser handles all HTTP methods, headers, bodies
- [ ] Chunked encoding works (both receive and send)
- [ ] Request smuggling vectors are rejected
- [ ] TLS 1.2 and 1.3 handshake works
- [ ] ALPN negotiation works
- [ ] IOVec response writes confirmed via strace
- [ ] FakeReader fuzz test passes (1M random fragmentations)
- [ ] testssl.sh passes against TLS endpoint

**Journal entry format:** `[DATE] Phase 7.N: <one-liner>`

---

### Phase 8: HTTP Router and Request/Response (Level 8)

**Goal:** Implement the compiled radix trie router, request/response types, and cookie handling.

**Dependencies:** Phase 7 complete (HTTP parser).

**Files:**
- `src/http/router.zig`
- `src/http/request.zig`
- `src/http/response.zig`
- `src/http/cookies.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Not applicable (stateless lookup).
2. **Unit tests:**
   - `router.zig`: Static routes match. Parameterized routes extract params. Catch-all routes. Static priority over param (`/users/me` beats `/users/{id}`). Route conflict detection. HEAD auto-generated from GET. OPTIONS auto-generated. 405 with Allow header. Named routes. List routes for CLI. Comptime router (if routes known at comptime).
   - `request.zig`: Parse query string (lazy). Parse form data (lazy). Path param type coercion (string → int/float). Multipart parsing (streaming, callback-driven). Content-Type auto-detection.
   - `response.zig`: JSON response. Text response. HTML response. Redirect. Custom status + headers. Streaming response (SSE-style).
   - `cookies.zig`: Parse Cookie header. Set-Cookie with attributes (Secure, HttpOnly, SameSite, Max-Age). HMAC-signed cookies (key from config).
3. **Benchmarks:**
   - Router match: target 2.45μs per match with 130 routes (matchit/axum benchmark). Reference: design.md §5.1.
   - Zero-copy path param extraction: params are slices into the original URL, no allocation.
4. **Memory verification:** Router is immutable after `compile()`. All route data allocated at startup via StaticAllocator. Zero allocation per match.
5. **VOPR simulation:** Not applicable (pure function).
6. **UAT:** Register 20 routes, match URLs manually, verify correct handlers and params.
7. **Conformance:** Not applicable.

**Implementation notes:**
- `router.zig`: Compressed radix trie. Per-method dispatch trees (7 trees). Children ordered by priority: static > param > catch_all. Reference: `refs/http.zig/INSIGHTS.md` §3 (trie routing), design.md §5.1 (matchit target).
- `request.zig`: State/View separation — `Request.State` owns buffers, `Request` is the user-facing view. Lazy query/form parsing with boolean guards. Reference: `refs/http.zig/INSIGHTS.md` §2.
- `response.zig`: Pre-computed content-type header lines at comptime. `writeInt` optimization for Content-Length. Reference: `refs/http.zig/INSIGHTS.md` §11.
- `cookies.zig`: HMAC-SHA256 signing using Zig's `std.crypto.auth.hmac`. Reference: design.md §4.3.
- Minimum viable: JSON + text responses. Streaming responses deferred to Phase 9.

**Completion criteria:**
- [ ] Router matches 130 routes in <3μs
- [ ] Static priority over param verified
- [ ] Conflict detection catches overlapping routes
- [ ] HEAD/OPTIONS auto-generation works
- [ ] Zero-copy param extraction verified
- [ ] Cookie parsing and HMAC signing work
- [ ] Router is immutable after compile (no mutation possible)

**Journal entry format:** `[DATE] Phase 8.N: <one-liner>`

---

### Phase 9: HTTP Features (Level 9)

**Goal:** Add compression, validation (schema compiler), middleware, and JSON codec.

**Dependencies:** Phase 8 complete (router, request, response).

**Files:**
- `src/http/compress.zig`
- `src/http/validate.zig`
- `src/http/middleware.zig`
- `src/json/parse.zig`
- `src/json/serialize.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Not applicable.
2. **Unit tests:**
   - `compress.zig`: gzip compress/decompress round-trip. Brotli compress/decompress round-trip. Content-type filtering (only text/json/html/css/js). Minimum threshold (1KB). Pre-compressed file detection (.br/.gz).
   - `validate.zig`: Compile schema from type annotations. Validate int constraints (Gt, Ge, Lt, Le). String constraints (MinLen, MaxLen, Pattern, Email). Nested model validation. Array constraints (MaxLen, UniqueItems). Union validation. Optional fields. Invalid input → detailed error JSON.
   - `middleware.zig`: Zig-side middleware chain (request ID, timing, CORS — zero Python). Python-side middleware hooks (before_request, after_request). Wrapping middleware (call_next). Middleware ordering. Short-circuit (auth failure returns 401, skips handler).
   - `json/parse.zig`: Parse object, array, string, number, boolean, null. Nested objects. Arrays of objects. Unicode escapes. Max nesting depth enforcement. Duplicate keys → last wins. NaN/Infinity → reject.
   - `json/serialize.zig`: Dict → JSON. List → JSON array. Nested. Custom types (datetime → ISO 8601, UUID → string). PgRowSerializer: DB row → JSON without Python. PyObjectSerializer: Python object → JSON bypassing Python's json module.
3. **Benchmarks:**
   - JSON parse: compare to `std.json`, simdjson, orjson. Target: orjson-level performance. Reference: design.md §9 (yyjson as reference).
   - Validation: fused decode+validate vs separate decode then validate. Target: 10-100x faster than interpreted validation (msgspec finding). Reference: design.md §3.5.
   - Compression: gzip/brotli throughput. Compare to Python's gzip module.
4. **Memory verification:** JSON parser operates on pre-allocated buffers. Validator uses arena allocation. Zero allocation for validation errors (pre-allocated error buffer).
5. **VOPR simulation:** Not applicable.
6. **UAT:** Send a malformed JSON body, verify 400 response with structured errors.
7. **Conformance:** Not applicable yet.

**Implementation notes:**
- `compress.zig`: Use Zig's `std.compress` (merged from ianic/flate, 395KB fixed memory, no allocator needed). Brotli via C dep or Zig port. Reference: design.md §4.4.
- `validate.zig`: Fused decode+validate — parse JSON and validate constraints in a single pass. Schema compiled at import time from Python annotations (Phase 13 will connect this). Reference: design.md §3.5 (msgspec pattern).
- `middleware.zig`: Two-tier model. Zig-side middleware is comptime-compiled (like http.zig's executor pattern). Python-side is hook-based. Reference: design.md §6.1, `refs/http.zig/INSIGHTS.md` §10 (middleware executor).
- `json/parse.zig`: Start with `std.json` zero-copy token slices. Add SIMD structural scanning later if benchmarks demand it. Reference: design.md §9.1.
- Minimum viable for this phase: JSON parse/serialize, gzip compression, basic validation. SIMD and brotli are optimization.

**Completion criteria:**
- [ ] JSON parse/serialize round-trips correctly
- [ ] Fused decode+validate works for nested models
- [ ] Validation errors are detailed JSON
- [ ] gzip compression works with threshold
- [ ] Zig-side middleware chain executes in correct order
- [ ] Middleware short-circuit works

---

**MILESTONE: snek serves "hello world" over HTTP.** Integration test: start scheduler with FakeIO (or real io_uring), register one route, send HTTP request, receive JSON response. Validated by `example/hello/` — the minimal app with just routing and JSON responses.

---

### Phase 10: Database Authentication and Wire Protocols (Level 10)

**Goal:** Implement Postgres wire protocol, auth (SCRAM, md5), and Redis RESP3 protocol.

**Dependencies:** Phase 5 complete (scheduler — for I/O). Independent of Phases 6-9 (HTTP path).

**Files:**
- `src/db/auth.zig`
- `src/db/wire.zig`
- `src/redis/protocol.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Model Postgres connection state machine (SSL negotiation → StartupMessage → Authentication → ReadyForQuery). Properties: every state has a defined next state or error; no stuck states.
2. **Unit tests:**
   - `auth.zig`: SCRAM-SHA-256 full handshake (client nonce → server challenge → client proof → server signature). MD5 auth with salt. Trust auth (no password). Invalid password → error.
   - `wire.zig`: Extern struct size assertions (already in stub — `@sizeOf(MessageHeader) == 5`, etc.). Serialize StartupMessage, parse AuthenticationOk, parse ErrorResponse, parse RowDescription, parse DataRow. Simple query round-trip (against FakeIO mock Postgres). Extended query: Parse/Bind/Execute/Sync. SSL negotiation.
   - `redis/protocol.zig`: RESP3 encode/decode. Simple string, error, integer, bulk string, array, null, map, set, double, boolean, big number, verbatim string, push. Inline commands. Pipeline encoding (multiple commands in one write).
3. **Benchmarks:**
   - Wire protocol parse: DataRow parsing throughput. Compare to asyncpg's Cython parser (1M+ rows/sec target). Reference: `src/db/REFERENCES.md` §2.2 (asyncpg benchmarks).
   - RESP3 parse: compare to hiredis parser.
4. **Memory verification:** All wire message structs are `extern struct` with `comptime { assert(@sizeOf(...) == N); assert(noPadding(...)); }`. Reference: `refs/tigerbeetle/INSIGHTS.md` §9 (extern struct + no_padding).
5. **VOPR simulation:** FakeIO simulates Postgres server responses. Inject: connection reset during auth, malformed backend messages, partial reads.
6. **UAT:** Connect to a real Postgres instance, authenticate, send a simple query, print rows. Same for Redis.
7. **Conformance:** Not applicable (protocol conformance is tested by connecting to real servers).

**Implementation notes:**
- `wire.zig`: Generic-over-IO (`WireConnectionType(comptime IO: type)`). Already stubbed. All message types as `extern struct` with comptime size assertions. Zero-copy result parsing: slices into read buffer (pg.zig pattern). Reference: `src/db/REFERENCES.md` §2.4 (pg.zig), §1 (protocol v3 message flow).
- `auth.zig`: SCRAM-SHA-256 per RFC 5802. Use `std.crypto.hash.sha2.Sha256` and `std.crypto.auth.hmac.sha2.HmacSha256`. MD5 via `std.crypto.hash.Md5`. Reference: `src/db/REFERENCES.md` §7 (SCRAM-SHA-256 authentication).
- `redis/protocol.zig`: RESP3 is simpler than Postgres wire protocol. Reference: Redis protocol spec.
- Known pitfall: Postgres messages can be arbitrarily large (COPY data, large results). Need streaming for large messages — don't try to buffer entire messages.

**Completion criteria:**
- [ ] All extern struct sizes verified at comptime
- [ ] SCRAM-SHA-256 handshake works against real Postgres
- [ ] MD5 auth works
- [ ] Extended query protocol (Parse/Bind/Execute/Sync) works
- [ ] SSL negotiation works
- [ ] RESP3 encodes/decodes all types correctly
- [ ] Zero-copy DataRow parsing verified

**Journal entry format:** `[DATE] Phase 10.N: <one-liner>`

---

### Phase 11: Database Features and Redis Client (Level 11)

**Goal:** Implement type mapping, query interface, connection pools, notifications, schema validation, and the full Redis client.

**Dependencies:** Phase 10 complete (wire protocols).

**Files:**
- `src/db/types.zig`
- `src/db/query.zig`
- `src/db/pipeline.zig`
- `src/db/pool.zig`
- `src/db/notify.zig`
- `src/db/schema.zig`
- `src/redis/connection.zig`
- `src/redis/pool.zig`
- `src/redis/commands.zig`
- `src/redis/pubsub.zig`
- `src/redis/lua.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Model connection pool: N connections, M concurrent borrowers. Properties:
   - **No double-borrow:** A connection is never lent to two borrowers simultaneously.
   - **No leak:** Every borrowed connection is eventually returned or the pool detects the leak.
   - **Bounded wait:** If pool is exhausted, waiters are served FIFO when connections return.
   - **Health check:** Unhealthy connections are replaced, not returned to borrowers.
2. **Unit tests:**
   - `types.zig`: Postgres → Zig type mapping for all supported types (int4→i32, int8→i64, float4→f32, float8→f64, text→[]const u8, bool→bool, timestamp→i64, json→parsed JSON, uuid→[16]u8, array→slice, bytea→[]u8). Binary format parsing for each.
   - `query.zig`: Parameter binding ($1, $2, ...). Prepared statement caching (LRU). Query timeout. Transaction support (BEGIN/COMMIT/ROLLBACK).
   - `pipeline.zig`: Send multiple queries without waiting for responses. Verify all responses arrive in order. Error mid-pipeline → remaining queries still return errors.
   - `pool.zig`: Borrow/return cycle. Pool exhaustion → waiter queue. Health check on borrow. Background ping. Reconnect on failure. Pool sizing: `(cores * 2) + 1` default.
   - `notify.zig`: LISTEN on a channel. Receive NOTIFY payload. Dedicated connection outside pool. Reconnect after connection drop. Buffered fan-out with overflow discard.
   - `schema.zig`: Parse schema.sql. Validate queries against schema at startup. Detect missing tables/columns.
   - `redis/commands.zig`: GET, SET, DEL, EXISTS, EXPIRE, TTL, INCR, HGET, HSET, LPUSH, LPOP, SADD, SMEMBERS, ZADD, ZRANGE.
   - `redis/pubsub.zig`: SUBSCRIBE, PUBLISH, UNSUBSCRIBE. Message delivery to subscribers. Pattern subscriptions (PSUBSCRIBE).
   - `redis/lua.zig`: EVAL with keys and args. EVALSHA. SCRIPT LOAD.
3. **Benchmarks:**
   - Query throughput: queries/sec single connection. Compare to asyncpg (1M rows/sec). Reference: `src/db/REFERENCES.md` §2.2.
   - Pipeline: measure speedup vs non-pipelined. Target: up to 71x on high-latency connections. Reference: design.md §7.1.
   - Pool: borrow/return latency. Compare to HikariCP (250ns avg). Reference: `src/db/REFERENCES.md` §5.3.
   - Redis: commands/sec. Compare to hiredis baseline.
4. **Memory verification:** Pool connections pre-allocated at startup. Statement cache uses arena. No allocation per query.
5. **VOPR simulation:** FakeIO simulates: connection drops mid-query, slow Postgres responses, pool exhaustion under load, NOTIFY delivery with random delays. Reference: `refs/tigerbeetle/INSIGHTS.md` §2 (fault injection).
6. **UAT:** Connect to real Postgres, run queries, verify results. Connect to real Redis, run commands.
7. **Conformance:** Not applicable.

**Implementation notes:**
- `pool.zig`: Pool sizing from Little's Law: `connections = rate × duration`. Default `(cores * 2) + 1`. Health check on borrow + periodic background ping. Reference: `src/db/REFERENCES.md` §14 (pool sizing), design.md §7.2.
- `notify.zig`: Notifier pattern from `docs/GAPS_RESEARCH.md` §3 (Brandur's pattern). One dedicated connection per process. Buffered channels per subscriber. Non-blocking sends. Auto-reconnect with re-LISTEN.
- `pipeline.zig`: Protocol pipelining — send Parse/Bind/Execute for multiple queries before any Sync. Collect all responses. Reference: `src/db/REFERENCES.md` §9.
- `types.zig`: Binary format by default for numeric/timestamp/array. Text for varchar. Cache entire decode pipeline per prepared statement (asyncpg pattern). Reference: `src/db/REFERENCES.md` §2.2.
- `schema.zig`: Parse CREATE TABLE statements from schema.sql. Build column type map. At startup, validate all registered queries against this map.
- Minimum viable: Simple queries, prepared statements, pool, basic types. Pipeline and NOTIFY can follow.

**Completion criteria:**
- [ ] TLA+ model verifies pool safety (no double-borrow, no leak)
- [ ] All Postgres types parse correctly from binary format
- [ ] Prepared statement caching works (LRU eviction)
- [ ] Pipeline mode delivers speedup
- [ ] Pool borrow/return works under concurrency
- [ ] NOTIFY delivers to subscribers
- [ ] All Redis command types work
- [ ] Pub/sub message delivery works
- [ ] Schema validation catches invalid queries at startup

---

**MILESTONE: Postgres and Redis work standalone.** Integration test: scheduler + TCP + wire protocol → execute queries, receive results, subscribe to notifications.

---

### Phase 12: Python FFI Bridge (Level 12)

**Goal:** Build the three-layer CPython C API bridge and GIL management.

**Dependencies:** Phase 9 (HTTP) + Phase 11 (DB/Redis) complete.

**Files:**
- `src/python/ffi.zig`
- `src/python/gil.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Model GIL acquire/release interleaved with I/O operations. Properties:
   - **Mutual exclusion:** Only one thread holds the GIL at any time.
   - **No deadlock:** GIL release before I/O + reacquire after never deadlocks.
   - **Progress:** Every Python call eventually acquires the GIL.
2. **Unit tests:**
   - `ffi.zig`: Create a Python module. Define a method. Call it from Zig. Return a value. Error handling: Python exception → Zig error. Reference counting: incref/decref lifecycle. Buffer protocol. Comptime function wrapper (Zig fn → CPython callable with automatic error conversion).
   - `gil.zig`: Acquire GIL, call Python, release GIL, verify another thread can acquire. GIL cycling latency measurement. Long-held GIL warning (>100ms).
3. **Benchmarks:**
   - GIL acquire/release latency: target ~50-100ns. Reference: design.md §3.2 (per I/O operation granularity recommendation).
   - FFI call overhead: Zig → Python → Zig round-trip. Compare to Cython call overhead.
4. **Memory verification:** Verify Python reference counting is correct — no leaks detected by Python's `gc.collect()` + `gc.get_referrers()`.
5. **VOPR simulation:** Simulate GIL contention: multiple coroutines competing for GIL, random hold durations. Verify no deadlock.
6. **UAT:** From a running snek process, call a Python function, print the result. Verify with Python's `sys.getrefcount()`.
7. **Conformance:** Not applicable.

**Implementation notes:**
- `ffi.zig`: Three-layer pattern (already stubbed). Layer 1: raw `@cImport` bindings. Layer 2: PyObject operations with refcount helpers (`Py_INCREF`, `Py_DECREF`, `Py_XDECREF`). Layer 3: comptime function wrapper — converts Zig error unions to `PyErr_SetString`. Reference: design.md §3.1 (Bun's C++→C extern→Zig pattern).
- `gil.zig`: `PyGILState_Ensure()` / `PyGILState_Release()`. Acquire per I/O operation, release on suspend. Reference: design.md §3.2.
- Build: `@cImport(@cInclude("Python.h"))`. Link against libpython3.12+. abi3 stable ABI.
- Known pitfall: Python objects allocated during request handling are GC-managed, not arena-managed. Clear ownership boundary: Zig owns buffers, Python owns objects.

**Completion criteria:**
- [ ] CPython module loads successfully
- [ ] Zig can call Python functions and get return values
- [ ] Python exceptions propagate to Zig as errors
- [ ] GIL acquire/release works without deadlock
- [ ] Reference counting is correct (no leaks)
- [ ] Comptime function wrapper generates correct CPython callables
- [ ] abi3 stable ABI targeting 3.12+ works

**Journal entry format:** `[DATE] Phase 12.N: <one-liner>`

---

### Phase 13: Python Integration (Level 13)

**Goal:** Connect Python handlers to the Zig runtime — coroutine driving, type coercion, DI, module init, and request context.

**Dependencies:** Phase 12 complete (FFI + GIL).

**Files:**
- `src/python/coerce.zig`
- `src/python/driver.zig`
- `src/python/module.zig`
- `src/python/context.zig`
- `src/python/inject.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Model coroutine driving protocol: Zig calls `coro.send()` → Python yields sentinel → Zig intercepts → submits I/O → Zig calls `coro.send(result)` → Python continues. Properties: every sentinel is eventually resolved; every coroutine terminates or is cancelled.
2. **Unit tests:**
   - `coerce.zig`: Build validation schema from Python `Annotated` types. Convert Python int → Zig i64. Python str → Zig slice. Python dict → request body. Path param coercion: `"{id}"` with `id: int` annotation → parse to i64.
   - `driver.zig`: Drive a simple `async def handler(req)` that returns a dict. Drive a handler that `await`s a `db.fetch()` sentinel — intercept, return mock result, verify handler completes. Drive a handler that raises an exception — verify 500 response.
   - `module.zig`: `_snek` module initialization. Register routes from `@app.route` decorators. Expose `app.db`, `app.redis`, `app.http` proxy objects.
   - `context.zig`: Create per-request Context. Set `req.state` from middleware. Access `req.id`, `req.user`, `req.trace`. Python `contextvars` integration.
   - `inject.zig`: Register injectable with scope (singleton/request/transient). Resolve dependency graph at startup. Detect circular deps. Override for testing. Yield-based lifecycle (async generators for setup/teardown).
3. **Benchmarks:**
   - Coroutine driving overhead: measure time from `coro.send()` to sentinel interception and back. Target: <1μs per round-trip (Zig side only).
   - Schema compilation: measure time to compile a 20-field model. Should be <1ms (done once at import).
   - DI resolution: per-request injectable creation. Target: <100ns per injectable.
4. **Memory verification:** Verify Python objects created during schema compilation are properly reference-counted. Verify per-request context is cleaned up.
5. **VOPR simulation:** Drive coroutines with FakeIO. Random sentinel types, random delays, random exceptions. Verify all coroutines complete or error cleanly.
6. **UAT:** Write a Python handler with route decorator, DI, and type annotations. Start snek. Make a request. Verify the full pipeline works.
7. **Conformance:** Not applicable.

**Implementation notes:**
- `driver.zig`: The coroutine driving protocol is snek's intellectual successor to curio's trap-based kernel. `coro.send(None)` starts the handler. When the handler `await`s a snek awaitable, it yields a sentinel object. Zig inspects the sentinel type (DbQuery, RedisOp, HttpOp, Sleep, etc.), submits the corresponding I/O, and on completion calls `coro.send(result)`. Reference: design.md §3.3.
- `coerce.zig`: Inspect Python `__annotations__` dict. Walk `typing.Annotated` metadata for constraints. Compile to Zig validation schema (used by `http/validate.zig` from Phase 9). Reference: design.md §3.5.
- `inject.zig`: Three scopes: singleton (app lifetime), request (per-request), transient (per-injection). Graph validated at startup. Reference: design.md §3.6 (ASP.NET Core as gold standard, Dishka as Python prior art).
- `module.zig`: `PyInit__snek` entry point. Create module, register methods, expose proxy objects.
- Known pitfall: Python `Annotated` type introspection requires navigating `typing.get_type_hints()` with `include_extras=True`. This is CPython API, not Zig-native.

**Completion criteria:**
- [ ] Python handlers are driven by Zig coroutine protocol
- [ ] Sentinel interception works for db.fetch, redis.get, http.get, sleep
- [ ] Type coercion from Python annotations works
- [ ] Fused decode+validate works end-to-end
- [ ] DI graph validates at startup (circular deps caught)
- [ ] DI override for testing works
- [ ] Request context propagates through middleware and handlers
- [ ] `_snek` module initializes and routes register

---

**MILESTONE: snek runs Python handlers.** Integration test: `app = snek.App()` → `@app.route("GET", "/")` → handler returns dict → snek serves JSON response. Validated by `example/db_basic/` — routing plus a single DB query.

---

### Phase 14: Production Features (Level 14)

**Goal:** Add security, configuration, observability, static file serving, and outbound HTTP client.

**Dependencies:** Phase 13 complete (Python integration).

**Files:**
- `src/security/cors.zig`
- `src/security/headers.zig`
- `src/security/jwt.zig`
- `src/config/toml.zig`
- `src/config/env.zig`
- `src/observe/log.zig`
- `src/observe/metrics.zig`
- `src/observe/health.zig`
- `src/observe/trace.zig`
- `src/serve/static.zig`
- `src/serve/client.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Not applicable.
2. **Unit tests:**
   - `cors.zig`: Pre-rendered CORS headers at startup. Preflight response (OPTIONS). Origin matching (wildcard vs explicit). Credentials support. Max-age. Reference: design.md §12.1 (TurboAPI pattern: 0% overhead).
   - `headers.zig`: X-Content-Type-Options: nosniff. X-Frame-Options: DENY. HSTS (if TLS). CSP (configurable).
   - `jwt.zig`: HS256 sign/verify. RS256 verify (public key). ES256 verify. JWKS endpoint fetching + caching. Expired token rejection. Invalid signature rejection.
   - `config/toml.zig`: Parse snek.toml with all sections from design.md §14.1. Type coercion (string "10mb" → bytes). Default values. OAuth provider config (`[oauth.*]` named sections).
   - `config/env.zig`: `${VAR_NAME}` interpolation. `.env` file loading (dev mode). Missing required env var → startup error.
   - `observe/log.zig`: Structured JSON logging. Access log. Configurable level per subsystem.
   - `observe/metrics.zig`: Prometheus-compatible endpoint. Request count, latency histogram, error rate, pool stats.
   - `observe/health.zig`: Health endpoint from config. DB reachability check. Custom Python health checks.
   - `observe/trace.zig`: Request ID generation. W3C traceparent propagation.
   - `serve/static.zig`: Serve files from directory. ETag/If-None-Match → 304. Content-Type from extension. Pre-compressed .br/.gz files. No directory listing.
   - `serve/client.zig`: Outbound GET/POST. Connection pooling per host. Timeouts. TLS verification. Redirect following.
3. **Benchmarks:**
   - CORS: verify 0% overhead (pre-rendered headers). Reference: design.md §6.1 (TurboAPI pattern).
   - JWT: HS256 verify throughput. Compare to PyJWT.
   - Static files: throughput via sendfile/io_uring. Compare to nginx for same file.
   - HTTP client: requests/sec to external endpoint. Compare to httpx (Python).
4. **Memory verification:** All config parsed at startup. CORS headers allocated once. JWT keys cached.
5. **VOPR simulation:** Not applicable for most. Client: simulate slow external servers, connection drops.
6. **UAT:** Configure snek.toml, start server, verify CORS headers, JWT auth, health endpoint, static files.
7. **Conformance:** Not applicable.

**Implementation notes:**
- `cors.zig`: Pre-render all CORS headers at startup as byte slices. On OPTIONS preflight, memcpy the pre-rendered response. Reference: design.md §6.1.
- `jwt.zig`: Zig-native decode + verify. `std.crypto` for HMAC (HS256), RSA (RS256), ECDSA (ES256). JWKS fetching via `serve/client.zig`.
- `config/toml.zig`: Parse TOML using Zig. Minimal parser — snek.toml is flat sections, no deeply nested structures.
- `serve/static.zig`: `io_uring` splice/sendfile for zero-copy file serving. ETag from file mtime + size hash.
- `serve/client.zig`: Fiber-aware HTTP client using the same io_uring/kqueue backend. Connection pool per host. Reference: design.md §8.1.
- Minimum viable: CORS, security headers, TOML config, structured logging, health check, static files. JWT, metrics, tracing, and HTTP client can follow.

**Completion criteria:**
- [ ] snek.toml parsed correctly with all sections
- [ ] Environment variable interpolation works
- [ ] CORS pre-rendered headers have zero per-request overhead
- [ ] JWT HS256/RS256 verification works
- [ ] Health endpoint responds correctly
- [ ] Static files served with correct Content-Type and ETag
- [ ] Structured JSON logging works
- [ ] HTTP client makes outbound requests
- [ ] Prometheus metrics endpoint works
- [ ] OAuth provider config parsed from snek.toml `[oauth.*]` sections
- [ ] OAuth authorization code flow works end-to-end (GitHub, Google)

**Journal entry format:** `[DATE] Phase 14.N: <one-liner>`

---

### Phase 15: CLI and Advanced Protocols (Level 15)

**Goal:** Implement the CLI entry point, HTTP/2, and WebSocket support.

**Dependencies:** Phase 14 complete (production features).

**Files:**
- `src/cli/main.zig`
- `src/cli/commands.zig`
- `src/net/http2.zig`
- `src/net/websocket.zig`

**Verification protocol:**
1. **TLA+ / Formal modeling:** Model WebSocket connection state machine (HTTP upgrade → Open → Closing → Closed). Model HTTP/2 stream lifecycle (idle → open → half-closed → closed).
2. **Unit tests:**
   - `cli/main.zig`: Parse `snek run app:module`. Parse `snek db create/migrate/rollback/status/diff/reset`. Parse `snek routes`. Parse `snek check`. Parse `snek version`. `--reload`, `--port`, `--host`, `--workers` flags.
   - `cli/commands.zig`: Each command dispatches correctly. `snek routes` lists all registered routes. `snek check` validates config + schema.
   - `net/http2.zig`: HPACK encode/decode. Stream multiplexing. Flow control. SETTINGS frame. GOAWAY for graceful shutdown. Priority handling. h2c (cleartext HTTP/2). Server push NOT implemented (dead feature).
   - `net/websocket.zig`: Upgrade handshake. Frame parsing (text, binary, ping, pong, close). Masking/unmasking (SIMD or word-size ops). Fragment reassembly. permessage-deflate. Close handshake. Max frame/message size enforcement.
3. **Benchmarks:**
   - WebSocket masking: target 3x gorilla/websocket via SIMD. Reference: design.md §2.6 (coder/websocket SSE2 assembly).
   - HTTP/2: streams/sec. Compare to h2 (Python). Measure HPACK compression ratio.
4. **Memory verification:** WebSocket deflate contexts: 32KB window per connection. Track total memory. Reference: design.md §2.6 (Node's ws library fragmentation finding).
5. **VOPR simulation:** WebSocket: simulate mid-frame disconnects, malformed frames, slow clients. HTTP/2: simulate stream reset, flow control pressure, GOAWAY.
6. **UAT:** `snek run app:app` starts the server. WebSocket echo server works with browser console. HTTP/2 works with `curl --http2`.
7. **Conformance:**
   - **Autobahn TestSuite** for WebSocket RFC 6455. Must pass all cases.
   - **h2spec** for HTTP/2. Must pass all applicable cases.
   - **testssl.sh** for TLS (re-run from Phase 7).

**Implementation notes:**
- `cli/main.zig`: Zig argument parser. Import Python module specified by user (`app:module` → `import app; app = getattr(module, 'app')`).
- `net/http2.zig`: HPACK with dynamic table. Stream mux with priority. Flow control windows. GOAWAY for graceful shutdown. Reference: design.md §2.4, RFC 7540/7541.
- `net/websocket.zig`: Frame-level parsing. Masking via `@Vector` or word-size XOR. permessage-deflate with configurable window size. Reference: design.md §2.6.
- Dev mode (`--reload`): Use Zig's `fs/watch.zig` for file watching. Full process restart (not module reload). Reference: `docs/GAPS_RESEARCH.md` §1.
- Minimum viable: CLI + WebSocket. HTTP/2 can follow.

**Completion criteria:**
- [ ] `snek run app:app` starts the server and serves requests
- [ ] `snek routes` lists all registered routes
- [ ] `snek check` validates config and schema
- [ ] WebSocket passes Autobahn TestSuite
- [ ] HTTP/2 passes h2spec
- [ ] permessage-deflate works
- [ ] Dev mode file watching + restart works

---

**MILESTONE: snek is production-usable.** Full server with CLI, HTTP/1.1+2, WebSocket, Python handlers, DB, Redis, auth, config, logging, metrics.

---

### Phase 16: Testing Infrastructure and Python Package (Level 16)

**Goal:** Build simulation testing (VOPR), the full-stack test client, conformance infrastructure, and the Python-facing package.

**Dependencies:** Phase 15 complete (CLI, protocols).

**Files:**
- `src/testing/simulation.zig`
- `src/testing/client.zig`
- `src/testing/fake_client.zig`
- `src/testing/conformance.zig`
- `python/snek/__init__.py`
- `python/snek/models.py`
- `python/snek/di.py`
- `python/snek/context.py`
- `python/snek/responses.py`
- `python/snek/exceptions.py`
- `python/snek/background.py`
- `python/snek/openapi.py`
- `python/snek/docs.py`
- `python/snek/docs_ui.py`

**Verification protocol:**
1. **TLA+ / Formal modeling:** The VOPR simulation IS the verification. Run thousands of seeds in CI.
2. **Unit tests:**
   - `simulation.zig`: Full VOPR — scheduler + connections + Python coroutines + DB pool, all driven by FakeIO with a single seed. Fault injection: network drops, slow I/O, GIL contention, connection resets. Verify: no leaked connections, no stuck coroutines, graceful shutdown works under faults. Swarm testing: randomize fault parameters per seed.
   - `client.zig` (TestClient): Full-stack integration test client. Spins up snek in-process, makes real HTTP requests over loopback. Use for integration and end-to-end tests — tests what you ship. Phase 16 conformance tests use this.
   - `fake_client.zig` (UnitTestClient): Internal development tool — not part of the public API. Lightweight test client that bypasses network and HTTP parsing. Used for unit-testing individual handlers in isolation during snek development. Not exported in `root.zig` testing namespace. Reference: `refs/http.zig/INSIGHTS.md` §10.
   - `conformance.zig`: Runner for Autobahn, h2spec, testssl.sh. Structured output. CI integration.
   - Python package: `snek.Model` base class with `model_validate`, `model_dump`, `model_json_schema`. Constraint types (`Gt`, `Ge`, `Lt`, `Le`, `MinLen`, `MaxLen`, `Pattern`, `Email`, `OneOf`, `UniqueItems`). `@app.injectable` decorator. `@app.route` decorator. `snek.Request`, `snek.Response`. Exception classes (`NotFound`, `BadRequest`, `Unauthorized`). Background tasks. OpenAPI 3.1 generation. Swagger UI + ReDoc endpoints.
3. **Benchmarks:**
   - VOPR throughput: simulated requests/sec. Target: >1M simulated requests/sec (1000x speedup over real I/O). Reference: `refs/tigerbeetle/INSIGHTS.md` §2 (3.3s simulation = 39min real-world).
   - Test client: overhead vs raw HTTP. Should be <5% overhead.
4. **Memory verification:** VOPR runs with leak detection enabled. Any leak → test failure with seed for reproduction.
5. **VOPR simulation:** This IS the VOPR.
6. **UAT:** Run the complete Python test suite. Run all conformance suites. Run VOPR with 10K seeds.
7. **Conformance:**
   - Autobahn TestSuite (WebSocket)
   - h2spec (HTTP/2)
   - testssl.sh (TLS)

**Implementation notes:**
- `simulation.zig`: Following TigerBeetle's VOPR architecture. Single-threaded, deterministic, PRNG-driven. `SEED -> PRNG -> (faults, timing, client behavior) -> deterministic execution`. Coverage marks verify that specific code paths are exercised. Reference: `refs/tigerbeetle/INSIGHTS.md` §2 (complete VOPR architecture).
- Python package: `snek.Model` is NOT Pydantic — it's snek's own base class with a Pydantic-compatible API surface. Validation happens in Zig. `model_validate` calls into `_snek` C extension. Reference: design.md §3.5.
- OpenAPI generation: Walk registered routes, extract type annotations, generate OpenAPI 3.1 spec. Constraint mapping from `Annotated` types to OpenAPI schema keywords. Reference: design.md §17.
- Docs UI: CDN-loaded Swagger UI at `/docs`, ReDoc at `/redoc`. Only in debug mode or when configured. Reference: design.md §17.
- Background tasks: Starlette-compatible API. Tasks are submitted to the scheduler's work queue after response is sent; any worker thread may execute them. Background tasks are not affine to the originating request's worker — they don't need access to the request's connection arenas. Task registry in Zig for shutdown drain. Reference: `docs/GAPS_RESEARCH.md` §2.

**Completion criteria:**
- [ ] VOPR runs 10K seeds without failures
- [ ] Coverage marks verify all critical code paths are exercised
- [ ] Full-stack test client works for all route types
- [ ] Autobahn TestSuite passes (all cases)
- [ ] h2spec passes (all applicable cases)
- [ ] testssl.sh passes
- [ ] `pip install snek` works
- [ ] `snek.Model` with `model_validate` / `model_dump` works
- [ ] DI with three scopes works
- [ ] OpenAPI 3.1 spec generated correctly
- [ ] Swagger UI and ReDoc serve correctly
- [ ] Background tasks run after response and drain on shutdown

---

**MILESTONE: snek is shippable.** Validated by `example/todos/` — the full showcase app exercising DI, Redis, JWT, OAuth, WebSocket, SSE, OpenAPI, and middleware.

---

## Integration Test Plan

Integration tests are run after completing each level of the DAG. Each test verifies that the new level works correctly with all levels below it.

### Integration 1: Core Runtime (after Phase 5)
- Scheduler starts with FakeIO, spawns coroutines, executes work across workers, shuts down cleanly.
- Backpressure: saturate workers, verify accept queue fills, verify TCP backlog absorbs.
- Graceful shutdown: submit long-running tasks, signal shutdown, verify tasks complete within timeout.

### Integration 2: TCP + HTTP (after Phase 9)
- Scheduler + TCP + HTTP parser + router + response serializer.
- Accept connection, parse HTTP request, route to handler, serialize JSON response, send, close.
- Keepalive: multiple requests on one connection.
- Compression: verify gzip response.
- Middleware: request ID header added by Zig-side middleware.

### Integration 3: Database Standalone (after Phase 11)
- Scheduler + TCP + Postgres wire protocol + pool.
- Open pool, borrow connection, execute query, return rows, return connection to pool.
- Pipeline: send 10 queries, receive 10 results.
- NOTIFY: subscribe to channel, trigger NOTIFY, receive payload.
- Redis: SET/GET, SUBSCRIBE/PUBLISH.

### Integration 4: Python Bridge (after Phase 13)
- Scheduler + TCP + HTTP + DB + Python.
- Python handler receives request, queries database via sentinel, returns JSON response.
- DI: injectable provides db_session, handler uses it.
- Validation: malformed JSON body → 400 with structured errors (never enters Python).
- Error: Python exception → 500 response.

### Integration 5: Full Stack (after Phase 15)
- CLI starts server from `snek run app:app`.
- HTTP/1.1, HTTP/2, WebSocket all work.
- CORS headers correct.
- JWT auth works.
- Static files served.
- Health endpoint responds.
- Metrics endpoint responds.
- Graceful shutdown works.

### Integration 6: Conformance (after Phase 16)
- All conformance suites pass (Autobahn, h2spec, testssl.sh).
- VOPR simulation passes 10K seeds.
- Python test suite passes.

---

## End-to-End Test Plan (The Final Boss)

This is the complete happy path that validates snek from `pip install` to production readiness.

### 1. Installation
```
pip install snek
```
- Installs the `_snek` C extension (abi3 wheel for CPython 3.12+).
- Installs the `snek` Python package.
- No compilation required for supported platforms (pre-built wheels).
- Source fallback compiles via setuptools-zig for exotic platforms.

### 2. Application Definition
```python
from snek import App, Model
from typing import Annotated

app = App()

class CreateUser(Model):
    name: Annotated[str, MinLen(1), MaxLen(100)]
    email: Annotated[str, Email()]
    age: Annotated[int, Ge(0), Lt(150)]

@app.injectable(scope="request")
async def db_session():
    async with app.db.transaction() as tx:
        yield tx

@app.before_request
async def auth_check(req):
    if req.path != "/health":
        token = req.headers.get("Authorization")
        if not token:
            raise snek.Unauthorized()

@app.route("GET", "/health")
async def health():
    return {"status": "ok"}

@app.route("POST", "/users")
async def create_user(body: CreateUser, db: db_session):
    user = await db.fetch_one(
        "INSERT INTO users (name, email, age) VALUES ($1, $2, $3) RETURNING *",
        body.name, body.email, body.age,
    )
    await app.redis.set(f"user:{user['id']}", user, ex=300)
    return user
```

### 3. Server Startup
```
snek run app:app
```
- Parses snek.toml (or uses defaults).
- Loads Python module, registers routes, compiles validation schemas.
- Validates DI graph (circular deps detected).
- Opens DB and Redis connection pools.
- Binds TCP socket, starts workers.
- Prints registered routes.

### 4. HTTP Requests
- `GET /health` → `{"status": "ok"}` (200)
- `POST /users` with valid JSON body → user created (201)
- `POST /users` with invalid JSON → structured 400 errors (never enters Python)
- `POST /users` without auth → 401
- Unknown route → 404
- Wrong method → 405 with Allow header

### 5. Database Operations
- Query executes via prepared statement cache.
- Binary format for result parsing.
- Pool recycles connections correctly.
- Transaction auto-commits on clean exit, auto-rollbacks on exception.

### 6. Redis Operations
- SET/GET works.
- TTL expiration works.
- Pub/sub message delivery works.

### 7. WebSocket
```python
@app.websocket("/ws/echo")
async def echo(ws):
    async for msg in ws:
        await ws.send(f"echo: {msg}")
```
- Upgrade handshake completes.
- Text and binary messages work.
- Ping/pong works.
- Close handshake completes cleanly.
- Autobahn TestSuite passes.

### 8. OpenAPI Documentation
- `GET /openapi.json` → valid OpenAPI 3.1 spec.
- `GET /docs` → Swagger UI (CDN-loaded).
- `GET /redoc` → ReDoc (CDN-loaded).
- Spec includes all routes, request/response models, constraints.

### 9. Graceful Shutdown
- `SIGTERM` → stop accepting → drain in-flight → close pools → exit.
- `SIGINT` → same with shorter timeouts.
- Double `SIGTERM` → immediate exit.
- WebSocket connections receive Close frame before shutdown.
- Background tasks complete within drain timeout.

### 10. Conformance Suites
- [ ] Autobahn TestSuite: all cases pass
- [ ] h2spec: all applicable cases pass
- [ ] testssl.sh: TLS 1.2 and 1.3, correct cipher suites, no vulnerabilities

### 11. Benchmark Targets
| Metric | Target | Reference |
|--------|--------|-----------|
| HTTP req/sec (hello world, 1 worker) | >200K | uvicorn+starlette baseline ~80K |
| HTTP req/sec (JSON response, 1 worker) | >150K | — |
| JSON parse throughput | orjson-level | design.md §9 |
| Router match (130 routes) | <3μs | matchit/axum: 2.45μs |
| DB query (single row) | >500K rows/sec | asyncpg: 1M rows/sec |
| WebSocket masking | >3x gorilla/websocket | design.md §2.6 |
| Coroutine frame size | <256 bytes | — |
| GIL acquire/release | <100ns | design.md §3.2 |
| Connection pool borrow | <500ns | HikariCP: 250ns |
| Memory per idle connection | <4KB | — |

---

## Implementation Journal

<!-- Format: [DATE] Phase N.M: <one-liner> -->

[2026-03-21] Phase 0.1: assert.zig — inline assert with zero overhead in ReleaseFast (Ghostty pattern), 2 tests passing
[2026-03-21] Phase 0.2: coverage.zig — mark/check/reset coverage marks with comptime hash (TigerBeetle pattern), 5 tests passing
[2026-03-21] Phase 0.3: static_alloc.zig — three-phase allocator (init→static→deinit) with vtable dispatch, 83 lines, 3 tests passing
[2026-03-21] Phase 0.4: pool.zig — HiveArray fixed-capacity bitset pool with O(n) scan + Fallback allocator, 3 tests passing
[2026-03-21] Phase 0.5: arena.zig — ConnArena + ReqArena pair with retain_with_limit reset, 3 tests passing
[2026-03-21] Phase 0: COMPLETE — all 5 foundation primitives implemented, 16 tests passing, zero leaks
[2026-03-21] Phase 1.1: deque.zig — Chase-Lev work-stealing deque, 7 tests + 7 edge cases, benchmarked 10x faster than mutex under contention (VERIFIED)
[2026-03-21] Phase 1.2: buffer.zig — ref-counted buffer pool, 5 tests + 7 edge cases, benchmarked vs arena (arena wins 1.1-3.8x, keep pool only for io_uring registered buffers)
[2026-03-21] Phase 1.3: timer.zig — flat-list timer with swap-remove, 4 tests + 6 edge cases, falsifiability deferred to profiling
[2026-03-21] Phase 1: COMPLETE — 3 data structures, 36 tests passing, 2 benchmarks run, zero leaks
[2026-03-21] Phase 2.1: io.zig — comptime IO interface with assertIsIoBackend validation, platform switch (Ghostty pattern), 5 tests
[2026-03-21] Phase 2.2: fake_io.zig — VOPR simulation backend, 210 lines, PRNG-driven, fault injection, seed-reproducible, 18 tests
[2026-03-21] Phase 2.3: signal.zig — atomic flag signal handler, SIGPIPE ignore, shutdown phase state machine, 9 tests
[2026-03-21] Phase 2: COMPLETE — IO abstraction + VOPR foundation + signal handling, 32 tests, zero bugs in UAT
[2026-03-21] Phase 3.1: io_uring.zig — thin adapter around std.os.linux.IoUring, NonLinuxStub for macOS, comptime interface check, 10 tests (5 Linux-gated)
[2026-03-21] Phase 3.2: kqueue.zig — readiness-to-completion adapter, ONESHOT kevents, ~200 lines, 13 tests on macOS. UAT caught silent OOM swallowing (catch {} → try)
[2026-03-21] Phase 3: COMPLETE (kqueue verified on macOS, io_uring compiles — Docker testing pending)
[2026-03-21] Phase 4.1: coroutine.zig — stackless state machine, CancellationToken, FrameQueue (intrusive), comptime Pipeline, 19 tests
[2026-03-21] Phase 4.2: worker.zig — WorkerThread(IO) with deque + futex park/wake, WorkerPool with real std.Thread, 13 tests. Found and fixed start/stop race via TLA+.
[2026-03-21] Phase 4.3: TLA+ model (specs/worker_lifecycle.tla) — verified 441,761 states with 4 workers. Safety: terminated workers never process. Liveness: stop always leads to termination, parked workers always wake.
[2026-03-21] Phase 4: COMPLETE — workers + coroutines, TLA+ verified, all tests pass on macOS + Linux
