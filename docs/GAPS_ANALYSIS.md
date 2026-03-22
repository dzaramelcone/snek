# Gaps Analysis: 10 Topics Across Reference & Insight Files

Systematic review of all REFERENCES.md and INSIGHTS.md files in the snek project.
Generated 2026-03-21.

---

## 1. Background Tasks / Fire-and-Forget

### Findings

**`python/snek/REFERENCES_di.md`** -- Identifies background tasks as a critical gap in FastAPI's DI system:

> "**No DI outside HTTP**: Background tasks, CLI commands, scheduled jobs, workers -- none of these have access to the `Depends()` system. You must manually wire dependencies."

> "`IServiceScopeFactory` (ASP.NET Core) and `ObjectProvider` (Spring) let you create scopes in background tasks, CLI tools, etc. FastAPI has no equivalent."

**`refs/bun/INSIGHTS.md`** -- Documents Bun's threading model with task dispatch patterns relevant to background work:

> "The event loop (`EventLoop`) has: A regular task queue, `immediate_tasks` / `next_immediate_tasks` (double-buffered for setImmediate), `concurrent_tasks` -- an MPSC queue for tasks posted from other threads, `deferred_tasks` -- tasks deferred until after current tick"

The `@fieldParentPtr` intrusive task pattern and MPSC queue design are directly applicable for fire-and-forget task dispatch.

**`refs/tigerbeetle/INSIGHTS.md`** -- Completion-based async with type-erased callbacks:

> "Type erasure via comptime: The `erase_types` function generates a type-erased wrapper at comptime. The user-facing API is fully typed [...] But internally stores `?*anyopaque` + function pointer. This is the core pattern for Zig async without allocators."

**`src/db/REFERENCES.md`** -- tokio-postgres uses a spawned background task for connection I/O:

> "`Connection` -- background task handling actual I/O on the Tokio runtime"
> "Split Client/Connection enables clean async model but requires the Connection to be spawned as a separate task"

### Assessment

**INSUFFICIENT.** No file addresses the specific design of a background task API for Python web handlers (e.g., spawning work that outlives the request, with proper GIL management, cancellation, and resource cleanup). The threading/task primitives from Bun and TigerBeetle are relevant building blocks, but the Python-side API design (how a handler spawns background work, how it interacts with DI scopes, how errors are reported) is unresearched.

**Needed research:**
- Starlette's `BackgroundTask` / `BackgroundTasks` API and its limitations
- Celery/Dramatiq/ARQ task queue patterns
- How to bridge Zig worker threads with Python coroutine-spawned background work
- Scope management for DI in non-request contexts

---

## 2. Request Context Propagation

### Findings

**`src/http/REFERENCES_middleware.md`** -- Documents the critical Starlette/ASGI bug and the importance of contextvars:

> "**ContextVar propagation broken.** `BaseHTTPMiddleware` prevents `contextvars.ContextVar` changes from propagating upwards. If an endpoint sets a context variable, middleware reading it sees a stale value. This is a fundamental architectural flaw."

> "Context variable propagation MUST work through middleware -- it's essential for modern Python."

Also documents request-scoped state patterns across frameworks:

> "Request extensions (`http::Extensions`) serve as a typed key-value map for request-scoped state." (Axum/Tower)

> Gin (Go): "`Copy()` for goroutine safety. Context must be cloned for use outside request scope."

> ASP.NET Core: "**HttpContext is the universal context.** All request-scoped state flows through it (Items dictionary, Features collection, User principal)."

**`python/snek/REFERENCES_di.md`** -- Documents request-scoped DI patterns:

> "Request scope propagates up the dependency chain -- if a controller depends on a request-scoped service, the controller also becomes request-scoped." (NestJS)

> "Thread-local scoping for async: Doesn't work. Async tasks share threads. Use proper async-aware scoping (contextvars in Python, AsyncLocal in .NET)."

**`src/python/REFERENCES.md`** -- PyO3 async bridging preserves contextvars:

> "Supports task cancellation and contextvars preservation (0.15+)"

### Assessment

