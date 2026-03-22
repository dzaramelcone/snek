# Event Loop & Async Runtime Reference

State-of-the-art survey of Python event loop implementations, custom async
runtimes, and native-code servers. Written as architectural context for snek's
own design (Zig runtime driving Python coroutines via `coro.send()`).

Last updated: 2026-03-21

---

## Table of Contents

1. [The `__await__` Protocol & `coro.send()` Mechanics](#1-the-await-protocol--corosend-mechanics)
2. [CPython's Default Event Loop (asyncio)](#2-cpythons-default-event-loop-asyncio)
3. [uvloop — libuv-based Drop-in Replacement](#3-uvloop--libuv-based-drop-in-replacement)
4. [curio — Trap-Based Coroutine Kernel](#4-curio--trap-based-coroutine-kernel)
5. [trio — Structured Concurrency Runtime](#5-trio--structured-concurrency-runtime)
6. [anyio — Backend-Agnostic Abstraction](#6-anyio--backend-agnostic-abstraction)
7. [granian — Rust HTTP Server for Python](#7-granian--rust-http-server-for-python)
8. [Robyn — Rust Runtime with Python Handlers](#8-robyn--rust-runtime-with-python-handlers)
9. [socketify.py — uWebSockets C API for Python](#9-socketifypy--uwebsockets-c-api-for-python)
10. [uvicorn & hypercorn — ASGI Server Bridges](#10-uvicorn--hypercorn--asgi-server-bridges)
11. [GIL Management in Native Event Loops](#11-gil-management-in-native-event-loops)
12. [Python 3.12+ Task Groups & Cancellation](#12-python-312-task-groups--cancellation)
13. [Python 3.13+ Free-Threading (no-GIL)](#13-python-313-free-threading-no-gil)
14. [Performance Comparison Table](#14-performance-comparison-table)
15. [How snek Compares](#15-how-snek-compares)
16. [Sources](#16-sources)

---

## 1. The `__await__` Protocol & `coro.send()` Mechanics

### The Core Mechanism

Every `await` expression in Python ultimately bottoms out in a `yield`. The chain
works as follows:

```
async def handler():
    result = await some_awaitable()
                   │
                   └─▶ some_awaitable.__await__() returns an iterator
                       │
                       └─▶ that iterator eventually yields a value
                           │
                           └─▶ the yield propagates up through yield-from
                               chain to whoever called coro.send()
```

### PEP 492 Specification (Key Points)

- **Native coroutines** (`async def`) have `.send()`, `.throw()`, `.close()` —
  same interface as generators.
- **`__await__`** must return an iterator. It is a `TypeError` if it returns
  anything else.
- Objects with `__await__` are called "Future-like objects."
- `asyncio.Future` simply sets `__await__ = __iter__` to participate.
- **Every `await` is suspended by a `yield` somewhere down the chain.** This is
  the fundamental invariant that makes custom runtimes possible.

### Driving a Coroutine Manually

```python
async def hello(name):
    print(f"Hello, {name}!")

coro = hello("world")
try:
    coro.send(None)        # start execution
except StopIteration:
    pass                   # coroutine completed
```

When a coroutine `await`s something that yields, `.send()` returns the yielded
value to the caller. The caller (the event loop / runtime) interprets it, does
work, then calls `.send(result)` to resume with the result.

### Custom Awaitables via `@types.coroutine`

```python
from types import coroutine

@coroutine
def sleep(seconds):
    yield ("sleep", seconds)    # sentinel tuple yielded to runtime

async def handler():
    await sleep(1.0)            # yields ("sleep", 1.0) to the driver
```

The yielded tuple is a **sentinel** — an instruction to the runtime. The runtime
interprets the tuple, performs the operation (timer, I/O, etc.), and calls
`.send(result)` to resume the coroutine.

### Minimal Event Loop

```python
def run(coro):
    result = None
    while True:
        try:
            sentinel = coro.send(result)
        except StopIteration as e:
            return e.value
        # interpret sentinel, perform I/O, set result
        result = handle_sentinel(sentinel)
```

### Relevance to snek

snek uses exactly this pattern. Python handlers are `async def` functions. snek
drives them via `coro.send()` from Zig. When the coroutine yields a sentinel
(e.g. `db_query`, `http_request`, `sleep`), snek's Zig runtime intercepts it,
performs the I/O natively, and resumes the coroutine with the result. **No asyncio
event loop is involved.** The Zig scheduler IS the event loop.

---

## 2. CPython's Default Event Loop (asyncio)

**URL:** https://github.com/python/cpython/blob/main/Lib/asyncio/base_events.py
**Language:** Python (with C accelerators)

### Architecture

```
asyncio.run()
  └─▶ loop.run_forever()
       └─▶ loop._run_once()  (called repeatedly)
            ├─▶ Process scheduled callbacks (loop._ready deque)
            ├─▶ Process timers (loop._scheduled heapq)
            └─▶ selector.select(timeout)  ← blocks for I/O
                 └─▶ epoll/kqueue/select depending on OS
```

### Key Internals

- **`_UnixSelectorEventLoop`** is the default on Unix. Uses `selectors` module
  which wraps epoll (Linux), kqueue (macOS), or select (fallback).
- **`ProactorEventLoop`** on Windows (IOCP-based).
- **`_run_once()`** is the hot loop. Recent optimization (CPython PR #110735)
  replaced `min()`/`max()` calls with comparison operators for a ~7-22%
  improvement in tight loops.
- **Callbacks** are the primitive. Coroutines are wrapped in `Task` objects that
  use `.__step()` to call `coro.send()` and schedule the next step as a callback.
- **`Task.__step()`** calls `result = coro.send(None)`, examines the result
  (which should be a `Future`), and adds a callback to that Future to call
  `__step()` again when it completes.

### Design Decisions

- Callback-centric design inherited from Tulip/PEP 3156.
- Heavy abstraction layers: AbstractEventLoop → BaseEventLoop →
  SelectorEventLoop → _UnixSelectorEventLoop.
- Supports pluggable event loop policies (deprecated in 3.12+).
- Thread-safe via `call_soon_threadsafe()`.
- Transport/Protocol pattern (from Twisted heritage).

### Performance Characteristics

- Pure Python hot paths (though some C accelerators exist for Task).
- `_run_once()` overhead: function call overhead for `min`/`max` was measurable
  at ~22% in microbenchmarks before optimization.
- Selector-based I/O: one syscall per `_run_once()` iteration for the select.
- No io_uring support (uses epoll on Linux).
- 2-4x slower than uvloop for networking workloads.

### Trade-offs

| Pro | Con |
|-----|-----|
| Standard library, zero deps | Slower than native alternatives |
| Huge ecosystem compatibility | Complex abstraction layers |
| Well-tested, many edge cases handled | Callback-based internals leak through |
| Pluggable (event loop policy) | Policy system is confusing, now deprecated |

### Relevance to snek

snek deliberately avoids asyncio's architecture. No callbacks, no Futures, no
Task wrappers. snek's coroutine driver calls `coro.send()` directly and
interprets sentinel objects, eliminating all the intermediate abstraction.

---

## 3. uvloop — libuv-based Drop-in Replacement

**URL:** https://github.com/MagicStack/uvloop
**Language:** Cython wrapping libuv (C)
**Author:** Yury Selivanov (also authored PEP 492, Python's async/await)

### Architecture

```
Python Application
       ↓
asyncio Module (Protocol/Transport API)
       ↓
uvloop Loop (Cython)
       ↓
libuv C Library
       ↓
OS Event Systems (epoll, kqueue, IOCP)
```

### Key Design Decisions

- **Drop-in replacement**: Implements `asyncio.AbstractEventLoop` fully. One line
  to switch: `asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())` or just
  `uvloop.run(main())`.
- **Cython for hot paths**: Direct C bindings without Python overhead. Type
  declarations enable C-level method resolution.
- **`nogil` sections**: Blocking I/O waits release the GIL. Event processing from
  libuv happens without GIL. Only re-acquires when calling Python callbacks.
- **Memory views**: Zero-copy data transfer in I/O operations.
- **Handle system**: Wraps libuv handles (UVHandle → UVSocketHandle → UVStream,
  UVPoll, UVTimer, UVSignal) with lifecycle management:
  `Uninitialized → Initialized → Active → Closing → Closed → Deallocated`.
- **Two-tier callbacks**: Immediate (deque-based, processed by idle handler) and
  delayed (libuv timer-based).
- **Context preservation**: `contextvars.copy_context()` captured at scheduling
  time, re-entered during execution.
- **Flow control**: High/low water marks for backpressure.

### Benchmark Claims

- **2-4x faster** than standard asyncio for networking.
- **2x faster** than Node.js, gevent.
- **22% faster** than Node.js in HTTP throughput (specific benchmark).
- P95/P99 tail latency improvements.
- Azure Functions (Python 3.13+) adopted uvloop as default — measurable
  throughput and latency improvements without regressions.
- Sanic + uvloop case study (Q1 2026): 8x RPS jump to 160k, p99 from 180ms to
  7ms, CPU down 40%.

### Production Exposure

Massive. Used by FastAPI/Starlette (via uvicorn), Sanic, aiohttp, Azure
Functions, and thousands of production services. ~31M monthly PyPI downloads.

### Trade-offs

| Pro | Con |
|-----|-----|
| 2-4x perf over asyncio | Still asyncio's abstraction layers |
| Drop-in, no code changes | libuv dependency (C library) |
| Battle-tested at scale | No Windows support |
| GIL-aware (nogil for I/O) | No io_uring (libuv uses epoll) |
| Same author as PEP 492 | Cython build complexity |

### Relevance to snek

uvloop is the performance bar to beat. It proves that moving the event loop to
native code (C via Cython) yields 2-4x improvement. snek goes further by also
moving HTTP parsing, routing, JSON parsing, and DB wire protocol to native code
(Zig), and eliminating the asyncio abstraction entirely.

Note: uvloop still uses epoll via libuv. snek uses io_uring on Linux, which
eliminates the syscall-per-event overhead via submission queue batching.

---

## 4. curio — Trap-Based Coroutine Kernel

**URL:** https://github.com/dabeaz/curio
**Language:** Pure Python
**Author:** Dave Beazley
**Status:** Abandoned (after 10 years, officially retired)

### Architecture: The Trap System

curio implements a kernel that drives coroutines via `send()`. Coroutines
communicate with the kernel by yielding **trap tuples** — a pattern identical
in concept to snek's sentinel system.

```python
from types import coroutine

@coroutine
def _trap_sleep(seconds):
    return (yield ("_trap_sleep", seconds))

@coroutine
def _trap_io(fileobj, event):
    return (yield ("_trap_io", fileobj, event))
```

The kernel receives the trap tuple via `coro.send()`, interprets it, performs the
requested operation, and resumes the coroutine with the result:

```python
# Simplified kernel loop
request = coro.send(None)
if request[0] == "_trap_sleep":
    # register timer, resume later
elif request[0] == "_trap_io":
    # register with selector, resume when ready
```

### Key Design Decisions

- **No callbacks.** Everything is coroutine-based. The kernel drives coroutines
  directly.
- **Curio does not perform I/O.** It is only responsible for waiting. I/O
  operations use standard library non-blocking calls; curio just manages the
  scheduling around `BlockingIOError`.
- **Traps are like syscalls.** The analogy to OS system calls is intentional —
  a trap suspends the running "process" (coroutine), the "kernel" handles the
  request, and control returns when complete.
- **Zero dependencies.** Pure Python, no C extensions.
- **Structured concurrency** via `TaskGroup` (predates trio's nurseries).

### I/O Interception Pattern

```python
async def accept_connection(s):
    while True:
        try:
            return s.accept()
        except BlockingIOError:
            await _read_wait(s)   # yields trap to kernel
```

### Trade-offs

| Pro | Con |
|-----|-----|
| Elegant, minimal design | Pure Python, inherently slower |
| Educational clarity | Abandoned, no maintenance |
| Proves coroutine driving works | Small ecosystem |
| Zero dependencies | Not asyncio-compatible |

### Relevance to snek

**curio's trap system is the direct intellectual ancestor of snek's sentinel
system.** The conceptual leap — that you can drive coroutines from an external
runtime by intercepting what they yield — was pioneered and proven by curio.
snek takes the same idea but moves the kernel from Python to Zig, and performs
I/O directly instead of delegating to Python's stdlib.

| curio | snek |
|-------|------|
| Python kernel | Zig scheduler |
| Trap tuples via yield | Sentinel objects via yield |
| stdlib non-blocking I/O | io_uring / kqueue native I/O |
| `_trap_sleep`, `_trap_io` | `Sentinel.sleep`, `Sentinel.db_query` |
| Pure Python | Zig + CPython C API |

---

## 5. trio — Structured Concurrency Runtime

**URL:** https://github.com/python-trio/trio
**Language:** Pure Python
**Author:** Nathaniel J. Smith (njs)

### Architecture

trio is a complete async runtime (not built on asyncio) with its own event loop,
scheduler, and I/O system. Its signature innovation is **nurseries** for
structured concurrency.

```python
async with trio.open_nursery() as nursery:
    nursery.start_soon(task_a)
    nursery.start_soon(task_b)
# Both tasks guaranteed complete here
```

### Core Design: Checkpoints

Every async operation in trio is a **checkpoint** — simultaneously a
cancellation point AND a scheduling point. This is a deliberate divergence from
asyncio, where these concepts are separate and inconsistent.

The key invariant: **each trio primitive either always acts as a checkpoint or
never does, regardless of runtime conditions.** This is statically determinable
from source code.

### Internal Scheduler

- **`trio.lowlevel.wait_task_rescheduled(abort_fn)`** is the lowest-level
  blocking primitive. Every blockage ultimately goes through it.
- Before blocking, a task arranges for someone to call `reschedule(task, outcome)`
  later.
- The `abort_fn` callback handles cancellation: returns `Abort.SUCCEEDED` (clean
  cancel) or `Abort.FAILED` (can't cancel yet, wait for `reschedule()`).
- **I/O system**: Platform-specific `IOManager` implementations (EpollIOManager,
  KqueueIOManager, WindowsIOManager). Bypasses Python's `selectors` module to
  access raw OS APIs directly.
- **Strict layering**: `trio._core` is self-contained (scheduler + I/O).
  Higher-level modules only use public APIs.

### Key Design Decisions

- **No callbacks.** Coroutine-native, like curio.
- **Structured concurrency**: Tasks cannot outlive their nursery. Exceptions
  propagate reliably.
- **Correctness over speed**: Latency consistency prioritized over raw throughput.
  Microbenchmarks deliberately deprioritized.
- **Static checkpoint semantics**: Developers can reason about cancellation by
  reading code, not understanding runtime state.

### Trade-offs

| Pro | Con |
|-----|-----|
| Strongest correctness guarantees | Slower than uvloop |
| Structured concurrency pioneer | Smaller ecosystem than asyncio |
| Excellent cancellation semantics | Not asyncio-compatible |
| Clean, layered internals | Pure Python perf ceiling |

### Relevance to snek

trio's `wait_task_rescheduled` + `reschedule()` pattern is conceptually close to
snek's coroutine suspend/resume. When a snek coroutine yields a sentinel, the
Zig runtime "reschedules" it when the I/O completes — same concept, different
implementation language.

trio's cancellation model (CancellationToken, abort protocol) is worth studying
for snek's own cancellation design (currently [OPEN] in design.md).

---

## 6. anyio — Backend-Agnostic Abstraction

**URL:** https://github.com/agronholm/anyio
**Language:** Pure Python
**Author:** Alex Grönholm

### Architecture

anyio provides a unified API that works identically on both asyncio and trio
backends. It acts as a compatibility layer — "USB-C for event loops."

### Key Features

- **CancelScope**: Unified cancellation semantics across both backends.
- **Task groups**: Structured concurrency for asyncio (backported from trio's
  nursery concept).
- **Backend auto-detection**: Uses whatever event loop is running.
- **Thread/process integration**: Unified API for running sync code in threads.

### Implementation

- **AsyncIO backend**: Wraps asyncio primitives, adds structured concurrency.
- **Trio backend**: Thin wrapper over trio's native APIs.
- Each backend implements the same abstract interface.

### Production Exposure

Used by FastAPI (via Starlette), Prefect, and many other frameworks. Heavy
production use.

### Relevance to snek

anyio demonstrates the value of a clean async API abstraction. snek's Python API
(`app.db.fetch()`, `app.sleep()`, etc.) serves a similar role — it presents a
clean async interface while the underlying runtime is completely different
(Zig, not asyncio or trio).

---

## 7. granian — Rust HTTP Server for Python

**URL:** https://github.com/emmett-framework/granian
**Language:** Rust + Python (via PyO3)
**Protocols:** ASGI/3, RSGI (custom Rust protocol), WSGI

### Architecture

```
TCP Connection
  ↓
Rust Tokio Runtime (async I/O, HTTP parsing)
  ↓
CallbackScheduler (GIL-aware bridge)
  ↓
Python Application Code
```

### Key Design Decisions

- **Separate Rust runtime**: Rust handles ALL networking. Python only executes
  application logic.
- **CallbackScheduler**: Bridge between Rust and Python. Manages GIL
  acquisition/release and uses `call_soon_threadsafe()` for thread-safe callback
  scheduling.
- **Three thread categories**:
  - Rust threads: Network I/O, event processing
  - Blocking threads: CPU-intensive operations
  - Python threads: Application code execution (dedicated to prevent GIL
    contention with I/O)
- **Two concurrency modes**:
  - Single-threaded (st): N single-threaded Tokio runtimes. Better with few
    processes.
  - Multi-threaded (mt): One multi-threaded Tokio runtime with N threads. Scales
    better with many CPUs.
- **Backpressure**: Semaphore-based connection limiting per worker.

### Coroutine/Future Bridging

Granian implements two strategies for bridging Rust futures with Python
awaitables:

1. **`PyIterAwaitable`** (iterator-based): ~55% faster for quick operations.
   Uses bare `yield` approach.
2. **`PyFutureAwaitable`** (future-like): More efficient for long-running
   operations. Supports cancellation.

Both implement `__await__`, `__iter__`, `__next__` — the standard Python
awaitable protocol.

### RSGI Protocol

Granian defines its own protocol (RSGI) for tighter Rust integration, avoiding
ASGI's dict-copying overhead.

### Performance

- Highest req/s in some benchmarks.
- Average-to-max latency ratio of ~2.8x (vs uvicorn's 6.8x gap) — more
  consistent tail latency.

### Production Exposure

Growing adoption. Used by the Emmett framework. Active development.

### Relevance to snek

granian is the closest existing project to snek's architecture:

| granian | snek |
|---------|------|
| Rust (Tokio) runtime | Zig runtime |
| PyO3 bridge | CPython C API bridge |
| `PyIterAwaitable` / `PyFutureAwaitable` | Sentinel objects via `coro.send()` |
| RSGI custom protocol | Custom sentinel protocol |
| Tokio async I/O | io_uring / kqueue |
| Semaphore backpressure | Work-stealing scheduler |

Key difference: granian still uses Python's awaitable protocol with asyncio-like
futures. snek uses raw `coro.send()` with sentinel interception — no futures, no
asyncio compatibility layer.

---

## 8. Robyn — Rust Runtime with Python Handlers

**URL:** https://github.com/sparckles/Robyn
**Language:** Rust (Actix-web + Tokio) + Python (PyO3)

### Architecture

```
HTTP Request → Rust Parser → Rust Router (matchit) → Parameter Extraction (Rust)
  → Python Handler (via PyO3) → Response Processing (Rust) → HTTP Response
```

Two-layer design:
- **Python layer**: Developer-facing API, routing config, business logic.
- **Rust layer**: HTTP parsing, routing, response generation, I/O.

### Key Design Decisions

- **No separate ASGI server needed.** Robyn IS the server. Unlike FastAPI (which
  needs uvicorn), Robyn has its own Rust-based server runtime.
- **Actix-web + Tokio**: Battle-tested Rust HTTP and async runtime.
- **PyO3 bindings**: Function registration at import time. Rust calls back into
  Python for handler execution.
- **Const routes**: Cached responses served entirely from Rust, bypassing Python
  when no middleware exists.
- **Zero-copy**: Request bodies parsed once and shared between layers. String
  data referenced rather than copied.
- **Dual handler support**: Async handlers run in async runtime; sync handlers
  run in a thread pool.

### Performance

- Comparable to pure Rust web frameworks (per documentation claims).
- A few milliseconds faster response times than FastAPI in benchmarks.
- Better concurrency under GIL pressure due to Rust handling network I/O.

### Production Exposure

Active development, growing community. v1.0 milestone reached.

### Relevance to snek

Robyn proves the architecture works: Rust runtime handles I/O, calls back into
Python for handlers. snek does the same with Zig. Key difference: Robyn uses
Actix-web (a full Rust HTTP framework), while snek implements HTTP parsing in
Zig directly. Robyn's const-route optimization is worth considering for snek.

---

## 9. socketify.py — uWebSockets C API for Python

**URL:** https://github.com/cirospaciari/socketify.py
**Language:** C/C++ (uWebSockets) + Python (CFFI)

### Architecture

socketify.py wraps uWebSockets (the C++ library that powers Bun.js) via a
custom C API, using CFFI for Python bindings.

### Key Design Decisions

- **Created a full C API for uWebSockets** (uWebSockets only had a C++ API).
  Same C API foundation used by Bun.
- **CFFI over Cython**: Enables PyPy3 support (Cython only works with CPython).
- **Plans for custom libuv + asyncio integration** (not using uvloop, which
  doesn't support Windows/PyPy3).
- **Both sync and async handlers** supported.

### Benchmark Claims

- HTTP: **770k req/s** (PyPy3), vs 582k for Japronto.
- WebSocket: **~900k msg/s** (PyPy3), **860k msg/s** (CPython).
- Matches Bun.js performance for WebSockets.
- TLS 1.3 faster than most servers' unencrypted performance.

These are microbenchmarks (TechEmPower, wrk with 16x pipelining).

### Production Exposure

Active development. Cross-platform (Windows, Linux, macOS Silicon/x64).

### Relevance to snek

socketify.py demonstrates that wrapping a C/C++ I/O library and driving Python
from it can match JavaScript runtimes. snek's approach is similar in spirit but
uses Zig instead of C++ and implements the networking stack directly rather than
wrapping an existing library.

---

## 10. uvicorn & hypercorn — ASGI Server Bridges

### uvicorn

**URL:** https://github.com/Kludex/uvicorn
**Language:** Python

- ASGI server that bridges HTTP to ASGI applications.
- Uses **uvloop** (optional) for the event loop and **httptools** (C-based HTTP
  parser) for performance.
- With `--loop uvloop` and `--http httptools`: fast path.
- With `--loop asyncio` and `--http h11`: pure Python fallback.
- Default: auto-detect best available.

### hypercorn

**URL:** https://github.com/pgjones/hypercorn
**Language:** Python

- ASGI server supporting HTTP/1.1, HTTP/2, WebSocket.
- Supports both asyncio and **trio** as backends.
- Can use uvloop with asyncio backend.

### Architecture Pattern

Both follow the same pattern:
1. Event loop (asyncio/uvloop/trio) handles I/O.
2. HTTP parser (httptools/h11) converts bytes to ASGI events.
3. ASGI protocol bridges events to the Python application.

### Relevance to snek

snek eliminates the need for a separate ASGI server. It IS the server. The ASGI
dict-copying protocol is replaced by direct Python object creation in Zig. This
removes an entire layer of overhead.

---

## 11. GIL Management in Native Event Loops

### The Pattern

Native event loops (C/Cython/Rust/Zig) must carefully manage the GIL:

1. **Acquire GIL** before calling any Python code (CPython C API calls).
2. **Release GIL** during I/O waits and pure native computation.
3. **Re-acquire GIL** to deliver results back to Python.

### C API Mechanisms

```c
// Simple release/acquire for blocking calls
Py_BEGIN_ALLOW_THREADS
// ... native code, I/O, etc. No Python calls here.
Py_END_ALLOW_THREADS

// Thread-state-aware acquire for callbacks from native threads
PyGILState_STATE gstate = PyGILState_Ensure();
// ... call Python code
PyGILState_Release(gstate);
```

### How Each System Handles It

| System | GIL Strategy |
|--------|-------------|
| **uvloop** | `nogil` Cython sections for I/O. Re-acquire for callbacks. |
| **granian** | `CallbackScheduler` manages GIL. Python runs on dedicated blocking threads. |
| **Robyn** | PyO3 handles GIL. Rust threads don't hold GIL; acquire only for handler calls. |
| **socketify.py** | CFFI handles GIL transitions automatically. |
| **snek** | Acquire GIL to call `coro.send()`. Release during Zig I/O. Per-I/O-operation granularity (~50-100ns per acquire/release). |

### snek's GIL Strategy (from design.md)

- Acquire GIL to call Python (`coro.send()`).
- Release GIL when coroutine yields sentinel (I/O operation begins).
- Re-acquire GIL when I/O completes and it's time to resume the coroutine.
- **Per I/O operation**: More concurrency, ~50-100ns overhead per cycle.
- Warning logged if GIL held > 100ms (CPU-bound handler detected).
- Free-threaded mode (no-GIL) deferred to a flag-based opt-in.

### Zig-Specific Tooling

- **ziggy-pydust**: Framework for writing Python extensions in Zig. Provides GIL
  management, buffer protocol, and type conversions.
- **py.zig**: Lightweight alternative for Zig-Python bindings.
- Both leverage Zig's compile-time features for zero-overhead FFI.
- snek uses direct CPython C API calls from Zig (not pydust/py.zig).

---

## 12. Python 3.12+ Task Groups & Cancellation

### `asyncio.TaskGroup` (Python 3.11+)

```python
async with asyncio.TaskGroup() as tg:
    task1 = tg.create_task(fetch_users())
    task2 = tg.create_task(fetch_posts())
# Both complete or all cancelled on exception
```

- Stronger than `asyncio.gather()`: if one task raises, remaining tasks are
  cancelled.
- ExceptionGroup collects multiple exceptions.
- **Python 3.13**: Improved handling of simultaneous internal/external
  cancellations. Preserves cancellation count correctly.

### Eager Task Execution (Python 3.12)

```python
task = asyncio.eager_task_factory(loop, coro)
```

If the event loop is running, the task starts executing immediately until it
first blocks. If it completes without blocking, it skips scheduling entirely.
This eliminates a round-trip through the event loop for fast-completing
coroutines.

### Cancellation Scopes

Not in stdlib asyncio. Available via:
- **trio**: Native cancellation scopes with deadlines.
- **anyio**: `CancelScope` that works on both asyncio and trio backends.

### Relevance to snek

snek's `app.gather()` parallels `TaskGroup` — it yields multiple sentinel ops
to the scheduler, which submits all I/O concurrently and resumes the coroutine
when all complete. snek should consider eager execution (avoiding scheduler
round-trips for fast operations) and cancellation scopes (currently [OPEN]).

---

## 13. Python 3.13+ Free-Threading (no-GIL)

### PEP 703: Making the GIL Optional

- **CPython 3.13**: Experimental `--disable-gil` build flag.
- **CPython 3.14**: No longer experimental (PEP 779), but not yet default.
- Uses biased reference counting, immortalization, and deferred reference
  counting for thread safety.

### Performance Impact

- ~40% overhead on pyperformance suite in 3.13 (free-threaded build vs GIL
  build).
- I/O-heavy and C-extension-heavy programs see less impact.
- Expected to improve in future releases.

### Implications for Native Event Loops

With free-threading:
- Threads can run Python truly in parallel.
- `WSGI + ThreadPool` becomes viable for parallelism without process forking.
- `ASGI + event loop` overhead changes — the event loop's single-threaded
  advantage (no locking) loses value when threads can run in parallel anyway.
- Native extensions (Zig, Rust, C) that release the GIL already benefit from
  parallelism; free-threading helps pure Python code.

### Implications for snek

snek's design (GIL acquire per I/O operation, release during Zig work) already
maximizes parallelism under the GIL. With free-threading:
- Multiple Python handlers could run in parallel on different Zig worker threads.
- No GIL acquire/release overhead.
- BUT: Python objects accessed from multiple threads need thread-safe handling.
- **Recommendation (from design.md)**: Target GIL mode first. Free-threaded as
  a flag later.

### PyO3 Free-Threading Support

PyO3 (Rust-Python bindings) already has experimental free-threading support,
proving the pattern works for native runtimes calling into Python.

---

## 14. Performance Comparison Table

All numbers are approximate and benchmark-dependent. Treat as relative
indicators, not absolute measures.

### HTTP Request Throughput (req/s, single machine)

| System | req/s | Notes |
|--------|-------|-------|
| socketify.py + PyPy3 | ~770k | wrk, 16x pipelining |
| socketify.py + CPython | ~860k ws/s | WebSocket benchmark |
| Japronto | ~582k | Unmaintained since 2020 |
| Sanic + uvloop | ~160k | Real-world case study (2026) |
| granian (Rust) | Highest in some benchmarks | ASGI + RSGI |
| uvloop (raw) | 2-4x asyncio | Echo server benchmarks |
| asyncio (CPython) | Baseline | Pure Python |
| Node.js | ~0.78x uvloop | uvloop 22% faster |

### Latency Characteristics

| System | Latency Profile |
|--------|----------------|
| granian | avg/max ratio ~2.8x (consistent) |
| uvicorn (uvloop) | avg/max ratio ~6.8x (more variance) |
| Sanic + uvloop | p99 = 7ms (from 180ms pre-migration) |
| trio | Prioritizes latency consistency over throughput |

### WebSocket Messages/sec

| System | msg/s |
|--------|-------|
| socketify.py + PyPy3 | ~900k |
| socketify.py + CPython | ~860k |
| Bun.js | ~900k (matches socketify) |
| Node.js | ~192k |
| Falcon + PyPy3 | ~56k |

---

## 15. How snek Compares

### snek's Unique Position

snek occupies a novel position in this landscape:

```
                    ┌─────────────────────┐
                    │   NATIVE RUNTIME    │
                    │   (Zig scheduler,   │
                    │    io_uring/kqueue,  │
                    │    HTTP parser,      │
                    │    JSON parser,      │
                    │    DB wire protocol) │
                    └────────┬────────────┘
                             │
                    coro.send() / sentinel yield
                             │
                    ┌────────▼────────────┐
                    │   PYTHON HANDLERS   │
                    │   (async def,       │
                    │    pydantic models,  │
                    │    business logic)   │
                    └─────────────────────┘
```

### Comparison with Nearest Relatives

| Feature | asyncio | uvloop | curio | trio | granian | Robyn | snek |
|---------|---------|--------|-------|------|---------|-------|------|
| Runtime language | Python | Cython/C | Python | Python | Rust | Rust | **Zig** |
| I/O backend | epoll/kqueue | libuv | selectors | epoll/kqueue | Tokio | Tokio | **io_uring/kqueue** |
| Event loop model | Callbacks | Callbacks | Traps (yield) | Checkpoints | Tokio tasks | Tokio tasks | **Sentinels (yield)** |
| HTTP parser | — | — | — | — | hyper (Rust) | Actix | **Custom Zig** |
| DB wire protocol | — | — | — | — | — | — | **Postgres in Zig** |
| JSON parser | — | — | — | — | — | — | **Custom Zig** |
| asyncio compatible | Yes | Yes | No | No | Via ASGI | No | **No** |
| Coroutine driving | Task.__step | Task.__step | Kernel send() | Scheduler | PyIterAwaitable | PyO3 callback | **coro.send()** |
| GIL strategy | N/A (Python) | nogil sections | N/A | N/A | Dedicated threads | PyO3 | **Per-I/O acquire/release** |

### snek's Advantages

1. **Deepest native integration**: Not just I/O — HTTP parsing, routing, JSON,
   DB wire protocol all in Zig. Other systems delegate at least some of these
   to Python.
2. **io_uring**: Submission queue batching eliminates per-event syscalls. Neither
   uvloop (epoll via libuv) nor granian (Tokio, which uses epoll) uses io_uring.
3. **No asyncio overhead**: No Task wrappers, no Future objects, no callback
   scheduling. Raw `coro.send()` with sentinel interception.
4. **Work-stealing scheduler**: Chase-Lev deques for load balancing across
   worker threads. Most Python async systems are single-threaded per process.
5. **Comptime pipeline builder**: Zig's comptime generates state machines from
   step sequences, eliminating runtime dispatch overhead.
6. **Unified stack**: One binary handles everything — no separate ASGI server,
   no reverse proxy needed for most use cases.

### snek's Risks

1. **Ecosystem isolation**: Not asyncio-compatible means no existing async
   library works (no aiohttp, no motor, etc.). Users are locked into snek's
   awaitables.
2. **Untested at scale**: All competitors have years of production exposure.
3. **CPython C API surface**: Large, complex, and version-sensitive. abi3 helps
   but limits available APIs.
4. **Zig maturity**: Zig is pre-1.0. Compiler and stdlib may change.
5. **Free-threading future**: If CPython goes fully free-threaded, the
   per-I/O-op GIL cycling overhead disappears and snek needs a different
   concurrency model for Python execution.

---

## 16. Sources

### Implementations

- [uvloop (GitHub)](https://github.com/MagicStack/uvloop)
- [uvloop architecture (DeepWiki)](https://deepwiki.com/MagicStack/uvloop)
- [curio (GitHub)](https://github.com/dabeaz/curio)
- [curio internals](https://curio-fork-azhukov.readthedocs.io/en/latest/devel.html)
- [trio (GitHub)](https://github.com/python-trio/trio)
- [trio design doc](https://trio.readthedocs.io/en/stable/design.html)
- [trio lowlevel](https://trio.readthedocs.io/en/stable/reference-lowlevel.html)
- [anyio (GitHub)](https://github.com/agronholm/anyio)
- [granian (GitHub)](https://github.com/emmett-framework/granian)
- [granian worker architecture (DeepWiki)](https://deepwiki.com/emmett-framework/granian/2.3-worker-architecture)
- [Robyn (GitHub)](https://github.com/sparckles/Robyn)
- [Robyn architecture deep dive](https://robyn.tech/documentation/en/api_reference/architecture_deep_dive)
- [socketify.py (GitHub)](https://github.com/cirospaciari/socketify.py)
- [uvicorn (GitHub)](https://github.com/Kludex/uvicorn)
- [CPython asyncio base_events.py](https://github.com/python/cpython/blob/main/Lib/asyncio/base_events.py)
- [CPython _run_once optimization (Issue #110733)](https://github.com/python/cpython/issues/110733)

### Specifications

- [PEP 492 — Coroutines with async and await syntax](https://peps.python.org/pep-0492/)
- [PEP 703 — Making the GIL Optional](https://peps.python.org/pep-0703/)
- [Python asyncio event loop docs](https://docs.python.org/3/library/asyncio-eventloop.html)
- [Python free-threading howto](https://docs.python.org/3/howto/free-threading-python.html)

### Educational

- [A Tale of Event Loops (GitHub)](https://github.com/AndreLouisCaron/a-tale-of-event-loops)
- [Dave Beazley talks](https://www.dabeaz.com/talks.html)
- [A Curious Course on Coroutines and Concurrency](http://www.dabeaz.com/coroutines/)

### Benchmarks & Analysis

- [uvloop blog post — Blazing fast Python networking](https://magic.io/blog/uvloop-blazing-fast-python-networking/)
- [socketify.py benchmarks (DEV.to)](https://dev.to/cirospaciari/socketifypy-maybe-the-fastest-web-framework-for-python-and-pypy-57ba)
- [Azure Functions + uvloop (Microsoft)](https://techcommunity.microsoft.com/blog/appsonazureblog/faster-python-on-azure-functions-with-uvloop/4455323)
- [Python Application Servers 2026 (DeployHQ)](https://www.deployhq.com/blog/python-application-servers-in-2025-from-wsgi-to-modern-asgi-solutions)
- [uvloop still faster? (Python.org discussion)](https://discuss.python.org/t/is-uvloop-still-faster-than-built-in-asyncio-event-loop/71136)

### Zig-Python Integration

- [ziggy-pydust (GitHub)](https://github.com/spiraldb/ziggy-pydust)
- [py.zig (GitHub)](https://github.com/codelv/py.zig)
- [PyO3 free-threading support](https://pyo3.rs/v0.27.2/free-threading.html)
- [Releasing the GIL (Thomas Nyberg)](https://thomasnyberg.com/releasing_the_gil.html)


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-a117bee1eddd5eca7.jsonl`
