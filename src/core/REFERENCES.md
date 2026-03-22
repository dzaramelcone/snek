# Scheduling & Runtime Systems: Design Reference

Exhaustive survey of state-of-the-art scheduling and runtime implementations across
high-performance systems languages. Last updated: 2026-03-21.

---

## Table of Contents

1. [Work-Stealing Schedulers](#1-work-stealing-schedulers)
2. [Stackless vs Stackful Coroutines](#2-stackless-vs-stackful-coroutines)
3. [io_uring-Based Event Loops](#3-io_uring-based-event-loops)
4. [Thread-Per-Core Architectures](#4-thread-per-core-architectures)
5. [Runtime Designs](#5-runtime-designs)
6. [Formal Verification of Concurrent Schedulers](#6-formal-verification-of-concurrent-schedulers)
7. [NUMA-Aware Scheduling](#7-numa-aware-scheduling)
8. [Adaptive Scheduling Strategies](#8-adaptive-scheduling-strategies)
9. [Cache-Friendly Task Queues](#9-cache-friendly-task-queues)
10. [Key Research Papers](#10-key-research-papers)
11. [Lessons & Design Principles](#11-lessons--design-principles)

---

## 1. Work-Stealing Schedulers

### 1.1 Theoretical Foundations

**Blumofe-Leiserson Bound (1999)**

The foundational result. For a fully-strict (fork-join) computation with work T1 and
span T_inf executed on P processors, a randomized work-stealing scheduler completes
in expected time:

    E[Tp] = T1/P + O(T_inf)

This is optimal to within a constant factor. The expected number of steal attempts is
O(P * T_inf), meaning communication overhead is proportional to the critical path, not
the total work.

- Paper: R.D. Blumofe, C.E. Leiserson. "Scheduling Multithreaded Computations by
  Work Stealing." JACM 46(5):720-748, 1999.
  https://dl.acm.org/doi/10.1145/324133.324234
- Proof technique: combinatorial "balls and bins" game bounding delay from random
  asynchronous accesses, combined with a delay-sequence argument.

**ABP Work-Stealing (Arora, Blumofe, Plaxton)**

The non-blocking work-stealing algorithm that became the practical standard. Models
computation as a DAG where each node is a strand (instruction sequence with no parallel
control). Key property: if a deque is non-empty, the head contains a constant fraction
of the potential in the deque, and after O(P) steal attempts, the critical node at the
head of some deque gets executed.

- Recent tighter bounds replace polynomial overhead terms with logarithmic factors.
- Paper: N.S. Arora, R.D. Blumofe, C.G. Plaxton. "Thread Scheduling for
  Multiprogrammed Multiprocessors." Theory of Computing Systems 34(2):115-144, 2001.

**Improved Analysis (Gu et al., 2021)**

Significantly tightened the bound on number of steals, with new parallel cache
complexity bounds using logarithmic rather than polynomial overhead terms.

- Paper: Y. Gu et al. "Analysis of Work-Stealing and Parallel Cache Complexity."
  arXiv:2111.04994, 2021. https://arxiv.org/pdf/2111.04994

### 1.2 Chase-Lev Deque

The standard data structure for work-stealing queues. A dynamic circular array-based
deque where:
- The owner pushes/pops from the bottom (LIFO)
- Thieves steal from the top (FIFO)
- Grows dynamically by doubling the circular buffer

**Original paper:** D. Chase, Y. Lev. "Dynamic Circular Work-Stealing Deque."
SPAA 2005. https://dl.acm.org/doi/10.1145/1073970.1073974

**C11 Atomics Translation:** N. Le et al. "Correct and Efficient Work-Stealing for
Weak Memory Models." PPoPP 2013.

Relaxes sequential consistency to:
- Relaxed atomic operations (where safe)
- Acquire/release operations
- Selective seq-cst (only where ordering is critical)

**CRITICAL BUG in Le et al.:** Integer overflow vulnerability discovered by Andy Wingo.
The `take()` operation decrements `bottom` using `size_t`, which underflows on an empty
deque in the initial state, creating a state that appears as `(size_t)-1` elements.
This causes garbage reads and undefined behavior. The bug was NOT present in the
original Java paper because Java integers don't underflow the same way.

- Analysis: https://wingolog.org/archives/2022/10/03/on-correct-and-efficient-work-stealing-for-weak-memory-models

**Lesson:** Formal proofs of specific algorithm properties don't guarantee overall
correctness. The proof verified the algorithm's concurrent properties but missed
the integer overflow in the C11 translation.

### 1.3 Implementations

#### Crossbeam (Rust)
- URL: https://github.com/crossbeam-rs/crossbeam
- Language: Rust
- Hybrid Chase-Lev implementation combining both papers
- Epoch-based memory reclamation (avoids per-object reference counting)
- Lock-free skip lists for concurrent maps/sets
- SegQueue: lock-free MPMC queue
- Design philosophy: memory management API as easy as GC, statically safe against
  misuse, overhead competitive with GC
- Battle-tested: used by Tokio, Rayon, and most of the Rust ecosystem
- Paper on epoch-based reclamation: A. Turon. "Lock-freedom without garbage
  collection." 2015. https://aturon.github.io/blog/2015/08/27/epoch/

#### Cilk/CilkPlus
- URL: https://www.cilkplus.org/
- Language: C/C++ (compiler extension)
- Pioneered work-stealing for fork-join parallelism
- **Continuation stealing**: the continuation of a spawned function can be stolen
  while the spawned child executes (vs. child stealing)
- Each worker has a deque; pushes/pops at bottom, steals from top (opposite ends
  reduce contention)
- Default: one worker thread per core
- Proven robust for highly irregular parallelism and complex nesting
- Production: Intel TBB integrated Cilk concepts; OpenCilk is the modern successor

#### Taskflow (C++)
- URL: https://github.com/taskflow/taskflow
- Language: C++17
- Work-stealing scheduler optimized for DAG (task dependency graph) execution
- Each worker has a private queue; idle workers become thieves stealing randomly
- Adaptive thread count based on available task parallelism during graph execution
- Single header-file library, ~6000 lines
- Academic papers: C.X. Lin et al. "An Efficient Work-Stealing Scheduler for Task
  Dependency Graph." ICPADS 2020. https://taskflow.github.io/taskflow/icpads20.pdf
- Also: T.W. Huang et al. "Taskflow: A Lightweight Parallel and Heterogeneous Task
  Programming System." IEEE TCAD 2021.

#### Rayon (Rust)
- URL: https://github.com/rayon-rs/rayon
- Language: Rust
- Data-parallelism library using work-stealing under the hood
- Built on crossbeam's Chase-Lev deque
- `par_iter()` automatically splits work across threads
- Production: widely used in the Rust ecosystem for CPU-bound parallelism

---

## 2. Stackless vs Stackful Coroutines

### 2.1 Comparative Analysis

| Property | Stackless | Stackful |
|---|---|---|
| Memory per coroutine | 16-256 bytes + captured locals | 4KB-2MB per stack |
| Context switch cost | ~3.5x faster switching | ~2.4x faster creation |
| Suspension points | Only at direct entry points | Any nested function depth |
| Compiler support | Requires compiler transforms (state machines) | Assembly/ucontext tricks |
| WASM compatibility | Yes | No (no stack manipulation) |
| Deep suspension | Not possible without coloring | Full flexibility |

**Key finding (SC'25 Workshop):** For small-state tasks, both approaches yield nearly
identical overall performance. The smaller frame size of stackless coroutines does not
significantly reduce communication time, which is dominated by network latency.

- Paper: "Stackless vs. Stackful Coroutines: A Comparative Study for RDMA-based
  Asynchronous Many-Task (AMT) Runtimes." SC'25 Workshops.
  https://dl.acm.org/doi/10.1145/3731599.3767502

### 2.2 Notable Implementations

#### Rust async/await (Stackless)
- Compiler generates state machines storing locals in heap-allocated coroutine frames
- Zero-cost abstraction: no allocation if the future is polled in place
- Function coloring problem: async functions have different types than sync functions
- Pinning required for self-referential futures

#### Go Goroutines (Stackful)
- Initial stack: 2KB, growable (segmented -> contiguous stacks since Go 1.4)
- Context switch: ~50-100 nanoseconds
- GMP model: G (goroutine), M (OS thread), P (processor/scheduling context)
- P is a "CPU token" decoupling scheduling from execution
- Cooperative preemption via function call prologues + async preemption (Go 1.14+)
  via signals for long-running loops
- Work stealing between P's local run queues

#### PhotonLibOS (C++, Stackful)
- URL: https://github.com/alibaba/PhotonLibOS
- Language: C++
- From Alibaba Cloud Storage team, extensively tested in production
- **CACS (Context-Aware Context Switching):** saves/restores only the minimum
  necessary registers based on caller/callee context
- Yield operation: ~1.52 ns (~3.34 cycles) on a single Xeon core — comparable to
  a function call
- Enables branch prediction inlining at caller site
- Supports epoll, io_uring, kqueue backends
- Rewrote 600K lines of RocksDB into coroutine program with 200 lines of changes
- Paper: "Stackful Coroutine Made Fast." PhotonLibOS, 2024.
  https://photonlibos.github.io/blog/stackful-coroutine-made-fast

#### May (Rust, Stackful)
- URL: https://github.com/Xudong-Huang/may
- Language: Rust
- Stackful coroutines modeled after Go goroutines
- Based on generator implementation with ASM context switching
- Restrictions: must not call thread-blocking APIs; careful with TLS
- Less maintained; niche compared to async/await ecosystem

#### Minicoro (C, Stackful)
- URL: https://github.com/edubart/minicoro
- Language: C (single header)
- Asymmetric stackful coroutines inspired by Lua coroutines
- Implementation: assembly, ucontext, or fibers (platform-dependent)
- Supports nesting, custom allocators, multithread safety
- Growable stacks with virtual memory allocator for low memory footprint
- Assembly inspired by Lua Coco (Mike Pall)
- Used as coroutine backend for Nelua programming language

### 2.3 Design Guidance

- **High-density I/O (thousands of concurrent suspensions):** stackless wins on memory
- **Complex algorithms with deep suspension:** stackful wins on expressiveness
- **WASM targets:** stackless is the only option
- **Legacy code integration:** stackful is less intrusive (no function coloring)
- **Cache locality:** stackless state machines keep hot data together; stackful
  stacks scatter it across memory

---

## 3. io_uring-Based Event Loops

### 3.1 Architecture

io_uring uses two lock-free ring buffers shared between user space and kernel:
- **Submission Queue (SQ):** applications enqueue I/O requests
- **Completion Queue (CQ):** kernel places results when operations complete

This is a **completion-based** (proactor) model, fundamentally different from
**readiness-based** (reactor) models like epoll/kqueue/poll.

Key advantages over epoll:
- Batched submission reduces syscall overhead
- True async file I/O (epoll can't do non-blocking file I/O)
- Multishot operations (accept, poll) produce multiple CQEs from one SQE
- Registered buffers/file descriptors eliminate repeated kernel lookups
- `IOSQE_IO_LINK` chains operations for ordered execution within a batch

### 3.2 Implementations

#### mrloop (C)
- URL: https://github.com/MarkReedZ/mrloop
- Language: C
- Minimal event loop built directly on io_uring
- Single-threaded design for maximum simplicity

#### async_io_uring (Zig)
- URL: https://github.com/saltzm/async_io_uring
- Language: Zig
- Event loop combining io_uring with Zig's coroutine support
- Educational reference for understanding the io_uring / coroutine integration

#### libxev (Zig/C)
- URL: https://github.com/mitchellh/libxev
- Language: Zig (with C API)
- Cross-platform: io_uring (Linux), epoll (Linux fallback), kqueue (macOS), WASM+WASI
- **Proactor API** modeled after io_uring semantics even on non-io_uring platforms
- Two API levels: high-level (platform-agnostic) and low-level (platform-specific
  escape hatch)
- Thread pool for operations without non-blocking APIs (e.g., local files on kqueue)
- Production: stable at scale (used in Ghostty terminal emulator)
- Created by Mitchell Hashimoto (HashiCorp founder)

#### TigerBeetle I/O Abstraction (Zig)
- URL: https://tigerbeetle.com/blog/2022-11-23-a-friendly-abstraction-over-iouring-and-kqueue/
- Language: Zig
- Single-threaded event loop wrapping io_uring and kqueue
- Designed for determinism: single-threaded userspace I/O enables deterministic
  simulation testing (DST)
- The VOPR simulator: entire cluster in single process, 1000x speed
  (3.3s simulation = 39min real-world testing)
- Static memory allocation, zero copy, zero deserialization, Direct I/O
- Production: TigerBeetle financial transactions database

#### Redis io_uring Backend
- PR: https://github.com/redis/redis/pull/14644
- Language: C
- Added as event loop backend for Linux (kernel 5.6+)
- Multishot accept/poll operations
- Production: Redis 8.x+

### 3.3 Design Trade-offs

- **Throughput vs latency:** io_uring's batching improves throughput but can add
  latency compared to immediate epoll dispatch
- **Kernel version requirements:** minimum 5.8 for full feature set; 5.6 for basics
- **Portability:** Linux-only; cross-platform systems must abstract over
  io_uring/kqueue/IOCP (as libxev and compio do)
- **Buffer ownership:** completion-based I/O requires the kernel to own buffers until
  completion, complicating memory management vs readiness-based models

---

## 4. Thread-Per-Core Architectures

### 4.1 Seastar / ScyllaDB Model

- URL: https://seastar.io/ / https://github.com/scylladb/seastar
- Language: C++
- **The defining implementation** of thread-per-core shared-nothing architecture

**Core principles:**
- One application thread pinned per CPU core
- Each thread owns: a chunk of memory (NUMA-local), network connections, storage I/O
- No locks, no shared mutable state, no context switches
- Explicit message passing via `smp::submit_to(cpu, lambda)` returning a future
- Map/reduce across all cores via broadcast + collect

**Resource allocation:**
- Each shard gets dedicated memory, network bandwidth, and storage bandwidth
- Linear scalability: 16 cores -> 32 cores = exactly 2x performance

**Scheduling:**
- Cooperative: tasks voluntarily yield
- Task quota: periodic polling ensures no task runs longer than a specified interval
- Priority-based task queues within each shard

**Production exposure:**
- ScyllaDB: drop-in Cassandra replacement, 10x performance
- Redpanda: Kafka-compatible streaming platform
- Ceph (partial): object storage

**Lessons from Redpanda (QCon London 2023):**
- Unexpected simplicity from strictly mapping data to cores
- Few libraries designed for thread-per-core (ecosystem gap)
- Loss of virtual memory benefits
- Standard memory analysis tools don't work out of the box
- Debugging shared-nothing is different: no data races, but message ordering bugs
- Works best when work decomposes into units mappable to shards

- Reference: https://www.scylladb.com/product/technology/shard-per-core-architecture/
- Talk: "Performance: Adventures in Thread-per-Core Async with Redpanda and Seastar"
  https://www.infoq.com/presentations/high-performance-asynchronous3/

### 4.2 Glommio (Rust)

- URL: https://github.com/DataDog/glommio
- Language: Rust
- Created by Glauber Costa (ex-ScyllaDB), maintained by Datadog
- **Status: effectively unmaintained** (despite Datadog ownership, they use Tokio
  internally)

**Architecture:**
- Thread-per-core with cooperative scheduling
- Three io_uring instances per thread:
  - **Main ring:** standard file/socket operations
  - **Latency ring:** time-critical I/O with yield awareness
  - **Poll ring:** NVMe direct polling (avoids interrupts)
- Proportional scheduling via "shares" system for task queues
- `yield_if_needed()` checks latency ring head/tail pointers (negligible cost)

**Design decisions:**
- No helper threads anywhere (pure thread-per-core)
- Lock-free by construction (single thread per core means no contention)
- Atomic operations relegated to handful of corner cases

**Performance claims:**
- Up to 71% improvement in tail latencies (from research)
- Eliminates context switch overhead (~5 microseconds saved per switch)

**Trade-offs:**
- Linux-only (io_uring dependency)
- Requires explicit data sharding
- Applications must voluntarily yield
- Optimal perf requires CPU isolation + Kubernetes-specific configs

**Lesson learned:** Architecturally superior design does not guarantee adoption.
Datadog maintains Glommio but uses Tokio for their own products. Active maintenance
matters more than theoretical perfection.

### 4.3 Monoio (Rust)

- URL: https://github.com/bytedance/monoio
- Language: Rust
- Created by ByteDance
- Pure io_uring/epoll/kqueue async runtime

**Key design:**
- Thread-per-core: tasks don't need to be Send or Sync
- Thread-local storage is safe by design
- Does NOT run on top of another runtime (unlike tokio-uring)

**Benchmarks (official, take with appropriate skepticism):**
- 1 core: slightly better than Tokio
- 4 cores: ~2x Tokio peak performance
- 16 cores: ~3x Tokio peak performance
- Better horizontal scalability than Glommio with higher peak performance

**Trade-offs:**
- Unbalanced workloads cause performance degradation vs Tokio (no work stealing)
- Slower maintenance cycle than Tokio
- Evaluated and rejected by Apache Iggy team due to feature gaps

### 4.4 Compio (Rust)

- URL: https://github.com/compio-rs/compio
- Language: Rust
- Thread-per-core runtime with IOCP/io_uring/polling backends
- Inspired by monoio but cross-platform (Windows IOCP support)

**Key design:**
- Decoupled driver/executor architecture (pluggable components)
- Broad io_uring feature support
- Active maintenance (key differentiator)

**Production exposure:**
- Selected by Apache Iggy for their v0.6.0 rewrite (Dec 2025)
- Iggy results with compio:
  - 16 partitions: P9999 latency improved 92% (86.30ms -> 7.17ms)
  - 32 partitions: P95 improved 57%, P99 improved 60%
  - fsync mode: +18% throughput (931 -> 1,102 MB/s)
  - Read performance: 3,361 MB/s with sub-4ms P9999

**Lessons from Apache Iggy migration:**
- POSIX abstractions (File, TcpListener) limit io_uring's most powerful features
  (request chaining, registered buffers, oneshot operations)
- RefCell borrows across .await points cause runtime panics — required
  control plane / data plane split
- io_uring batch operations are NOT guaranteed to execute in order — use
  `IOSQE_IO_LINK` chaining flag for sequential execution
- Active maintenance > perfect design (chose compio over glommio)
- Async runtimes should have pluggable components for deterministic simulation testing

### 4.5 Apache Iggy Case Study

- URL: https://iggy.apache.org/blogs/2026/02/27/thread-per-core-io_uring/
- The most detailed public account of migrating from work-stealing (Tokio) to
  thread-per-core (compio) in a production Rust system.

**Migration challenges:**
1. Interior mutability across await points (RefCell panics)
2. io_uring operation ordering (non-deterministic batch execution)
3. Shared state management (solved with `left-right` concurrent data structure
   for strongly-consistent resources + DashMap for eventually-consistent sharded data)

**Ecosystem gap identified:** Rust lacks a Seastar equivalent. Glommio attempted
this role but is unmaintained. Teams needing performance-at-scale face missing
abstractions and workflow friction.

---

## 5. Runtime Designs

### 5.1 Tokio (Rust)

- URL: https://github.com/tokio-rs/tokio
- Language: Rust
- **The dominant Rust async runtime.** Battle-tested at massive scale.

**Scheduler Architecture:**
- Multi-threaded work-stealing scheduler (default)
- Single-threaded option (`current_thread`)
- Each worker has a fixed-size local run queue (bounded circular buffer)
- Global queue for overflow when local queues are full
- Work stealing: idle workers steal half of another worker's queue

**Key Optimizations (2019 rewrite, 10x improvement):**

1. **Fixed-size local queues:** Replaced crossbeam's dynamic deques. Eliminates
   epoch-based memory reclamation overhead. Queue operations:
   - Push: 1 Acquire load + 1 Release store (no read-modify-write)
   - Pop: 1 Acquire load + 1 CAS
   - On x86: minimal CPU synchronization

2. **LIFO slot:** Special "next task" slot checked before the run queue. When task A
   sends a message waking task B, B goes into the LIFO slot and executes next.
   Improves cache locality (message data still hot in cache).
   - **Known issue:** LIFO slot tasks don't participate in work stealing, causing
     latency spikes when a LIFO task doesn't yield. Can be disabled with
     `disable_lifo_slot()` (unstable API).

3. **Throttled stealing:** Concurrent work-stealing searchers limited to half the
   worker count via sloppy atomic counter. Prevents thundering herd during batch
   task arrivals.

4. **Single allocation per task:** Header (hot data) + future + trailer (cold data)
   combined into one allocation via custom `std::alloc`.

5. **Wake throttling:** Only notify idle workers if no searchers exist, enabling
   smooth ramp-up rather than waking all workers simultaneously.

6. **Reduced atomic ref counting:** `Waker::wake_by_ref` avoids atomic increment;
   scheduler's task list acts as implicit reference count.

**Benchmark results (2019 rewrite):**
- chained_spawn: 11.9x faster
- ping_pong: 2.3x faster
- Hyper hello-world: 34% throughput increase (113K -> 152K req/sec)
- Tonic gRPC: ~10% improvement

**Lessons:**
- "No code faster than no code" — reduction over optimization
- Weak atomics (Acquire/Release) sufficient for single-producer cases
- Mutexes often better than atomics for certain paths
- Work-stealing complexity justified only for non-uniform workloads

- Blog: https://tokio.rs/blog/2019-10-scheduler

### 5.2 smol (Rust)

- URL: https://github.com/smol-rs/smol
- Language: Rust
- Tiny, composable async runtime

**Design philosophy:**
- No macros, no sprawling APIs
- Re-exports smaller async crates (async-fs, async-net, etc.)
- Unopinionated building blocks vs Tokio's opinionated ecosystem
- Prioritizes simplicity and predictable tail latency over raw throughput

**Trade-offs:**
- Lower ecosystem support than Tokio
- Better for CLI tools, libraries, resource-constrained environments
- Not suitable for high-throughput network servers

### 5.3 Go Runtime (Go)

- URL: https://go.dev/ (runtime is part of the language)
- Language: Go

**GMP Model:**
- **G (Goroutine):** lightweight user-space task, 2KB initial stack
- **M (Machine):** OS thread executing goroutines
- **P (Processor):** logical CPU token holding a run queue; decouples scheduling
  from execution. `GOMAXPROCS` sets P count (default: CPU count).

**Scheduling:**
- Cooperative at function calls (compiler inserts preemption checks in prologues)
- Async preemption via OS signals (Go 1.14+) for long-running loops
- Work stealing between P's local run queues
- Global run queue as fallback
- Context switch: ~50-100 nanoseconds

**Key design decisions:**
- M:N threading (many goroutines on few OS threads)
- Growable stacks (2KB -> as needed), copied on growth (not segmented since Go 1.4)
- netpoller integration: goroutines blocking on I/O are parked, not blocking M
- Syscall handling: when G blocks on syscall, M is detached from P and a new M
  created/reused; P can continue scheduling other G's

### 5.4 Erlang BEAM (Erlang/Elixir)

- Language: Erlang, Elixir
- **Preemptive scheduling via reduction counting**

**Architecture:**
- One scheduler thread per CPU core
- Reduction = unit of work (function call, arithmetic, message send)
- Each process gets a budget of reductions (~4000 default)
- When budget exhausted, process is preempted (cooperative on C level, preemptive
  on Erlang level)
- Per-process heap with independent GC (no stop-the-world)

**Key properties:**
- True preemption for soft real-time guarantees
- Millions of lightweight processes (each ~300 bytes initial)
- No process can starve others (reduction budget enforced)
- Built-in distribution: processes can be on different nodes transparently

**Scheduler features:**
- Work stealing between scheduler threads
- Migration logic for load balancing
- Dirty schedulers for NIFs that can't yield

**Lesson:** Reduction counting achieves preemptive-like fairness without OS timer
interrupts. The compiler and VM cooperate to ensure bounded execution between
yield points.

- Reference: https://github.com/happi/theBeamBook/blob/master/chapters/scheduling.asciidoc

### 5.5 Zig Async I/O (Zig)

- URL: https://ziglang.org/
- Language: Zig

**New design (2025+):**
- Decouples async/await from execution model entirely
- `Io` interface is a non-generic vtable (like Zig's `Allocator`)
- Caller provides the I/O implementation — dependency injection throughout the
  call stack

**Execution models supported (all from same code):**
1. Blocking I/O: equivalent to C, zero overhead
2. Thread pool: multiplexes blocking calls across OS threads
3. Green threads: io_uring + thread pools for concurrent tasks
4. Stackless coroutines (planned): WASM-compatible

**Function coloring solution:** I/O strategy is pluggable at runtime, not encoded
in function signatures. A single library binary works regardless of the host
application's concurrency strategy. `io.async` expresses asynchrony (out-of-order
OK); `io.asyncConcurrent` expresses true concurrency (panics if backend can't
support it).

**Guaranteed de-virtualization:** when only one `Io` implementation exists, the
vtable is eliminated at compile time (no runtime dispatch cost).

- Blog: https://kristoff.it/blog/zig-new-async-io/

### 5.6 Zap (Zig)

- URL: https://github.com/kprotty/zap
- Language: Zig
- Focus: resource-efficient thread pool with work stealing

**Key design decisions:**
- Intrusive task structures (no allocation): tasks embedded in caller contexts,
  retrieved via `@fieldParentPtr()` (Zig's `container_of`)
- Bounded SPMC buffer for normal ops; unbounded overflow queue as fallback
- Single 32-bit atomic `Sync` word coordinates all thread state via CAS
  (no locks)
- Lazy thread spawning with graceful failure handling
- **Wake throttling:** only one "waking thread" at a time — prevents thundering
  herd. Woken thread must find tasks before waking another.

**Influence:** Zap's thread pool design was adopted by Bun (JavaScript runtime)
for its worker pool: https://github.com/oven-sh/bun/blob/main/src/thread_pool.zig

### 5.7 Tardy (Zig)

- URL: https://github.com/tardy-org/tardy
- Language: Zig
- Created by mookums (muki), Seattle-based developer
- Thread-local async I/O runtime with stackful coroutines
- Stars: ~271 (tardy) + ~716 (zzz, the HTTP framework built on it)
- License: MPL-2.0

**Architecture:**
- **Thread-local isolated runtimes**: each thread runs an independent `Runtime` instance
  with its own scheduler, task pool, and I/O backend — no cross-thread synchronization
  in the hot path
- Threading modes: `.single`, `.multi(n)`, `.all` (all cores), `.auto` (max(cpus/2 - 1, 1))
- Cooperative multitasking: tasks yield explicitly when waiting for I/O or triggers

**Coroutine Model (Frames):**
- **Stackful coroutines** with custom assembly context switching (`tardy_swap_frame()`)
- Architecture-specific implementations: x86_64 SysV (7 registers), x86_64 Windows
  (31 registers), AArch64 (20 registers)
- Each Frame gets a heap-allocated stack; `Frame.yield()` suspends, `Frame.proceed()`
  resumes
- Thread-local `active_frame` variable tracks the currently executing frame
- In debug mode, stacks are filled with 0xAA for debugger visibility
- Frame status machine: `in_progress` -> `done` | `errored`

**I/O Backend Abstraction:**
- Unified vtable-based `Async` interface across all backends:
  - `AsyncIoUring` (Linux >= 5.1) — full file + network async I/O
  - `AsyncEpoll` (Linux >= 2.5.45) — network/timer only
  - `AsyncKqueue` (BSD/macOS) — network/timer only
  - `AsyncPoll` (cross-platform fallback) — socket/timer only
- Auto-detection: Linux prefers io_uring, falls back to epoll; BSD/macOS uses kqueue;
  Windows/Solaris uses poll
- Custom backend support: any type implementing `init`, `inner_deinit`, `queue_job`,
  `to_async` methods
- Capability bitmask (`AsyncFeatures`): backends declare which operations they support
  (open, read, write, accept, connect, etc.)

**Scheduler Design:**
- Task pool with configurable pooling strategy: `.grow` (dynamic) or `.static` (fixed)
- Default initial pool size: 1024 tasks
- Task state machine: `dead` -> `runnable` -> `wait_for_io` | `wait_for_trigger` ->
  `runnable` -> `dead`
- Released task indices are recycled via a queue to minimize allocation
- Atomic bitset triggers for cross-thread wake-ups
- Run loop: iterate all tasks, run runnable ones, check triggers, submit I/O, reap
  completions, repeat. When no tasks are runnable, blocks on I/O reap.

**Memory Management:**
- Pre-allocated pools with index reuse — no per-operation allocation in hot paths
- Frame stacks are heap-allocated and freed on task completion
- Zero-copy I/O primitives via `zero_copy.zig`

**Ecosystem:**
- **zzz** (HTTP/HTTPS framework): built on tardy, competitive with gnet (TechEmpower's
  fastest plaintext HTTP server) at ~22% of gnet's memory. On Hetzner CCX63:
  70.9% faster than Zap, 83.8% faster than http.zig, using ~3% of Zap's memory
  and ~1.6% of http.zig's memory
- **secsock**: async TLS implementation for tardy sockets
- SPSC channels for inter-runtime communication

**Key Design Decisions:**
1. **Stackful over stackless coroutines**: simpler mental model, natural stack traces,
   standard function call semantics. Trade-off: higher memory per task (~configurable
   stack size) vs stackless state machines
2. **vtable dispatch for I/O backends**: single binary supports multiple backends
   without recompilation. Small polymorphism cost at runtime
3. **Thread-local isolation over work-stealing**: eliminates lock contention at the cost
   of requiring explicit channels for cross-thread communication and no automatic
   load balancing
4. **Pool-based memory**: pre-allocated with index recycling avoids allocator pressure
   in hot paths

**Comparison with Other Zig Runtimes:**
- vs **libxev**: libxev is a lower-level event loop (proactor API) with C bindings and
  WASM support; tardy is a higher-level runtime with stackful coroutines, scheduler,
  and task management. libxev is more mature (production in Ghostty)
- vs **Zap**: Zap is a work-stealing thread pool; tardy is thread-local isolated.
  zzz (built on tardy) benchmarks 70.9% faster than Zap for HTTP
- vs **Zig std.Io** (new async design): std.Io uses a non-generic vtable with
  guaranteed de-virtualization and supports blocking/threaded/green thread/stackless
  modes from same code. Tardy commits to stackful coroutines with its own vtable
  abstraction. When std.Io stabilizes, tardy may need to adapt or integrate

**Production Status:** Alpha. zzz framework is running in production despite rapid
changes. No major production deployments documented for tardy itself yet.

### 5.8 Odin Threading Model

- URL: https://odin-lang.org/
- Language: Odin
- No built-in scheduler or runtime — explicit threading via `core/thread` package
- Thread pools with `pool_add_task` (can add tasks from any thread, including
  from within other tasks)
- Synchronization primitives in `core/sync`
- Philosophy: no automatic memory management = no hidden runtime
- Third-party `oasync` library provides M:N threading (virtual threads) but
  is experimental

### 5.9 Event Loop Libraries (C)

#### libuv
- URL: https://github.com/libuv/libuv
- Cross-platform (Linux epoll, macOS kqueue, Windows IOCP)
- Powers Node.js
- Thread pool for blocking operations (file I/O, DNS)
- Most active community and maintenance

#### libev
- URL: http://software.schmorp.de/pkg/libev.html
- Lightweight, fast, Unix-focused
- 8 event types (I/O, timers, signals, child status, etc.)
- Benchmarks: ~2x faster than libevent in dispatch throughput
- Limited community; no Windows IOCP support

#### libevent
- URL: https://libevent.org/
- Mature, widely deployed
- Slower dispatch than libev in benchmarks
- Good cross-platform support

---

## 6. Formal Verification of Concurrent Schedulers

### 6.1 TLA+ and Model Checking

- Tool: TLA+ (Temporal Logic of Actions), by Leslie Lamport
- TLAPS (TLA+ Proof System): mechanically checks proofs, developed at
  Microsoft Research-INRIA
- Used to verify Byzantine Paxos, Pastry DHT components
- **Amazon AWS** uses TLA+ since 2011: found bugs in DynamoDB, S3, EBS, and
  internal distributed lock manager

Concurrent scheduler verification: TLA can formally reason about scheduling
strategies by verifying that an efficient strategy preserves all properties
(especially behavior) of a simpler reference strategy.

- Paper: G.M. Sherali et al. "Formal verification of concurrent scheduling
  strategies using TLA." IEEE SRMPDS, 2007.
  https://ieeexplore.ieee.org/document/4447839/

### 6.2 Loom (Rust-specific)

- URL: https://github.com/tokio-rs/loom
- Language: Rust
- Permutation testing for concurrent Rust code under C11 memory model
- Deterministically explores all valid execution orderings
- State reduction techniques to avoid combinatorial explosion
- When a test fails, outputs the exact execution path for reproduction

**How it works:**
- Intercepts all loads, stores, and concurrency-sensitive operations
- Simulates OS scheduler and Rust memory model
- Requires using `loom` replacement types (not automatic)

**Impact on Tokio:** Caught 10+ bugs missed by conventional testing during
the 2019 scheduler rewrite. Essential for verifying lock-free data structures.

**Limitation:** Code must explicitly use loom types; any code using standard
library atomics is invisible to loom.

### 6.3 Deterministic Simulation Testing (DST)

**FoundationDB** pioneered this approach:
- Entire cluster simulated in a single-threaded process
- Flow language: C++ extension with actor-based concurrency
- Deterministic scheduler abstracts all nondeterminism (network, disk, time, PRNG)
- Simulates failures at network, machine, and datacenter levels
- Perfect repeatability of any simulated run
- "Before building the database, they built the simulation framework"
- Paper: J. Zhou et al. "FoundationDB: A Distributed Unbundled Transactional
  Key Value Store." SIGMOD 2021.

**TigerBeetle VOPR:**
- Deterministic simulator fuzzing entire clusters
- Network + storage fault injection
- 3.3 seconds of simulation = 39 minutes of real-world testing
- Every bug is deterministically reproducible

**Lesson for scheduler design:** Single-threaded event loops enable DST by
construction. Multi-threaded schedulers require careful abstraction of all
nondeterminism sources to achieve testability.

### 6.4 sched_ext (Linux Kernel)

- URL: https://github.com/sched-ext/scx
- Merged in Linux 6.11 (June 2024)
- Write kernel schedulers in BPF, load dynamically at runtime
- Safety: BPF static analysis prevents crashes; if scheduler misbehaves
  (e.g., fails to schedule a task for 30s), kernel kills it and falls back
  to CFS/EEVDF
- Update scheduler without kernel reinstall or reboot
- **Future plans:** hierarchical schedulers, composable schedulers, GPU awareness,
  energy-aware abstractions, Rust implementation of some C code
- Production: Valve (Steam Deck game scheduling), Meta

**Relevance to runtime design:** sched_ext enables prototyping OS-level scheduling
strategies as BPF programs, including adaptive schedulers that switch policies
based on workload detection.

---

## 7. NUMA-Aware Scheduling

### 7.1 Core Concepts

- NUMA: memory access time depends on processor-memory distance
- Local memory access: fast; remote (cross-node) access: 1.5-3x slower
- Modern servers: 2-8+ NUMA nodes, each with multiple cores

### 7.2 Strategies

**Thread/Process Placement:**
- Pin threads to cores via affinity masks (sched_setaffinity / CPU_SET)
- Partition state across NUMA nodes; each thread works on NUMA-local data
- Achieve >99% local memory accesses with proper placement

**Memory Allocation:**
- First-touch policy: page allocated on the node where it's first accessed
- Interleaved allocation: spread pages across nodes (good for shared read-only data)
- Explicit NUMA allocation: `mbind()`, `set_mempolicy()`
- Memory migration: move pages to match thread placement at runtime

**Performance results:**
- 192-core system with 24 NUMA nodes: proper NUMA-aware scheduling achieved
  **5x speedup** over NUMA-aware hierarchical work-stealing baseline
- Local memory fraction increased to >99%

**Papers:**
- B. Lepers et al. "Thread and Memory Placement on NUMA Systems: Asymmetry
  Matters." USENIX ATC 2015. https://people.ece.ubc.ca/sasha/papers/atc15-final165.pdf
- "NUMA-aware scheduling and memory allocation for data-flow task-parallel
  applications." PPoPP 2016. https://dl.acm.org/doi/10.1145/2851141.2851193

### 7.3 Seastar's NUMA Approach

Seastar allocates a pool of memory from each NUMA node and assigns it to the
core(s) on that node. Each shard's memory is guaranteed NUMA-local. Inter-core
messages use per-pair queues that are allocated on the receiver's NUMA node.

### 7.4 Implications for Runtime Design

- Work stealing across NUMA boundaries is expensive (remote memory access for
  stolen task's data)
- NUMA-aware stealing: prefer to steal from same NUMA node first
- Thread-per-core with NUMA-local memory allocation is the simplest correct approach
- Hierarchical schedulers: local stealing within NUMA node, cross-node stealing
  only as last resort

---

## 8. Adaptive Scheduling Strategies

### 8.1 Overview

Adaptive schedulers dynamically adjust scheduling policies based on runtime
observations of workload characteristics, resource utilization, and performance
metrics.

### 8.2 Approaches

**Workload-Aware Switching (sched_ext ASA):**
- Lightweight framework matching workloads to optimal scheduling policies
- Perception module: monitors runtime metrics continuously
- Decision module: trained ML model recognizes workload patterns, consults
  scheduler mapping table
- Action module: dynamically switches scheduler via sched_ext
- Paper context: "Mixture-of-Schedulers: An Adaptive Scheduling Agent."
  arXiv:2511.11628, 2025.

**Adaptive Work Stealing (Microsoft Research):**
- Adjusts parallelism level based on runtime feedback
- Key insight: optimal number of active stealers changes with workload phase
- Paper: K. Agrawal, Y. He. "Adaptive Work Stealing with Parallelism Feedback."
  https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/asteal.pdf

**Hybrid ML + Heuristics:**
- ML components tune heuristic parameters (time-slice intervals, queue thresholds)
- Final scheduling decisions use traditional rule-based mechanisms
- Combines ML adaptability with heuristic predictability

**Cooperative Budget Limits (Tokio-style):**
- Set execution limits forcing submission/reaping after task threshold
- Cooperative polling limits restrict state transitions per poll
- Prevents starvation without preemption

### 8.3 Tokio's Adaptive Mechanisms

- Throttled work-stealing searchers (sloppy atomic counter)
- LIFO slot for message-passing patterns (automatically prioritizes receivers)
- Global queue checked periodically (every N local pops) to prevent global starvation
- Worker notification: smooth ramp-up rather than thundering herd

### 8.4 Go's Adaptive Mechanisms

- Spinning vs non-spinning threads: idle threads spin briefly before parking
- Dynamic M creation: new OS threads created when all M's are blocked on syscalls
- Syscall-aware scheduling: M detaches from P during blocking syscalls

---

## 9. Cache-Friendly Task Queues

### 9.1 False Sharing

**The problem:** Multiple CPU cores accessing independent variables on the same
cache line forces unnecessary cache coherence traffic. Cache line sizes:
- x86: 64 bytes
- Apple M-series: 128 bytes

**Impact:** Can cause 2-10x slowdown in concurrent data structures.

### 9.2 Mitigation Strategies

**Padding and Alignment:**
- Align queue entries to cache line boundaries
- Add padding between independent variables
- Tokio uses `#[repr(align(64))]` on worker state structures

**Structure Layout:**
- Hot data (frequently accessed) grouped together in same cache line
- Cold data (rarely accessed) separated to different cache lines
- Tokio's task layout: Header (hot) | Future | Trailer (cold) — single allocation
  but cache-aware layout

**CFCLF Queue Design:**
- Uses matrix (2D array) instead of 1D array for the shared queue
- Provides good cache behavior by ensuring producers and consumers access
  different cache lines
- Paper: "A cache-friendly concurrent lock-free queue for efficient inter-core
  communication." IEEE 2017.
  https://ieeexplore.ieee.org/abstract/document/8230170/

### 9.3 Queue Design Patterns

**Single-Producer Single-Consumer (SPSC):**
- Simplest and fastest: no contention by design
- Used within thread-per-core architectures for inter-core channels
- Cache-aware: head and tail on separate cache lines

**Single-Producer Multi-Consumer (SPMC):**
- Used for work-stealing deques (owner produces, thieves consume)
- Chase-Lev deque is the standard
- Bounded SPMC buffer with overflow to unbounded queue (Zap's approach)

**Multi-Producer Multi-Consumer (MPMC):**
- Most complex, highest contention
- Crossbeam SegQueue: lock-free MPMC
- Higher overhead than SPSC/SPMC but necessary for certain patterns

**Fixed-size vs Dynamic:**
- Tokio chose fixed-size local queues over dynamic (crossbeam) deques
- Trade-off: fixed-size eliminates epoch-based reclamation overhead but requires
  overflow handling (push to global queue)
- Fixed-size queues: push is 1 Acquire load + 1 Release store (no RMW)
- Dynamic queues: push requires atomic RMW for growth detection

### 9.4 Cache Locality Optimizations in Schedulers

**LIFO execution (Tokio, Go, Kotlin):**
- Execute most recently woken task first
- Rationale: data accessed by the waker is still in L1/L2 cache
- Significantly improves message-passing workloads

**Affinity-based stealing:**
- Prefer stealing from nearby cores (same L3 cache / NUMA node)
- Reduces cache miss penalty when accessing stolen task's data

**Task-local storage:**
- Thread-per-core: TLS is safe and fast (no synchronization)
- Work-stealing: task affinity hints keep tasks on preferred workers

---

## 10. Key Research Papers

### Foundational

1. R.D. Blumofe, C.E. Leiserson. "Scheduling Multithreaded Computations by Work
   Stealing." JACM 46(5), 1999.
   — The theoretical foundation for work-stealing schedulers.

2. D. Chase, Y. Lev. "Dynamic Circular Work-Stealing Deque." SPAA 2005.
   — The standard deque data structure for work stealing.

3. N. Le, A. Pop, A. Cohen, F. Zappa Nardelli. "Correct and Efficient Work-Stealing
   for Weak Memory Models." PPoPP 2013.
   — C11 atomics translation of Chase-Lev (but see integer overflow bug above).

4. N.S. Arora, R.D. Blumofe, C.G. Plaxton. "Thread Scheduling for Multiprogrammed
   Multiprocessors." Theory of Computing Systems 34(2), 2001.
   — The ABP non-blocking work-stealing algorithm.

### Runtime Design

5. T.W. Huang et al. "Taskflow: A Lightweight Parallel and Heterogeneous Task
   Programming System." IEEE TCAD 2021.

6. "Stackless vs. Stackful Coroutines: A Comparative Study for RDMA-based AMT
   Runtimes." SC'25 Workshops, 2025.

7. C.X. Lin et al. "An Efficient Work-Stealing Scheduler for Task Dependency Graph."
   ICPADS 2020.

### NUMA and Cache

8. B. Lepers et al. "Thread and Memory Placement on NUMA Systems: Asymmetry Matters."
   USENIX ATC 2015.

9. "NUMA-aware scheduling and memory allocation for data-flow task-parallel
   applications." PPoPP 2016.

10. Y. Gu et al. "Analysis of Work-Stealing and Parallel Cache Complexity."
    arXiv:2111.04994, 2021.

### Verification

11. L. Lamport. "Verification and Specification of Concurrent Programs."
    https://lamport.azurewebsites.net/pubs/lamport-verification.pdf

12. J. Zhou et al. "FoundationDB: A Distributed Unbundled Transactional Key Value
    Store." SIGMOD 2021.

13. G.M. Sherali et al. "Formal verification of concurrent scheduling strategies
    using TLA." IEEE SRMPDS 2007.

### Adaptive Scheduling

14. K. Agrawal, Y. He. "Adaptive Work Stealing with Parallelism Feedback."
    Microsoft Research.

15. "Mixture-of-Schedulers: An Adaptive Scheduling Agent as a Learned Router for
    Expert Policies." arXiv:2511.11628, 2025.

---

## 11. Lessons & Design Principles

### From Tokio (Rust, work-stealing)
- Fixed-size queues beat dynamic queues when overflow is rare
- LIFO slot is a massive win for message-passing but creates starvation risk
- Throttle concurrent stealers to half the worker count
- Single allocation per task eliminates allocator pressure
- Loom permutation testing is essential for lock-free correctness
- "No code faster than no code" — simplification wins

### From Seastar/ScyllaDB (C++, thread-per-core)
- Shared-nothing + message passing eliminates entire classes of bugs
- Linear scalability is achievable when each core owns its resources
- Few libraries are designed for this model (ecosystem friction)
- Virtual memory tools break; custom tooling required
- Works best when data naturally shards

### From Apache Iggy (Rust, Tokio -> compio migration)
- POSIX abstractions hide io_uring's best features
- Active maintenance matters more than architectural perfection
- RefCell across await points is a landmine
- io_uring batch ordering is non-deterministic (use IOSQE_IO_LINK)
- Pluggable runtime components enable deterministic simulation testing
- Thread-per-core requires fundamentally rethinking concurrency patterns

### From Go (work-stealing + goroutines)
- GMP decoupling (scheduling from execution) is elegant and effective
- Small initial stacks (2KB) with growth enable millions of goroutines
- Async preemption (signals) needed in addition to cooperative checks
- Syscall awareness prevents a blocked goroutine from starving a P

### From Erlang BEAM (reduction counting)
- Preemptive fairness without OS timer interrupts is possible
- Per-process heaps with independent GC avoids stop-the-world
- Reduction counting is simple to implement and reason about
- Suitable for soft real-time guarantees

### From Zig (pluggable I/O)
- Decoupling concurrency primitives from execution model defeats function coloring
- vtable dispatch with guaranteed de-virtualization: zero-cost when monomorphic
- Same code works with blocking, threaded, and evented I/O

### From Tardy (Zig, thread-local stackful coroutines)
- Stackful coroutines with custom assembly context switching trade memory for simplicity
- Thread-local isolation is simpler than work-stealing but requires explicit cross-thread
  channels and cannot automatically rebalance load
- vtable-based I/O backend abstraction enables single-binary multi-platform support
- Pool-based allocation with index recycling eliminates hot-path allocator pressure
- zzz framework demonstrates that extreme memory efficiency (~22% of gnet, ~3% of Zap)
  is achievable with pre-allocation and thread-local design
- Custom I/O backend support (via duck-typed `custom: type`) allows embedding in
  bare metal / non-standard environments

### From TigerBeetle / FoundationDB (verification)
- Build the testing framework before the system
- Single-threaded event loops enable deterministic simulation by construction
- Deterministic simulation at 1000x speed catches bugs that years of production
  can't find
- Every bug must be reproducible

### Universal Principles
1. **Cache coherence traffic is the fundamental bottleneck** — minimize cross-core
   synchronization above all else
2. **Work stealing is optimal for non-uniform workloads** but adds complexity
   that's wasted on balanced workloads
3. **Thread-per-core eliminates lock contention** but requires explicit data
   partitioning and message passing
4. **Fixed-size bounded structures** beat dynamic ones when overflow is rare
   (simpler code, fewer allocations, better cache behavior)
5. **Wake throttling prevents thundering herd** — only wake one thread at a time,
   require it to find work before waking another
6. **LIFO execution improves cache locality** for message-passing patterns at the
   cost of potential starvation
7. **Formal verification catches bugs that testing can't** — but proofs of
   algorithm properties don't guarantee implementation correctness (Chase-Lev
   integer overflow bug)
8. **NUMA awareness can yield 5x improvement** on multi-socket systems; ignoring
   it leaves massive performance on the table
9. **Ecosystem and maintenance matter as much as design** — the best architecture
   is worthless if unmaintained (Glommio lesson)
10. **Deterministic simulation testing is the gold standard** for verifying
    concurrent system correctness

---

## Implementation Summary Table

| System | Language | Model | Scheduling | io_uring | Production | Key Strength |
|--------|----------|-------|-----------|----------|------------|--------------|
| Tokio | Rust | M:N work-stealing | Cooperative + budget | No (epoll) | Massive | Ecosystem, maturity |
| Glommio | Rust | Thread-per-core | Cooperative shares | Yes (3 rings) | Limited | Architecture purity |
| Monoio | Rust | Thread-per-core | Cooperative | Yes | ByteDance | Raw throughput |
| Compio | Rust | Thread-per-core | Cooperative | Yes + IOCP | Apache Iggy | Cross-platform, maintained |
| smol | Rust | M:N | Cooperative | No | CLI tools | Simplicity |
| Seastar | C++ | Thread-per-core | Cooperative + quota | No (AIO/epoll) | ScyllaDB, Redpanda | Proven at scale |
| Taskflow | C++ | Work-stealing | DAG-aware | No | Academic + industry | Task graphs |
| PhotonLibOS | C++ | M:N stackful | Cooperative CACS | Yes | Alibaba Cloud | 1.52ns context switch |
| Go runtime | Go | M:N (GMP) | Cooperative + preemptive | No | Everywhere | Simplicity, goroutines |
| BEAM | Erlang | 1:1 per core | Preemptive (reductions) | No | Telecom, WhatsApp | Fairness, fault tolerance |
| libxev | Zig/C | Single-threaded | Event loop | Yes | Ghostty | Cross-platform proactor |
| Zap | Zig | Work-stealing pool | Wake-throttled | No | Bun | Resource efficiency |
| Tardy | Zig | Thread-local isolated | Cooperative stackful | Yes (+ epoll/kqueue/poll) | Alpha (zzz) | Memory efficiency, stackful coroutines |
| TigerBeetle | Zig | Single-threaded | Event loop | Yes | Financial DB | Deterministic testing |
| Crossbeam | Rust | Library (no runtime) | N/A | N/A | Everywhere | Lock-free primitives |
| Cilk/OpenCilk | C/C++ | Fork-join | Work-stealing | No | HPC | Theoretical optimality |
| Minicoro | C | Library (no runtime) | N/A | N/A | Nelua | Minimal, portable |
| May | Rust | M:N stackful | Cooperative | No | Niche | Go-style in Rust |


---

## Agent Session Transcripts

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-a545288d1fed1812b.jsonl`

Tardy research session (section 5.7, lessons, summary table entry):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-a3f8578084acbf5ce.jsonl`