**PARTIALLY SUFFICIENT.** The middleware reference clearly identifies the problem (Starlette's broken contextvars) and documents how other frameworks handle request context. The DI reference covers scoping well. However, there is no specific design for how snek will implement request context propagation -- specifically how Zig-side per-request state maps to Python-side contextvars, and how to ensure propagation works correctly through snek's middleware chain.

**Needed research:**
- Concrete design for snek's request context: what lives in Zig (arena, connection state), what lives in Python (contextvars), and how they connect
- How contextvars interact with Zig-managed worker threads (do they need to be copied/restored?)

---

## 3. DBAPI 2.0 / PEP 249

### Findings

**`src/db/REFERENCES.md`** -- Contains a complete section (Section 15) on DBAPI 2.0 compliance:

> Required module-level items: `connect()`, `apilevel`, `threadsafety`, `paramstyle`

Documents the full error hierarchy, connection object methods (`close()`, `commit()`, `cursor()`), cursor object requirements (`description`, `rowcount`, `arraysize`, `execute()`, `fetchone()`, `fetchmany()`, `fetchall()`), type constructors, and optional extensions.

Also documents that asyncpg deliberately does NOT comply:

> "**Not DB-API 2.0 compliant** -- deliberately exposes PostgreSQL features directly rather than hiding behind generic facade"

While psycopg3 is compliant:

> "**DB-API 2.0 compliant** -- unlike asyncpg"

### Assessment

**SUFFICIENT.** The PEP 249 specification is fully documented. The trade-off between compliance (psycopg3) and performance/expressiveness (asyncpg) is clearly laid out. The reference provides enough detail to implement a DBAPI-compliant layer if desired, or to make an informed decision to skip it.

---

## 4. Backpressure

### Findings

**`refs/tigerbeetle/INSIGHTS.md`** -- Documents the three-queue architecture in detail:

> "**Three-queue architecture**: `unqueued` (waiting for SQE space), kernel (submitted), `completed` (ready for callbacks). This prevents starvation and ensures fairness."

> "**Callback batching**: Completions are NOT invoked inline during CQE processing. They're collected into a linked list and invoked later. This avoids recursion, unbounded stack usage, and confusing stack traces."

**`src/net/REFERENCES_websocket.md`** -- Comprehensive WebSocket backpressure coverage:

> "Three-state `SendStatus` enum: `SUCCESS`, `BACKPRESSURE`, `DROPPED`. Configurable `maxBackpressure` threshold."

Documents patterns across uWebSockets, ws (Node.js), gorilla/websocket, coder/websocket, and Axum. General principles:

> "1. **Always expose buffered amount**: Callers need visibility into send queue. 2. **Configurable limits**: Drop vs. close vs. block are all valid strategies. 3. **Cork/batch writes**: Reduce syscalls by batching frame header + payload. 4. **Separate slow consumers**: Per-connection buffers prevent one slow consumer from blocking others."

**`src/serve/REFERENCES.md`** -- Back-pressure in streaming section:

> "Async frameworks accept unlimited connections by default. Without explicit limits, 10,000 concurrent connections competing for a 50-connection database pool causes catastrophic queuing."

Documents TCP flow control, HTTP/2 flow control, tower's `poll_ready()`, bounded channels, and nginx as a backpressure proxy. Design patterns:

> "1. **Semaphore-based**: acquire token before processing; return 503 with `Retry-After` when exhausted. 2. **Readiness checks**: query service capacity before committing (tower pattern). 3. **Bounded queues**: fixed-size channel between producer/consumer stages. 4. **Write polling**: only produce data when downstream is ready to consume"

**`src/http/REFERENCES_middleware.md`** -- Tower's `poll_ready` as backpressure mechanism:

> "`poll_ready` for backpressure. Services explicitly signal capacity before accepting requests. This enables load shedding, rate limiting, connection pool management."

Also notes that Axum removed `poll_ready`:

> "`poll_ready` removal: backpressure is pushed to dedicated middleware at the front of the chain, or handled at service creation time."

### Assessment

**SUFFICIENT.** TigerBeetle's three-queue architecture is thoroughly documented and explicitly recommended for adoption. WebSocket, HTTP streaming, and middleware-level backpressure patterns are all well-covered. The research provides concrete implementation guidance across multiple levels (kernel, protocol, application).

---

## 5. LISTEN/NOTIFY

### Findings

**`src/db/REFERENCES.md`** -- Mentioned only in pgx's architecture overview:

> "pgx.Conn -- high-level driver, ~70 type conversions, LISTEN/NOTIFY, COPY"

**`src/db/REFERENCES.md`** (pgwire section) -- Notifications listed as a supported protocol feature:

> "Protocol Coverage: [...] Notifications"

No other file discusses LISTEN/NOTIFY patterns, dedicated connection strategies, or how to integrate Postgres pub/sub with a web framework's event system.

### Assessment

**INSUFFICIENT.** LISTEN/NOTIFY is mentioned only in passing as a feature that pgx and pgwire support. There is no research on:
- Dedicated connection patterns (a LISTEN connection cannot be pooled)
- How to bridge Postgres notifications to WebSocket clients
- Connection lifecycle management for long-lived LISTEN connections
- asyncpg's `add_listener()` API and its implementation
- Fan-out patterns (one LISTEN connection distributing to many WebSocket connections)

**Needed research:**
- asyncpg and psycopg3 LISTEN/NOTIFY APIs
- Dedicated connection vs. stealing a pool connection
- Integration with snek's event loop (how Zig-side notification receipt triggers Python callbacks)
- Comparison with Redis pub/sub for the same use cases

---

## 6. Multipart Parsing

### Findings

**`src/serve/REFERENCES.md`** -- Comprehensive Section 3 covering multipart form parsing:

Documents implementations across C (multipart-parser-c), Rust (multer, mime-multipart, multipart-stream-rs), Go (mime/multipart), and Node.js (busboy, formidable).

Key patterns:

> multipart-parser-c: "callback-driven streaming parser [...] internal buffer never exceeds boundary size (~60-70 bytes)"

> multer (Rust): "async streaming parser; accepts `Stream<Item = Result<Bytes>>` input [...] configurable field size limits to prevent DoS/memory exhaustion"

> Go stdlib: "Max 10,000 headers per part, Max 10,000 total FileHeaders, Max 1,000 parts per form"

Section 6 covers large file upload handling including TUS protocol and server-side strategies.

Summary recommendations:

> "Use callback-driven streaming parser (multer/multipart-parser-c pattern). Never buffer entire body in memory. Enforce per-field and total size limits. Stream file parts directly to destination."

**`refs/http.zig/INSIGHTS.md`** -- Documents http.zig's lazy multipart parsing:

> "Lazy fields: `qs` (query string), `fd` (form data), `mfd` (multipart form data) -- only parsed when accessed via `req.query()`, `req.formData()`, etc."

### Assessment

**SUFFICIENT.** The multipart parsing landscape is well-documented with implementation references across all relevant languages. The streaming parser pattern, memory limits, and large file upload strategies are all covered. The http.zig lazy parsing pattern provides a concrete Zig-side reference.

---

## 7. Graceful Shutdown / Drain

### Findings

**`tests/REFERENCES_verification.md`** -- Formal specification of graceful shutdown properties:

> "**What:** All in-flight requests complete (or timeout). All connections are closed. All resources are freed. Shutdown completes in bounded time."

> "**Key properties:** `after_shutdown_signal: eventually(all_connections_closed)` (liveness), `after_shutdown_signal: no_new_connections_accepted` (safety), `shutdown_completes_within(timeout)` (bounded liveness)"

Recommends TLA+ modeling and deterministic simulation for verification.

**`refs/tigerbeetle/INSIGHTS.md`** -- Cancel-all pattern:

> "**Graceful shutdown via `cancel_all`**: Walks the `awaiting` doubly-linked list, cancels each in-flight operation one by one, waits for completion."

**`src/db/REFERENCES.md`** -- PgCat contributed graceful shutdown:

> "Contributed multiple pools per instance and graceful shutdown features"

**`src/net/REFERENCES_websocket.md`** -- HTTP/2 clean shutdown and reconnection storms:

> "**Clean shutdown**: RST_STREAM with CANCEL replaces abrupt TCP closes."

> "When a server restarts, all clients reconnect simultaneously. Mitigations: **Client**: Exponential backoff with jitter. **Server**: Rate limiting at TCP and application levels."

**`src/serve/REFERENCES.md`** -- nginx as drain proxy:

> "nginx acts as a buffer between slow clients and fast upstreams: Reads upstream response quickly, Buffers in memory/disk, Drains to slow client at client's pace, Frees upstream connection early"

### Assessment

**PARTIALLY SUFFICIENT.** The formal properties of graceful shutdown are well-specified, and building blocks exist (TigerBeetle's cancel-all, WebSocket reconnection storms, nginx drain). However, there is no concrete design for snek's shutdown sequence, which is more complex than most because it spans Zig worker threads, Python's asyncio event loop, database connections, and WebSocket connections.

**Needed research:**
- Concrete drain protocol: stop accepting -> drain HTTP/1.1 keep-alive -> send GOAWAY for HTTP/2 -> wait for in-flight -> timeout -> force close
- How to signal Python coroutines to finish (cancellation vs. deadline)
- WebSocket drain: close frame with code 1001 (Going Away) vs. just closing
- Interaction with process managers (systemd, gunicorn) and their SIGTERM handling

---

## 8. Hot Reload / Dev Mode

### Findings

**`src/security/REFERENCES.md`** -- Certificate hot-reloading patterns:

> "tls-hot-reload (Rust): Wait-free and lock-free TLS certificate hot-reload for rustls. Spawns file watchers that detect modifications and reload certificates without service interruption."

> "File watching (inotify/kqueue) is more responsive than polling."

**`refs/http.zig/INSIGHTS.md`** -- Jetzig has auto-reload:

> "Development server with auto-reload."

No other file addresses Python code hot-reload, file watching for `.py` changes, process restart strategies, or fast restart techniques.

### Assessment

**INSUFFICIENT.** Certificate hot-reload is covered, but application code hot-reload for development is not researched at all. This is a critical developer experience feature.

**Needed research:**
- watchdog (Python) / watchfiles (Rust-based) file watching libraries
- uvicorn's reload implementation (inotify/kqueue/polling, worker process restart)
- Full process restart vs. module reimport tradeoffs
- Fast restart: preserving listening socket across restarts (SO_REUSEPORT + fork/exec)
- Interaction with Zig compiled code (can't hot-reload Zig; only Python)
- StatReload (uvicorn) vs. WatchFilesReload strategies

---

## 9. Embedded Cache / In-Process KV

### Findings

**`refs/ghostty/INSIGHTS.md`** -- CacheTable: a fixed-size LRU cache:

> "**CacheTable**: Fixed bucket count (power of 2), Fixed bucket size, LRU eviction within each bucket, Zero heap allocation after initialization."

Verdict: "ADAPT -- useful for route caching, compiled regex caching, etc."

**`src/serve/REFERENCES_client.md`** -- HTTP client connection pool uses LRU:

> "**LRU connection pool**. Uses doubly-linked lists for both active (`used`) and idle (`free`) connections."

> "Matching is by host + port + protocol. When capacity is exceeded, the oldest idle connection is destroyed (LRU eviction)."

Also documents DNS cache TTL:

> "`CURLOPT_DNS_CACHE_TIMEOUT` | 60 seconds | DNS entry TTL in cache"

**`refs/tigerbeetle/INSIGHTS.md`** -- Set-associative cache with CLOCK eviction:

> "`SetAssociativeCacheType` with configurable `cache_line_size: u64 = 64`. Tags packed into cache lines. CLOCK eviction algorithm with configurable bit width."

### Assessment

**INSUFFICIENT.** While Ghostty's CacheTable and TigerBeetle's set-associative cache provide Zig-native building blocks, there is no research on in-process caching specifically for a web framework context:
- Route match caching (hot path optimization)
- Response caching (with TTL, invalidation, cache-control header parsing)
- Python-side caching patterns (cachetools, lru_cache limitations in async)
- Concurrent access patterns when Zig worker threads share a cache
- Memory budgeting for cache vs. connection buffers vs. request arenas

**Needed research:**
- Stale-while-revalidate patterns
- Cache warming strategies on startup
- How frameworks like Django, Flask implement their cache backends
- Whether an in-process cache can replace Redis for common patterns (session storage, rate limit counters)

---

## 10. Worker Thread Failure / Resilience

### Findings

**`refs/bun/INSIGHTS.md`** -- Crash handler with nested panic detection:

> "The crash handler handles nested panics (panic-during-panic) with a stage counter."

**`src/python/REFERENCES.md`** -- PyO3 catches panics at FFI boundary:

> "Panics are caught at the FFI boundary and converted to `PanicException`."

> "Never let Rust panics cross FFI boundaries (PyO3 handles this automatically)"

**`refs/tigerbeetle/INSIGHTS.md`** -- Assertive programming style:

> "Not defensive programming -- assertive programming. If invariants are violated, crash immediately. ~1 assert per 5-10 lines of code."

> "`unreachable` for impossible errnos: E.g., `FAULT` (kernel passed bad pointer) is `unreachable` because it indicates a bug in TigerBeetle, not a runtime condition."

**`tests/REFERENCES_verification.md`** -- Mentions thread failure verification:

> "Verify: connection pool behavior under network partitions, scheduler correctness under thread failures, graceful shutdown under partial failures."

**`refs/http.zig/INSIGHTS.md`** -- Error handling at the handler boundary:

> "Handler errors caught by framework: [...] `uncaughtError` callback fires for unhandled errors, defaulting to 500 Internal Server Error."

### Assessment

**INSUFFICIENT.** The references cover panic handling at FFI boundaries (PyO3) and crash handlers (Bun), but there is no research on worker thread resilience specifically:
- What happens when a Zig worker thread panics while holding the GIL?
- Can a worker thread be restarted without restarting the process?
- How to isolate a Python exception that causes thread-local state corruption
- Supervision tree patterns (Erlang/OTP style) applicable to worker threads
- Health checking of worker threads (watchdog timers, heartbeat)
- Memory leak detection per-worker (slow leak in arena that never resets properly)

**Needed research:**
- Zig's behavior on thread panic (does `@panic` kill the whole process or just the thread?)
- Process-level isolation (multiprocessing) vs. thread-level isolation tradeoffs
- Gunicorn/uvicorn worker management patterns (max-requests, max-requests-jitter)
- How to safely recover from a corrupted Python interpreter state in one thread

---

## Summary Matrix

| # | Topic | Coverage | Files with Findings | Verdict |
|---|-------|----------|---------------------|---------|
| 1 | Background tasks / fire-and-forget | Minimal | `REFERENCES_di.md`, `bun/INSIGHTS.md`, `tigerbeetle/INSIGHTS.md` | INSUFFICIENT -- no Python-side API design |
| 2 | Request context propagation | Moderate | `REFERENCES_middleware.md`, `REFERENCES_di.md`, `python/REFERENCES.md` | PARTIALLY SUFFICIENT -- architecture identified, snek-specific design missing |
| 3 | DBAPI 2.0 / PEP 249 | Complete | `db/REFERENCES.md` | SUFFICIENT |
| 4 | Backpressure | Thorough | `tigerbeetle/INSIGHTS.md`, `REFERENCES_websocket.md`, `serve/REFERENCES.md`, `REFERENCES_middleware.md` | SUFFICIENT |
| 5 | LISTEN/NOTIFY | Minimal | `db/REFERENCES.md` | INSUFFICIENT -- only mentioned in passing |
| 6 | Multipart parsing | Thorough | `serve/REFERENCES.md`, `http.zig/INSIGHTS.md` | SUFFICIENT |
| 7 | Graceful shutdown / drain | Moderate | `REFERENCES_verification.md`, `tigerbeetle/INSIGHTS.md`, `REFERENCES_websocket.md` | PARTIALLY SUFFICIENT -- properties specified, concrete design missing |
| 8 | Hot reload / dev mode | Minimal | `security/REFERENCES.md` (cert reload only) | INSUFFICIENT -- no app-level hot reload research |
| 9 | Embedded cache / in-process KV | Minimal | `ghostty/INSIGHTS.md`, `tigerbeetle/INSIGHTS.md`, `serve/REFERENCES_client.md` | INSUFFICIENT -- building blocks only, no web-framework-specific patterns |
| 10 | Worker thread failure / resilience | Minimal | `python/REFERENCES.md`, `bun/INSIGHTS.md`, `REFERENCES_verification.md` | INSUFFICIENT -- FFI panic catching covered, thread recovery not |

### Topics Requiring Additional Research (Priority Order)

1. **Hot reload / dev mode** -- Critical for DX, completely unresearched
2. **LISTEN/NOTIFY** -- Important for real-time features, barely mentioned
3. **Background tasks** -- Core framework feature, no API design research
4. **Worker thread failure / resilience** -- Production reliability concern
5. **Embedded cache** -- Performance optimization, missing web-framework context
6. **Graceful shutdown** -- Partially covered, needs concrete snek-specific protocol
7. **Request context propagation** -- Well-understood problem, needs snek-specific design
