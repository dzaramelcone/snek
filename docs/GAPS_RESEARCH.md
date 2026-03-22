# Snek Gaps Research

Deep research on five identified gaps for the snek framework (Zig-based Python web framework).

---

## 1. Hot Reload / Dev Mode

### How Python Web Frameworks Handle Hot Reload

**Uvicorn** uses `--reload` which starts a file watcher in the main process and runs the application in a subprocess. When files change, the subprocess is killed and restarted from scratch. It supports `--reload-dir`, `--reload-include`, `--reload-exclude` for scoping. The `--reload-delay` defaults to 0.25s between checks.

**Django** has two reloader implementations:
- **StatReloader** (default): Polls all files every 1 second. On a medium project (385k lines + 206 installed packages), uses ~10% of a CPU every other second.
- **WatchfilesReloader** (via [django-watchfiles](https://github.com/adamchainz/django-watchfiles)): Uses OS-native events. Detects changes in ~50ms vs 1s+. Uses 0% CPU between changes. Batches rapid changes with a 50ms debounce window, repeating up to 1600ms as long as changes keep occurring.

**Flask** uses Werkzeug's reloader, which is similar to Django's StatReloader (polling-based).

### watchfiles (Rust-based File Watcher)

[watchfiles](https://github.com/samuelcolvin/watchfiles) wraps the Rust [notify](https://github.com/notify-rs/notify) crate, which provides cross-platform filesystem notification using OS-native APIs:
- **Linux**: inotify
- **macOS**: FSEvents
- **BSD**: kqueue
- **Windows**: ReadDirectoryChanges
- **Fallback**: Polling (stat-based), implemented in Rust so still faster than Python polling

The notify crate is used by major projects: alacritty, cargo watch, deno, mdBook, rust-analyzer, watchexec, xi-editor, zed.

### Process Restart vs In-Place Module Reload

| Approach | Pros | Cons |
|----------|------|------|
| **Full process restart** (uvicorn, Django, gunicorn) | Bulletproof reliability. No stale state. No mysterious bugs from incomplete reloads. | Slow. Kills all state. 200-500ms for small Flask apps, 5+ seconds for large projects. |
| **Module reload** (jurigged, Gauge HMR) | Near-instant (~6ms). Preserves app state. | Stale references everywhere. Every captured reference (decorators, closures, global vars) is a source of bugs. Breaks down with complex dependency graphs, metaclasses, dynamic imports. |
| **Bytecode swap** (jurigged specifically) | Uses `gc.get_referrers()` to find ALL functions using old code, replaces `__code__` pointers simultaneously. Most sophisticated approach. | Still fragile with module-level side effects, class hierarchies, and C extensions. |

### Restart Bottlenecks

1. **Python interpreter startup**: ~50-100ms
2. **Dependency imports**: The real killer. FastAPI + Pydantic v2 with large models can take 2-4x longer. Django's ORM, SQLAlchemy, etc. are expensive.
3. **Top-level side effects**: DB migrations, connection establishment, config loading at import time
4. **Route table rebuilding**: Relatively cheap compared to imports
5. **Worker multiplication**: Each worker re-imports everything independently

### Zig File Watching Implementations

Zig's standard library includes `fs/watch.zig` with cross-platform file watching, introduced via [PR #20580](https://github.com/ziglang/zig/pull/20580):
- **Linux**: inotify
- **macOS/BSD**: kqueue (implemented Oct 2024, [issue #20599](https://github.com/ziglang/zig/issues/20599))
- **macOS**: FSEvents also available
- Supports `--watch` flag with configurable `--debounce`
- Goal: extract into `std.fs.Dir.Watch` ([issue #20682](https://github.com/ziglang/zig/issues/20682))

### Recommendations for Snek

1. **Use Zig's `fs/watch.zig`** for file watching in dev mode. It already abstracts inotify/kqueue/FSEvents, exactly what we need.
2. **Full process restart** is the right default. Module reload is too fragile and Python's reference semantics make it a minefield.
3. **Optimize restart speed** by keeping the Zig server process alive and only restarting the Python interpreter subprocess. The Zig event loop, thread pool, route table (if compiled), and socket listeners can persist.
4. **Debounce** with 50-100ms window, matching watchfiles defaults.
5. **Lazy loading hint**: Document that users should lazy-load heavy imports to speed up reload. Consider a `snek dev --preload` mode that keeps expensive Python modules in a parent process and forks (like gunicorn's preload).

---

## 2. Background Tasks / Fire-and-Forget

### Starlette/FastAPI BackgroundTask

The implementation is remarkably simple (~30 lines):

```python
class BackgroundTask:
    def __init__(self, func, *args, **kwargs):
        self.func = func
        self.args = args
        self.kwargs = kwargs
        self.is_async = is_async_callable(func)

    async def __call__(self):
        if self.is_async:
            await self.func(*self.args, **self.kwargs)
        else:
            await run_in_threadpool(self.func, *self.args, **self.kwargs)
```

Key behavior:
- Tasks run **after** the response is sent to the client
- Tasks execute **sequentially** (not concurrently) by default
- Sync functions run via `run_in_threadpool` (threadpool executor)
- No retry, no persistence, no monitoring
- If the server shuts down, pending tasks are lost silently

### External Task Queues

| System | Broker | Strengths | Weaknesses |
|--------|--------|-----------|------------|
| **Celery** | RabbitMQ, Redis, SQS | Mature, distributed, flexible routing, scheduling | Complex, heavy, slow for low-latency |
| **Dramatiq** | RabbitMQ, Redis | Simpler API, better low-latency performance, threading | Fewer features than Celery |
| **Huey** | Redis, SQLite | Lightweight, minimal setup, perfect for small-medium apps | Redis-only for production |

Performance: Huey, Dramatiq, and Taskiq are ~10x faster than RQ for task dispatch.

### In-Process vs External Task Queue

| Approach | Use Case | Trade-off |
|----------|----------|-----------|
| **In-process** (Starlette-style) | Send email, log analytics, invalidate cache | Zero infra overhead, but tasks die with the process |
| **External queue** (Celery/Dramatiq) | Payment processing, video transcoding, anything that must complete | Requires broker infra, but tasks survive crashes |

### Graceful Shutdown Patterns

**Go**: Move server out of main goroutine, catch OS signals via context, use `select` to react. In-flight requests get a timeout (typically 30-60s).

**Rust/Tokio**: `CancellationToken` pattern. Clone tokens to share across tasks. `JoinSet` for group cancellation (`drop(set)` aborts all). Libraries: `tokio-graceful-shutdown`, `tokio-graceful`.

**Python**: Catch `KeyboardInterrupt`, cancel asyncio tasks with `task.cancel()`, await cleanup.

**Universal principle**: Stop accepting new work, drain existing work with a timeout, then force-kill.

### Recommendations for Snek

1. **Implement Starlette-compatible BackgroundTask** as the simple default. Run tasks on Zig's thread pool after response is sent.
2. **Add a task registry** in the Zig core that tracks active background tasks. On shutdown signal, drain with a configurable timeout (default 30s).
3. **Fire-and-forget via Zig threads**: Since snek controls the thread pool, spawn background work as Zig tasks that call back into Python. This is cheaper than Python's `run_in_threadpool`.
4. **Shutdown protocol**:
   - SIGTERM received -> stop accepting new connections
   - Wait for in-flight requests (with timeout)
   - Wait for background tasks (with timeout)
   - Force kill remaining tasks
   - Exit
5. **Do NOT build a task queue**. That's Celery/Dramatiq territory. Instead, provide clean integration points for external queues.

---

## 3. LISTEN/NOTIFY

### Driver Implementations

**asyncpg**:
- Supports `connection.add_listener(channel, callback)` for LISTEN/NOTIFY
- **Critical constraint**: All listeners are removed when a connection is returned to the pool (`UNLISTEN *` is part of reset)
- Therefore, **must use a dedicated connection** outside the pool
- [asyncpg-listen](https://pypi.org/project/asyncpg-listen/) wraps this with reconnection policies and dedicated connection management

**psycopg3**:
- Supports both sync and async notification handling
- Use `connection.notifies()` generator for receiving
- **Must be in autocommit mode** for timely notification delivery (transactions buffer notifications)
- Only supports one listener per connection natively; fan-out must be implemented manually

**pgx (Go)**:
- Uses `WaitForNotification()` on a dedicated connection
- [pgln](https://github.com/tzahifadida/pgln) provides structured LISTEN/NOTIFY on top of pgx

### The Notifier Pattern (brandur.org)

[Brandur's notifier pattern](https://brandur.org/notifier) is the gold standard architecture:

1. **One connection per process** handles all LISTEN channels
2. Components subscribe via `Listen(channel)` -> receive a **buffered channel** (e.g., `make(chan string, 100)`)
3. **Non-blocking sends**: If a subscriber's buffer is full, the notification is discarded (prevents slow subscribers from blocking everything)
4. **Interruptible receive loop**: 30s timeout-based context loop periodically interrupts blocking waits, allowing new subscriptions to issue LISTEN immediately
5. **Health monitoring**: Unhealthy connections trigger clean shutdown rather than complex recovery ("let it crash")
6. **PgBouncer compatible**: The notifier uses session pooling for its dedicated connection; everything else can use transaction pooling

River's notifier is a well-vetted Go reference implementation.

### Dedicated Connection vs Pool

**Must be dedicated**. Reasons:
- Pool connections get `UNLISTEN *` on release
- LISTEN connections must stay idle for reliable delivery
- Queries on a LISTEN connection can interfere with notification delivery
- One connection is cheap; the notifier pattern proves it scales

### Real-Time Patterns

**NOTIFY -> SSE fan-out**: Simplest pattern. PostgreSQL notifies the server, server pushes to clients via SSE. No WebSocket upgrade handshake needed. Built-in reconnection via EventSource API. Best for infrequent updates (<1/min).

**NOTIFY -> WebSocket broadcast**: For higher frequency updates. Server maintains `active_connections` set, uses `asyncio.gather()` to broadcast concurrently. Requires connection management, heartbeats, reconnection logic.

**Throughput limits**: PostgreSQL LISTEN/NOTIFY is NOT a high-throughput message bus. Good for hundreds/sec. For thousands/sec, use it as a signal layer and pair with Redis pub/sub or Kafka for payload delivery.

### Recommendations for Snek

1. **Implement the Notifier pattern** in Zig. One dedicated PostgreSQL connection per process, managed entirely in Zig.
2. **Buffered fan-out**: Each Python subscriber gets a bounded channel. Non-blocking sends with overflow discard (log when dropping).
3. **Auto-reconnect**: The Zig notifier should handle connection drops, re-LISTEN on all channels after reconnect.
4. **Expose to Python** as:
   ```python
   @app.listen("channel_name")
   async def on_notify(payload: str):
       await broadcast_to_websockets(payload)
   ```
5. **SSE helper**: Provide a built-in SSE response type that integrates with NOTIFY channels.
6. **Keep it separate from the pool**. The notifier connection must not come from the connection pool.

---

## 4. Worker Thread Failure / Resilience

### What Happens When a Thread Panics

**Erlang/OTP Supervision Trees** (the gold standard):
- Hierarchical process tree: supervisors monitor workers, restart them according to rules
- **Strategies**: `one_for_one` (restart only the failed worker), `one_for_all` (restart all siblings), `rest_for_one` (restart failed + all started after it)
- Configurable restart intensity: max N restarts in T seconds before supervisor itself crashes (escalating to its parent)
- Workers restart into a known-good state: reload config, rebuild caches from durable storage
- **"Let it crash"**: Fail fast on invalid state. Recovery is structural, not defensive. This produces simpler code.
- Production proof: Riak under abusive testing "simply wouldn't stop running" because supervisors cleaned up and restarted subsystems every time.

**Go Goroutine Panic Recovery**:
- A single unrecovered panic in ANY goroutine crashes the entire process
- Pattern: `defer func() { if r := recover(); r != nil { log.Error(...) } }()` at goroutine entry
- **SafeGo wrapper**: Production pattern wraps goroutine launch with recovery, logging, metrics
- Best practice: Long-running goroutines MUST have panic recovery. Short-lived ones may skip if non-critical.
- Never silently swallow panics — always log + metrics

**Zig's @panic Behavior**:
- **Panics are terminal by default**. The custom panic handler must return `noreturn` — you cannot swallow a panic.
- [zig-recover](https://github.com/dimdin/zig-recover): Community library that catches panics by overriding the panic handler. Returns `error.Panic` instead of crashing. Requires C stdlib linkage (except Windows). **Author states it's intended for testing, not production.**
- **No native panic recovery mechanism** like Go's `recover()` or Rust's `catch_unwind()`
- Zig's philosophy: Use error unions (`!T`) for expected failures. Panics indicate programmer bugs that should crash.

**Nginx Worker Architecture**:
- Master process + N worker processes (one per CPU core)
- **Full process isolation**: Each worker has its own PID and memory space
- Master monitors workers; if a worker crashes (SIGSEGV, etc.), master immediately spawns a replacement
- Workers are single-threaded, event-loop driven (epoll/kqueue)
- No shared memory between workers = crash in one cannot corrupt another

**Seastar's Shared-Nothing Per-Core Design**:
- One application thread per core (called a "shard")
- Memory is **partitioned at startup**: each core gets its own chunk, NUMA-aware
- No locks, no shared state. Inter-core communication via single-producer/single-consumer message queues
- Each core runs a cooperative task scheduler (non-preemptive)
- Application code within a core needs NO synchronization — it's effectively single-threaded
- Used by ScyllaDB, Redpanda

### Thread-Level vs Process-Level Recovery

| Approach | Isolation | Recovery | Overhead | Example |
|----------|-----------|----------|----------|---------|
| **Process per core** | Complete | Master respawns | Fork + reimport | nginx, gunicorn |
| **Thread per core + crash containment** | Partial (shared address space) | Restart thread, but memory may be corrupted | Low | Zig potential approach |
| **Shard per core** (shared-nothing) | Near-complete (partitioned memory) | Restart shard's state | Low | Seastar/ScyllaDB |
| **Supervision tree** | Complete (Erlang processes are isolated) | Supervisor restarts child | Very low (lightweight processes) | Erlang/OTP |

### Recommendations for Snek

1. **Process-level isolation for Python workers** is the safest default. If a Python worker thread panics (segfault in C extension, etc.), the damage is contained.
2. **Zig thread supervision**: Implement a lightweight supervisor in Zig that monitors worker threads. If a thread dies:
   - Log the failure with full context
   - Increment a failure counter
   - Spawn a replacement thread
   - If failures exceed threshold (e.g., 5 in 60s), trigger graceful shutdown (something is fundamentally wrong)
3. **Do NOT use zig-recover in production**. It's intended for testing. Instead, design around error unions for expected failures and let panics crash the thread.
4. **Heartbeat monitoring**: Worker threads send periodic heartbeats. If a thread goes silent for >5s, consider it stuck/dead and replace it.
5. **Shared-nothing where possible**: Give each worker thread its own Python interpreter (subinterpreters in 3.12+) and its own memory arena. This approaches Seastar's isolation model.
6. **Graceful degradation**: If worker count drops below minimum, start rejecting new connections with 503 rather than accepting work that can't be processed.

---

## 5. Embedded / Multi-Tier Cache

### In-Process Caching in Web Frameworks

**Django's Cache Framework**:
- Pluggable backends: local memory, file, database, Memcached, Redis
- Local memory cache: Fast, but each process has its own private instance — no cross-process sharing
- Multi-process/thread-safe
- Granularity levels: per-site, per-view, template fragment, low-level API

**Flask-Caching**:
- SimpleCache: In-memory, single-process only, "not 100% thread safe"
- Supports Redis, Memcached, filesystem backends via cachelib

### Cache Patterns

| Pattern | Mechanism | Best For | Risk |
|---------|-----------|----------|------|
| **Cache-aside** (lazy loading) | App checks cache, misses go to DB, result written to cache | Read-heavy workloads (user profiles, catalogs) | Cache stampede on expiry |
| **Write-through** | Writes go to cache AND DB synchronously | Strong consistency requirements | Added write latency |
| **Write-behind** (write-back) | Writes go to cache only, async flush to DB | Write-heavy workloads | Data loss if cache crashes before flush |

### Redis Pub/Sub for Cache Invalidation

When running multiple server nodes, Redis pub/sub broadcasts invalidation messages:
1. Node A updates data -> publishes invalidation to Redis channel
2. All nodes subscribed to that channel receive the message
3. Each node deletes the stale key from its local cache

This is the standard pattern for keeping L1 (local) caches consistent across a distributed deployment.

### Zig Cache Implementations

**[cache.zig](https://github.com/karlseguin/cache.zig)** (karlseguin) — the most mature Zig cache library:
- Thread-safe, expiration-aware, LRU(ish)
- **Segmented architecture**: Configurable segment count (default 8, must be power of 2). Locking only at segment level.
- **Deferred promotion**: Items promoted to head of recency list only after N gets (default 5). Reduces lock contention + adds frequency bias to eviction.
- **Atomic reference counting**: Safe concurrent get/delete across threads. Users must call `release()` on retrieved entries.
- **Per-segment eviction**: Each segment independently enforces `max_size / segment_count`. Evicts down to `max_size * (1 - shrink_ratio)` (default 0.2 = evict to 80%).
- **Trade-off**: Poor key distribution across segments means the cache may never reach its configured max size.

**TigerBeetle's Set-Associative Cache**:
- Was in `cache_map.zig`, but **removed** ([PR #2889](https://github.com/tigerbeetle/tigerbeetle/pull/2889))
- Removal had no measurable performance impact in most cases (10-15% regression in some edge cases, deemed acceptable)
- Reasoning: Zig's standard HashMap improved enough that the set-associative approach no longer justified its complexity
- **Lesson**: Simpler is better. The complexity cost of a set-associative cache wasn't justified by the marginal performance gain.

**Ghostty's CacheTable**:
- No public documentation found on this specific data structure. Ghostty's source code would need direct inspection.
- Ghostty uses comptime-heavy Zig patterns but its cache structures aren't documented externally.

### Memcached vs Redis vs In-Process

| Tier | Latency | Use When | Limitations |
|------|---------|----------|-------------|
| **In-process** (L1) | ~50ns | Hot keys, read-heavy, single-node | Per-process, no cross-node sharing, limited by process memory |
| **Redis** (L2) | ~0.5ms | Shared state, cross-node, persistence needed | Network hop, serialization overhead |
| **Memcached** | ~0.5ms | Pure caching, multi-threaded workloads, simple key-value | No persistence, no pub/sub, no complex data types |
| **Database** | ~5ms | Source of truth | Slowest tier |

10,000x difference between L1 and Redis. For hot keys read thousands of times/sec, this matters enormously.

### Multi-Tier Cache Architecture

Request flow: **Request -> L1 (local, ~50ns) -> L2 (Redis, ~0.5ms) -> Database (~5ms) -> Populate L1 + L2**

- L1 absorbs hot reads, Redis handles the long tail and cross-instance sharing
- Invalidation: Redis pub/sub notifies all nodes to evict from L1 when data changes
- TTLs should differ: L1 short (seconds), L2 longer (minutes)

### Cache Stampede Prevention (Singleflight)

When a cached item expires under load, hundreds of concurrent requests all miss and hit the database simultaneously.

**Singleflight pattern** (from Go's `golang.org/x/sync/singleflight`):
- Deduplicates concurrent calls for the same key
- First caller does the actual work; all others wait and reuse the result
- 200 concurrent requests for the same expired key -> 1 database call instead of 200

**Redis-level stampede prevention**:
- Use `SET key value NX` (set-if-not-exists) as a distributed lock
- First request acquires the lock, fetches from DB, populates cache
- Other requests wait (poll or subscribe) for the cache to be populated

**Singleflight is non-negotiable** in any serious multi-tier cache. Without it, cache expiration under load becomes a database stampede.

### Recommendations for Snek

1. **Build an L1 cache in Zig** using karlseguin's cache.zig design principles:
   - Segmented (8-16 segments), mutex per segment
   - LRU with frequency-biased promotion (promote after N hits)
   - Atomic refcounting for thread-safe concurrent access
   - Configurable max size and TTL per entry
2. **Singleflight built into the cache layer**. When a key misses L1 and L2, only one thread fetches from the DB. Others wait on a condition variable.
3. **Redis as optional L2**. Not everyone needs it. The L1 cache should work standalone for single-node deployments.
4. **Cache invalidation via Redis pub/sub** when Redis is configured. On write, publish invalidation -> all nodes evict from L1.
5. **Expose to Python** as:
   ```python
   @app.get("/users/{id}")
   @cache(ttl=60)  # L1 + L2 automatically
   async def get_user(id: int) -> User:
       return await db.fetch_user(id)
   ```
6. **Skip set-associative caching**. TigerBeetle proved it doesn't justify the complexity over a good segmented hashmap.
7. **PostgreSQL NOTIFY as invalidation signal** (ties into section 3): When a row changes, NOTIFY -> snek notifier -> invalidate L1 cache key. Zero-config cache invalidation for database-backed caches.

---

## Cross-Cutting Themes

### Simplicity Wins
- TigerBeetle removed their set-associative cache with no meaningful performance loss
- Process restart for hot reload is simpler and more reliable than module reload
- The Notifier pattern uses one connection instead of per-topic connections
- Starlette's BackgroundTask is ~30 lines and covers 80% of use cases

### Zig's Strengths for Snek
- `fs/watch.zig` gives us cross-platform file watching for free
- Thread pool is controlled by Zig, enabling proper shutdown drain
- Segmented caching with per-segment mutexes maps perfectly to Zig's threading model
- Error unions handle expected failures; panics only for bugs

### Zig's Gaps for Snek
- No native panic recovery (zig-recover is testing-only). Must design around thread death via supervision.
- Standard library cache primitives don't exist yet; need to build or vendoring cache.zig
- File watching API not yet stabilized in std (`std.fs.Dir.Watch` is planned but not landed)

### Integration Points
These five features are interconnected:
- **NOTIFY + Cache**: Database changes trigger cache invalidation via NOTIFY
- **Background Tasks + Shutdown**: Task drain is part of graceful shutdown
- **Hot Reload + Worker Recovery**: Dev mode restart is a controlled version of crash recovery
- **Cache + Singleflight + Background Tasks**: Cache population can be a background task with singleflight deduplication

---

## Sources

### Hot Reload
- [Uvicorn Settings](https://uvicorn.dev/settings/)
- [django-watchfiles](https://github.com/adamchainz/django-watchfiles)
- [Introducing django-watchfiles - Adam Johnson](https://adamj.eu/tech/2025/09/22/introducing-django-watchfiles/)
- [notify-rs/notify](https://github.com/notify-rs/notify)
- [watchfiles Rust backend](https://watchfiles.helpmanual.io/api/rust_backend/)
- [Misadventures in Python Hot Reloading - Pierce Freeman](https://pierce.dev/notes/misadventures-in-python-hot-reloading)
- [How to Build Hot Module Replacement in Python - Gauge](https://www.gauge.sh/blog/how-to-build-hot-module-replacement-in-python)
- [jurigged](https://github.com/breuleux/jurigged)
- [Zig File Watching PR #20580](https://github.com/ziglang/zig/pull/20580)
- [Zig kqueue File Watching Issue #20599](https://github.com/ziglang/zig/issues/20599)
- [Watch.zig Stdlib Extraction Issue #20682](https://github.com/ziglang/zig/issues/20682)

### Background Tasks
- [Starlette Background Tasks](https://www.starlette.io/background/)
- [FastAPI Background Tasks](https://fastapi.tiangolo.com/tutorial/background-tasks/)
- [Dramatiq Motivation](https://dramatiq.io/motivation.html)
- [Choosing the Right Python Task Queue - Judoscale](https://judoscale.com/blog/choose-python-task-queue)
- [Exploring Python Task Queue Libraries - Steven Yue](https://stevenyue.com/blogs/exploring-python-task-queue-libraries-with-load-test)
- [Tokio Graceful Shutdown](https://tokio.rs/tokio/topics/shutdown)
- [Graceful Shutdown in Go](https://dev.to/bryanprimus/graceful-shutdown-in-go-2mlg)
- [Python Graceful Shutdown Example](https://github.com/wbenny/python-graceful-shutdown)

### LISTEN/NOTIFY
- [The Notifier Pattern - brandur.org](https://brandur.org/notifier)
- [asyncpg-listen](https://pypi.org/project/asyncpg-listen/)
- [psycopg3 Async/Concurrent Operations](https://www.psycopg.org/psycopg3/docs/advanced/async.html)
- [Real-Time with PostgreSQL LISTEN/NOTIFY and FastAPI](https://medium.com/@diwasb54/real-time-communication-with-postgresql-listen-notify-and-fastapi-0bfedf66be13)
- [PostgreSQL LISTEN/NOTIFY Real-Time Without Message Broker](https://www.pedroalonso.net/blog/postgres-listen-notify-real-time/)
- [Real-time Updates from Postgres Using NOTIFY/LISTEN and SSE](https://tom.catshoek.dev/posts/postgres-sse/)
- [Supabase Realtime](https://github.com/supabase/realtime)

### Worker Thread Failure
- [Supervision Trees - Adopting Erlang](https://adoptingerlang.org/docs/development/supervision_trees/)
- [OTP Supervisor Behaviour](https://www.erlang.org/doc/system/sup_princ.html)
- [Defer, Panic, and Recover - Go Blog](https://go.dev/blog/defer-panic-and-recover)
- [Crash-Proof Go Services](https://medium.com/@sogol.hedayatmanesh/crash-proof-go-services-why-you-must-recover-panics-in-goroutines-whether-you-like-it-or-not-4c2bbecfd191)
- [zig-recover](https://github.com/dimdin/zig-recover)
- [Nginx Master-Worker Architecture](https://medium.com/@nomannayeem/nginx-master-worker-architecture-from-zero-to-production-c451ee8e44ca)
- [Seastar Shared-Nothing Design](https://seastar.io/shared-nothing/)
- [ScyllaDB Shard-per-Core Architecture](https://www.scylladb.com/product/technology/shard-per-core-architecture/)

### Multi-Tier Cache
- [cache.zig](https://github.com/karlseguin/cache.zig)
- [TigerBeetle Set-Associative Cache Removal PR #2889](https://github.com/tigerbeetle/tigerbeetle/pull/2889)
- [Django Cache Framework](https://docs.djangoproject.com/en/6.0/topics/cache/)
- [Redis Cache Invalidation Strategies](https://oneuptime.com/blog/post/2026-01-25-redis-cache-invalidation/view)
- [Three Ways to Maintain Cache Consistency - Redis](https://redis.io/blog/three-ways-to-maintain-cache-consistency/)
- [Singleflight in Go - PickMe Engineering](https://medium.com/pickme-engineering-blog/singleflight-in-go-a-clean-solution-to-cache-stampede-02acaf5818e3)
- [Multi-Tier Cache in Go with Redis](https://dev.to/young_gao/building-a-high-performance-cache-layer-in-go-2ejd)
- [Bentocache (Node.js Multi-Tier Cache)](https://github.com/Julien-R44/bentocache)
- [Redis vs Memcached - AWS](https://aws.amazon.com/elasticache/redis-vs-memcached/)
- [HybridCache - Go Multi-Level Cache](https://github.com/cshum/hybridcache)
