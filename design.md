# snek — Engineering Design Document

**Status:** Draft
**Last updated:** 2026-03-21

This document covers every subsystem, feature, and open decision in snek.
Items marked **[DECIDED]** have an answer. Items marked **[OPEN]** need discussion.
Items marked **[DEFER]** are real concerns we're punting to a later version.

---

## 0. Project Constraints

- **Language:** [DECIDED] Zig 0.15.2
- **Python ABI:** CPython 3.12+ via C extension API
- **Primary OS:** Linux (io_uring, 5.1+ kernel)
- **Secondary OS:** macOS (kqueue fallback for local dev)
- **Database:** [DECIDED] Postgres AND Redis for v1. Redis is first-class, same level as Postgres.
- **Packaging:** [DECIDED] setuptools-zig as PEP 517 build backend. abi3 stable ABI targeting
  CPython 3.12+. Static link OpenSSL. Pre-built wheels via cibuildwheel. Source fallback for
  exotic platforms.
- **License:** [OPEN] MIT? Apache 2.0? AGPL?

---

## 1. Runtime & Scheduler

### 1.1 Coroutine Model
- **[DECIDED]** Stackless coroutines (state machines, not green threads)
- **[DECIDED]** Comptime pipeline builder generates state machines from step sequences
- **[OPEN]** Maximum coroutine frame size — do we cap it? What if a handler has huge local state?
- **[OPEN]** Coroutine cancellation semantics — what happens when a client disconnects mid-handler?
  - Option A: Set a cancellation flag, handler checks it cooperatively
  - Option B: Force-complete the coroutine with a cancellation error
  - Option C: Let it finish but discard the response
- **[OPEN]** Coroutine timeout — per-request timeout that kills slow handlers?

### 1.2 Work-Stealing Scheduler
- **[DECIDED]** Chase-Lev deques, one per worker thread
- **[DECIDED]** Random victim selection for stealing (3 attempts)
- **[OPEN]** Number of worker threads — fixed at startup or adaptive?
  - Recommendation: Fixed. `workers = N` in snek.toml, default to CPU count.
- **[OPEN]** Worker thread affinity — pin to cores?
  - Pros: Better cache locality. Cons: Harder on heterogeneous CPUs (big.LITTLE).
- **[DECIDED]** Three-tier backpressure (inspired by TigerBeetle):
  1. Per-worker deque has a fixed capacity. When full, worker stops accepting from the accept queue.
  2. Accept queue (between TCP accept loop and workers) has a bounded size. When full, stop calling accept() — TCP backlog absorbs pressure.
  3. TCP listen backlog (OS-level, `backlog` in snek.toml). When full, kernel refuses connections.
  - Result: Pressure propagates cleanly from workers → accept → TCP → client sees connection refused.
  - No global overflow queue (avoids contention).
  - Slow clients: If a client is slow to read responses, its send buffer fills, io_uring send stalls, that coroutine stays suspended but doesn't block the worker (other coroutines continue). If too many slow clients accumulate, per-worker deque fills → backpressure kicks in.
- **[OPEN]** Idle strategy — what do workers do when there's no work?
  - Spin briefly, then park on a futex, wake on new work or I/O completion.

### 1.3 I/O Backend
- **[DECIDED]** io_uring on Linux, kqueue on macOS
- **[DECIDED]** Generic-over-IO architecture (TigerBeetle pattern). All subsystems are
  parameterized on `comptime IO: type`. Production uses real io_uring/kqueue. Tests use
  `FakeIO` driven by a deterministic PRNG seeded by a single `u64`.
  - Every I/O operation goes through the generic interface — no direct syscalls.
  - Zig comptime generics monomorphize away: zero runtime cost in production.
  - The compiler enforces the contract: if code calls a method that doesn't exist on
    `FakeIO`, it won't compile. No discipline required — the type system catches violations.
  - Enables VOPR-style deterministic simulation testing (see §19).
- **[OPEN]** io_uring configuration:
  - Ring size (SQ entries) — 256? 1024? 4096? Configurable?
  - SQ polling mode (SQPOLL) — burns a CPU core but eliminates syscalls. Worth it?
  - Registered file descriptors (IOSQE_FIXED_FILE) — avoids fd table lookup per op
  - Registered buffers (IORING_REGISTER_BUFFERS) — zero-copy recv
- **[OPEN]** How many io_uring instances? One per worker thread, or one shared?
  - Recommendation: One per worker. Avoids contention. Matches the work-stealing model.
- **[OPEN]** io_uring feature detection — what if the kernel is too old for features we want?
  - Probe at startup, degrade gracefully, log warnings.

### 1.4 Development on macOS
- **[DECIDED]** kqueue backend for local dev. io_uring via Docker (kernel 6.10+) for
  local io_uring testing. CI runs both backends on Linux.
- Four testing environments:
  1. `zig build test` on macOS → kqueue backend, fast iteration
  2. `docker run` on macOS → real io_uring (Linux kernel in VM)
  3. GitHub Actions `ubuntu-latest` → both backends, conformance suites
  4. `FakeIO` → deterministic simulation, runs anywhere, reproducible from seed

### 1.5 Memory Architecture
- **[DECIDED]** StaticAllocator pattern (TigerBeetle): applies ONLY to the Zig hot-path I/O
  buffers (connection pool, coroutine frames, request/response buffers, io_uring SQE/CQE
  rings). These are pre-allocated at startup and locked. Any allocation through the
  StaticAllocator after startup crashes — deterministic memory for the fast path.
- **[DECIDED]** Arena allocators handle per-request allocations (freed at request end).
- **[DECIDED]** General purpose allocator handles infrequent runtime allocations: config
  reload, JWKS cache refresh, OpenAPI schema generation, schema compilation at import time.
- **[DECIDED]** The "zero allocation" promise is: no allocation in the request-processing
  fast path after startup. Per-request arenas and infrequent runtime allocations use
  separate allocators outside the StaticAllocator boundary.
- **[DECIDED]** Two arenas per connection (http.zig pattern): `conn_arena` for connection
  lifetime (TLS state, parser state), `req_arena` for request lifetime with retention
  (cleared between requests but memory retained to avoid syscalls).
- **[DECIDED]** HiveArray (Bun pattern): bitset-tracked fixed-capacity pool for pre-allocated
  request contexts. O(1) acquire/release via leading-zeros intrinsic on the bitset.

### 1.6 Worker Resilience
- **[OPEN]** What happens when a worker thread panics?
  - Option A: Whole process dies (simple, correct — let process manager restart)
  - Option B: Isolate the failed worker, restart just that thread
  - Recommendation: Option A for v1. Process-level recovery via systemd/k8s is simpler and more reliable than thread-level recovery. Zig's @panic is not recoverable by design.
  - In-flight requests on the crashed worker are lost. Clients see connection reset. This is acceptable — any framework crashes on panic.

---

## 2. Networking

### 2.1 TCP
- **[DECIDED]** Non-blocking sockets, managed by io_uring/kqueue
- **[OPEN]** TCP_NODELAY — always on? Configurable?
  - Recommendation: On by default. HTTP benefits from low latency.
- **[OPEN]** SO_REUSEPORT — for multi-worker accept?
  - Linux 3.9+. Each worker listens on the same port, kernel load-balances.
  - Alternative: Single accept thread dispatches to workers.
- **[OPEN]** Keepalive
  - HTTP/1.1 keepalive timeout — how long to hold idle connections?
  - TCP keepalive (SO_KEEPALIVE) — for detecting dead connections
  - Default: HTTP keepalive 75s, TCP keepalive on after 60s idle
- **[OPEN]** Connection limits
  - Max total connections — what's the limit?
  - Max connections per IP — DDoS mitigation
  - Configurable in snek.toml

### 2.2 TLS
- **[DECIDED]** TLS 1.2 and 1.3. Native termination, no nginx.
- **[DECIDED]** TLS implementation: OpenSSL via `@cImport`. Not BoringSSL (fewer features,
  smaller ecosystem), not Zig native (stdlib is client-only, tls.zig not production-complete).
  Statically linked into the wheel. Let snek.toml configure min version.
- **[OPEN]** ALPN negotiation — required for HTTP/2 over TLS
- **[OPEN]** Certificate reloading — can we reload certs without restart?
  - Watch cert files with inotify, reload on change. No downtime.
- **[OPEN]** Client certificate auth (mTLS)
  - Needed for service-to-service auth.
  - [DEFER] v2 feature.
- **[OPEN]** ACME / Let's Encrypt auto-provisioning
  - [DEFER] v2 feature. Would be amazing but it's a lot of protocol work.

### 2.3 HTTP/1.1
- **[DECIDED]** Custom parser in Zig. Not wrapping llhttp or h11.
- **[DECIDED]** Request smuggling prevention is a first-class concern. Strict CL/TE validation.
  Reference: Kettle's 2025 research (24M sites exposed to CL/TE desync attacks).
- **[DECIDED]** Use SIMD-accelerated structural scanning where beneficial (inspired by
  picohttpparser/hparse approach). Ghostty finding: use inline asserts in hot paths,
  `std.debug.assert` has 15-20% overhead even in ReleaseFast.
- **[OPEN]** Request size limits
  - Max header size — 8KB? 16KB? (Apache default: 8KB, nginx: 4KB-8KB)
  - Max number of headers — 100? 200?
  - Max URI length — 8KB?
  - Max request body — configurable via `limits.body_size` in snek.toml
- **[OPEN]** Transfer encodings
  - Chunked encoding (receive and send) — required
  - Content-Length validation — reject mismatched bodies?
  - gzip/deflate/br response compression — [OPEN] built-in or defer?
    - Recommendation: Built-in gzip + brotli. It's expected in 2026.
    - Zig has zlib bindings. Brotli would be another C dep or Zig port.
- **[OPEN]** Expect: 100-continue handling
  - Client sends headers, waits for 100 before sending body.
  - Required for correct file upload handling.
- **[OPEN]** HTTP pipelining
  - Technically in the spec but most clients don't use it.
  - Recommendation: Support it but don't optimize for it.
- **[OPEN]** Keepalive behavior
  - Max requests per connection — unlimited? Configurable?
  - Idle timeout — how long before we close an idle keepalive connection?
  - Connection: close header — respect it, send it on server shutdown

### 2.4 HTTP/2
- **[OPEN]** Build or borrow?
  - http2.zig exists (HPACK, stream mux, flow control). Evaluate quality.
  - Or write from scratch using RFC 7540/7541.
- **[OPEN]** h2c (HTTP/2 cleartext) — allow HTTP/2 without TLS?
  - Useful for internal services behind a load balancer.
- **[OPEN]** Stream concurrency limits
  - SETTINGS_MAX_CONCURRENT_STREAMS — default 100? 256?
- **[OPEN]** Server push
  - Recommendation: Don't implement. Browsers are removing support. Dead feature.
- **[OPEN]** Flow control tuning
  - Default window sizes? Auto-tuning?
- **[OPEN]** HPACK dynamic table size — how much memory per connection?
- **[OPEN]** Graceful shutdown — GOAWAY frame, drain existing streams

### 2.5 HTTP/3 / QUIC
- **[DEFER]** This is a v2 feature. QUIC is massive (RFC 9000 alone is 150 pages).
- **[OPEN]** When we do it, build or bind to quiche/msquic?

### 2.6 WebSocket
- **[DECIDED]** First-class support. Upgrade from HTTP/1.1 (and H2 via RFC 8441).
- **[DECIDED]** Must pass Autobahn TestSuite for RFC 6455 conformance.
- **[DECIDED]** permessage-deflate support. Be aware of memory fragmentation
  (documented by Node's ws library — each deflate context retains a 32KB window).
- **[DECIDED]** Masking optimization via SIMD or word-size operations (reference:
  coder/websocket SSE2 assembly achieves 3x gorilla/websocket throughput).
- **[OPEN]** WebSocket frame handling
  - Max frame size — configurable
  - Max message size (across fragments) — configurable
  - Ping/pong handling — auto-reply to pings? Configurable interval for outbound pings?
- **[OPEN]** Python API for WebSocket handlers:
  ```python
  @app.websocket("/ws/chat")
  async def chat(ws):
      async for msg in ws:
          await ws.send(f"echo: {msg}")
  ```
  - The `ws` object drives send/recv through snek coroutines.
  - How does the Python async for interact with snek's coroutine driving?
  - ws.send() and ws.recv() are Suspend points that yield to Zig.

---

## 3. Python Integration

### 3.1 C Extension Module (_snek)
- **[DECIDED]** CPython C API. Ship as .so/.dylib in the wheel.
- **[DECIDED]** Stable ABI: abi3 targeting CPython 3.12+. One wheel works across 3.12, 3.13,
  3.14. Note: abi3 is incompatible with free-threaded Python (PEP 803 targets 3.15).
- **[DECIDED]** Build tooling: setuptools-zig. Three-layer FFI bridge pattern (like Bun's
  C++→C extern→Zig bindings, adapted for CPython→C extern→Zig).
- **[DECIDED]** Comptime boolean specialization: thread ssl/debug/middleware-presence through
  type hierarchy at comptime to eliminate runtime branching (Bun pattern). E.g., a server
  compiled without TLS has zero TLS-related branches in the hot path.

### 3.2 GIL Management
- **[DECIDED]** Acquire GIL to call Python, release on I/O suspend.
- **[OPEN]** Python 3.13 free-threaded mode (no-GIL) — do we support it?
  - If yes: need to handle concurrent Python execution carefully.
  - Recommendation: Target GIL mode first. Free-threaded as a flag later.
- **[OPEN]** GIL granularity — acquire/release per request? Per I/O operation?
  - Per I/O operation: More concurrency, more overhead from GIL cycling.
  - Per request: Simpler, less overhead, but blocks other handlers.
  - Recommendation: Per I/O operation. The benchmarks show GIL acquire/release is ~50-100ns. Worth it.
- **[OPEN]** What if Python code runs too long (CPU-bound handler)?
  - The GIL is held for the duration. Other Python handlers queue behind it.
  - Options: timeout? warning? forceful interrupt via PyErr_SetInterrupt?
  - Recommendation: Log a warning if GIL held > 100ms. Document that CPU-bound
    work should go in a thread pool or subprocess.
- **[DECIDED]** snek is a Zig-first runtime with short Python execution windows. Thread-per-core
  scales the I/O layer (parsing, validation, JSON serde, DB wire protocol, compression). Python
  execution is GIL-serialized — the bet is that handler Python code is brief (business logic,
  not I/O). The GIL is released at every I/O suspend point. CPU-bound Python work must use a
  thread pool or subprocess. This is a deliberate design trade-off, not a limitation to work around.
- **[DECIDED]** The performance model: Zig handles the I/O multiplexing across N cores. Python
  handles the business logic on effectively one core at a time (GIL). The system scales because
  I/O dominates wall-clock time in web applications, and snek's I/O is fully parallel.

### 3.3 Coroutine Driving Protocol
- **[DECIDED]** Python handlers are `async def`. snek drives them via `coro.send()`.
- **[DECIDED]** DbQuery sentinel object yielded from await, intercepted by snek.
- snek is the intellectual successor to curio's trap-based kernel design. Sentinel
  interception follows the same pattern as curio's trap system.
- **[DECIDED]** Recognized awaitables (sentinel objects intercepted at `send()` boundary):
  - `app.db.fetch()` / `app.db.fetch_one()` / `app.db.execute()` — DB queries
  - `app.redis.get()` / `app.redis.set()` / `app.redis.publish()` / `app.redis.subscribe()` — Redis
  - `app.http.get()` / `app.http.post()` etc. — outbound HTTP
  - `app.sleep(seconds)` — timer
  - `app.ws.send()` / `app.ws.recv()` — WebSocket I/O
- **[OPEN]** What happens if the user awaits something snek doesn't recognize?
  - e.g., `await asyncio.sleep(1)` — this is an asyncio awaitable, not a snek one.
  - Option A: Raise TypeError immediately.
  - Option B: Try to run it via a minimal asyncio compatibility layer.
  - Option C: Document that only snek awaitables work. Anything else is an error.
  - Recommendation: C. Be explicit. snek is not asyncio.
- **[OPEN]** Multiple concurrent awaits in one handler?
  ```python
  async def handler():
      users, posts = await app.gather(
          app.db.fetch("SELECT * FROM users"),
          app.db.fetch("SELECT * FROM posts"),
      )
  ```
  - `app.gather` would yield multiple IoOps. Scheduler submits all, resumes
    when all complete. This is genuinely useful for parallel db queries.
  - Implementation: gather returns a sentinel with a list of ops.

### 3.4 Error Handling
- **[OPEN]** Python exception → HTTP response mapping
  - Unhandled exception in handler → 500 Internal Server Error
  - Custom exception classes → specific status codes?
    ```python
    raise snek.NotFound("User not found")    # → 404
    raise snek.BadRequest("Invalid email")   # → 400
    raise snek.Unauthorized()                # → 401
    ```
  - Or: return-value-based instead of exception-based?
    ```python
    return snek.error(404, "User not found")
    ```
  - Recommendation: Support both. Exceptions for convenience,
    return values for explicitness.
- **[OPEN]** Error response format
  - JSON by default? `{"error": "User not found", "status": 404}`
  - Configurable error renderer for HTML error pages?
- **[OPEN]** Debug mode — show tracebacks in responses?
  - Only if `debug = true` in snek.toml. Never in production.

### 3.5 Type Coercion / Validation
- **[DECIDED]** `snek.Model` base class for validation (not pydantic). Pydantic-compatible API
  surface: `model_validate`, `model_dump`, `model_json_schema`.
- **[DECIDED]** All constraints are declarative via `Annotated` types: `Gt`, `Ge`, `Lt`, `Le`,
  `MinLen`, `MaxLen`, `Pattern`, `Email`, `OneOf`, `UniqueItems`. No imperative validators.
  The type system IS the validation spec.
- **[DECIDED]** Zig compiles validation schema from Python annotations at import time.
  Validation errors returned as JSON without entering Python.
- **[DECIDED]** Fused decode+validate — parse JSON and validate constraints in a single pass
  in Zig. Never decode then validate separately. (msgspec pattern: 10-100x faster than
  interpreted validation per research.)
- **[DECIDED]** Supported types:
  - Primitives: `int`, `float`, `str`, `bool`, `None`
  - Containers: `list[T]`, `dict[str, T]`, `tuple[T, ...]`, `set[T]`
  - Optional: `Optional[T]`, `T | None`
  - Union: `int | str`
  - Nested models: any `snek.Model` subclass
  - Enums: `enum.Enum` subclasses
  - Constrained: `Annotated[int, Gt(0), Lt(100)]`

Example:
  ```python
  from snek import Model
  from typing import Annotated

  class Address(Model):
      street: str
      city: str
      zip: Annotated[str, Pattern(r"^\d{5}$")]

  class CreateUser(Model):
      name: Annotated[str, MinLen(1), MaxLen(100)]
      email: Annotated[str, Email()]
      age: Annotated[int, Ge(0), Lt(150)]
      address: Address
      tags: Annotated[list[str], MaxLen(10), UniqueItems()]
  ```

- Path params: Zig parses the URL, extracts string, converts to int/float/str
  based on type annotation, passes to Python as native Python type.
- Query params: Same.
- Request body (JSON): Fused decode+validate in Zig against compiled schema.
- DB results: Postgres wire format → Python dict by default.

### 3.6 Dependency Injection
- **[DECIDED]** First-class DI, not bolted on. Unlike FastAPI's `Depends()`, snek DI works
  in middleware AND handlers uniformly.
- **[DECIDED]** `@app.injectable` decorator for declaring dependencies.
- **[DECIDED]** Yield-based lifecycle (async generators for setup/teardown, e.g., db
  transactions that auto-commit/rollback):
  ```python
  @app.injectable(scope="request")
  async def db_session():
      async with app.db.transaction() as tx:
          yield tx
          # auto-commit on clean exit, auto-rollback on exception
  ```
- **[DECIDED]** Three scopes:
  - **singleton** — app lifetime (e.g., config, shared caches)
  - **request** — per-request (e.g., db transactions, auth context)
  - **transient** — per-injection site (new instance every time)
- **[DECIDED]** DI graph validated at startup — circular deps detected, missing deps caught
  before the first request ever arrives.
- **[DECIDED]** Testing: override injectables without monkey-patching:
  ```python
  app.override(db_session, fake_db_session)
  ```
- Reference: ASP.NET Core is the gold standard for DI design. Dishka is closest Python
  prior art.

### 3.7 Request Context
- **[DECIDED]** Request-scoped state via `req.state` dict, set by middleware, available to handlers and DI.
- **[DECIDED]** Python's `contextvars` integration: snek creates a new Context per request, copies are used for DI resolution. This avoids the Starlette BaseHTTPMiddleware bug (which runs middleware in a threadpool executor, breaking ContextVar propagation).
- **[DECIDED]** Built-in context: `req.id` (request ID), `req.user` (set by auth middleware), `req.trace` (W3C traceparent).
- **[DECIDED]** DI injectables can access request context via declaring `req: snek.Request` as a parameter.

---

## 4. Request/Response

### 4.1 Request Parsing
- **[DECIDED]** Zig parses everything. Python gets clean, validated data.
- **[OPEN]** Request body handling:
  - JSON: Parse in Zig. Validate against schema if Body[T] annotated.
  - Form data (application/x-www-form-urlencoded): Parse in Zig.
  - Multipart (multipart/form-data): Parse in Zig. This is the hard one.
    - **[DECIDED]** Streaming multipart parser in Zig (callback-driven, like multipart-parser-c's 60-byte buffer approach).
    - **[DECIDED]** Configurable memory threshold: files smaller than threshold (default 1MB) buffered in memory, larger files streamed to temp directory.
    - **[DECIDED]** Limits: max file size per field, max total upload size, max number of fields — all configurable in snek.toml `[limits]` section.
    - **[OPEN]** TUS protocol (resumable uploads) — [DEFER] v2.
    - Multiple files in one field
    - Mixed file + form fields
  - Raw body: Just pass bytes through.
  - Streaming body: For large requests, provide an async iterator.
    ```python
    async def upload(body: snek.Stream):
        async for chunk in body:
            process(chunk)
    ```
- **[OPEN]** Content-Type negotiation
  - Should snek auto-detect and parse based on Content-Type header?
  - Or should the handler explicitly declare what it expects?
  - Recommendation: Auto-detect. JSON if application/json, form if
    application/x-www-form-urlencoded, multipart if multipart/form-data.

### 4.2 Response Serialization
- **[DECIDED]** Zig handles JSON serialization.
- **[OPEN]** Response types:
  - Dict/list return → auto-serialize to JSON, Content-Type: application/json
  - String return → text/plain
  - `snek.html("...")` → text/html
  - `snek.redirect("/path")` → 302 with Location header
  - `snek.file("/path/to/file")` → streaming file response with correct MIME type
  - `snek.stream(async_iterator)` → streaming response (SSE, chunked)
  - What about custom status codes? Custom headers?
    ```python
    return snek.response(data, status=201, headers={"X-Custom": "value"})
    ```
- **[OPEN]** Streaming responses (Server-Sent Events)
  ```python
  @app.route("GET", "/events")
  async def events():
      async def generate():
          while True:
              event = await app.db.listen("events")
              yield f"data: {event}\n\n"
      return snek.stream(generate(), content_type="text/event-stream")
  ```
  - The generator yields chunks. Each yield is a suspend point.
  - snek sends each chunk as it arrives. Connection stays open.
  - How does cancellation work when the client disconnects?

### 4.3 Cookies / Sessions
- **[DECIDED]** Cookie parsing and signing in Zig. HMAC-signed, key from snek.toml.
- **[DECIDED]** Redis-backed sessions for v1 (not deferred). Cookie-based session ID,
  HMAC-signed.
- **[DECIDED]** Session middleware with auto-save dirty sessions, configurable TTL.
  ```python
  @app.route("POST", "/login")
  async def login(req):
      req.session["user_id"] = user.id    # auto-saved at end of request
      return {"ok": True}
  ```

### 4.4 Response Compression
- **[DECIDED]** gzip + brotli. Use Zig's `std.compress` (merged from ianic/flate, 395KB
  fixed memory, no allocator needed). zstd deferred.
- **[DECIDED]** Compression threshold: 1KB minimum. Content-type filtering: text/json/html/css/js only.
- **[DECIDED]** Pre-compressed static files: `.br`/`.gz` served directly if they exist on disk.

---

## 5. Routing

### 5.1 Router Design
- **[DECIDED]** Compiled radix trie (not just prefix trie). Per-method dispatch trees.
  Reference: matchit (axum) at 2.45μs/130 routes is the benchmark target.
- **[DECIDED]** Path parameter syntax (FastAPI/OpenAPI-compatible):
  - `{id}` — single-segment parameter (matches until next `/` or end of path)
  - `{rest:path}` — catch-all parameter (matches remaining path, must be terminal)
  - Type comes from Python annotations, not route syntax. Route is just `{id}`,
    annotation says `id: int`. This matches FastAPI convention and avoids
    duplicating type info in two places. Reference: matchit uses `{id}` and
    `{*rest}`; we prefer `{rest:path}` for consistency with FastAPI's `path`
    converter and OpenAPI's path-style parameters.
- **[DECIDED]** Static segments take priority over parameters.
- **[DECIDED]** Route conflict detection at startup.
- **[DECIDED]** HEAD auto-generated from GET. OPTIONS auto-generated for CORS.
- **[DECIDED]** 405 Method Not Allowed with `Allow` header when path matches but method doesn't.

### 5.2 Route Groups / Prefixes
- **[OPEN]** Grouping routes under a common prefix:
  ```python
  users = app.group("/api/v1/users")

  @users.route("GET", "/{id}")
  async def get_user(id: int): ...

  @users.route("POST", "/")
  async def create_user(name: str, email: str): ...
  ```

---

## 6. Middleware & Hooks

### 6.1 Middleware Model
- **[DECIDED]** Not ASGI middleware. Snek's own model.
- **[DECIDED]** Two-tier middleware:
  - **Zig-side** (zero Python overhead): CORS, security headers, request ID, timing.
    Compiled at startup, never resolved per-request. Reference: http.zig comptime middleware.
  - **Python-side** (auth, custom logic): hooks + wrapping, both supported.
- **[DECIDED]** CORS pre-rendered headers at startup (TurboAPI pattern: 0% overhead vs 24%
  for Python middleware).
- **[DECIDED]** Hooks model (`before_request`, `after_request`, `on_error`) + wrapping model
  (`call_next`). Both supported:
    ```python
    @app.before_request
    async def auth_check(req):
        token = req.headers.get("Authorization")
        if not valid(token):
            raise snek.Unauthorized()
        req.user = decode(token)

    @app.middleware
    async def timing(req, call_next):
        start = time.time()
        response = await call_next(req)
        response.headers["X-Time"] = str(time.time() - start)
        return response
    ```
- **[OPEN]** Middleware ordering — declaration order? Explicit priority?
- **[OPEN]** Route-specific middleware vs global middleware

### 6.2 Lifecycle Hooks
- **[OPEN]** Startup/shutdown hooks:
  ```python
  @app.on_startup
  async def startup():
      app.redis = await connect_redis()

  @app.on_shutdown
  async def shutdown():
      await app.redis.close()
  ```
  - How do startup hooks interact with the connection pool?
  - snek's db pool is ready before startup hooks run?

### 6.3 Background Tasks
- **[OPEN]** Background task API:
  ```python
  @app.route("POST", "/users")
  async def create_user(body: Body[UserCreate], db: DbSession):
      user = await db.fetch_one("INSERT INTO users ... RETURNING *", ...)
      await app.spawn(send_welcome_email, user["email"])  # fire-and-forget
      return user
  ```
  - Spawned tasks are submitted to the scheduler's work queue; any worker thread may execute them.
    Background tasks are not affine to the originating request's worker — they don't need
    access to the request's connection arenas.
  - Tasks must complete before shutdown (subject to task_drain_timeout).
  - [OPEN] Should tasks survive response completion? Should they be cancellable?

---

## 7. Database (Postgres)

### 7.1 Wire Protocol
- **[DECIDED]** First-class Postgres wire protocol in Zig. No libpq dependency. Native
  wire protocol implementation.
- **[DECIDED]** Protocol version: v3 (current, since Postgres 7.4).
- **[DECIDED]** Authentication: SCRAM-SHA-256 + md5 + trust.
- **[OPEN]** SSL/TLS to Postgres — required for cloud providers
  - Postgres has its own SSL negotiation before the wire protocol starts
- **[DECIDED]** Extended query protocol (not simple). Enables prepared statements.
- **[DECIDED]** Pipeline mode support (up to 71x speedup on high-latency networks).
- **[DECIDED]** Binary format by default for numeric/timestamp/array types. Text for pure varchar.
- **[DECIDED]** Cache entire decode pipeline per prepared statement (asyncpg pattern → 1M rows/s).
- **[DECIDED]** Zero-copy result parsing: slices into read buffer (pg.zig pattern).
- **[OPEN]** Prepared statement caching
  - LRU cache? Size limit? Per-connection or global?
  - `statement_cache = 100` in snek.toml

### 7.2 Connection Pool
- **[DECIDED]** Built-in, fiber-aware. No PgBouncer.
- **[DECIDED]** Pool sizing: default `(cores * 2) + 1`. Small pools with waiters beat large
  pools (Little's Law). Configurable via `pool_min`/`pool_max` in snek.toml.
- **[DECIDED]** Health check on borrow + periodic background ping. Reconnect on failure.
- **[OPEN]** Transaction support
  ```python
  async with app.db.transaction() as tx:
      await tx.execute("INSERT INTO users ...")
      await tx.execute("INSERT INTO profiles ...")
      # auto-commit on exit, auto-rollback on exception
  ```
  - The `async with` is a Python context manager.
  - BEGIN at enter, COMMIT at exit, ROLLBACK on exception.
  - The transaction pins a connection for its duration.

### 7.3 Query Interface
- **[DECIDED]** Raw SQL with parameter binding.
- **[DECIDED]** Query validation at startup against schema.sql.
- **[OPEN]** Query builder for common patterns:
  ```python
  app.db.table("users").select().where(id=42)
  app.db.table("users").insert(name="Dzara", email="d@snek.dev").returning()
  app.db.table("users").update(name="Dzara").where(id=42)
  app.db.table("users").delete().where(id=42)
  ```
  - How complex does the builder get? Joins? Subqueries? Aggregates?
  - Recommendation: Simple CRUD only. Joins and beyond = raw SQL.
- **[DECIDED]** snek's DB driver exposes a PEP 249 (DBAPI 2.0) compatible cursor interface for use outside snek handlers (scripts, migrations, Alembic compatibility).
  - Primary API within handlers remains `app.db.fetch()` / `app.db.execute()` (sentinel-based).
  - DBAPI cursor available via `snek.db.connect()` for standalone usage.
- **[OPEN]** Result types
  - `fetch()` → list of dicts? list of tuples? list of Row objects?
  - `fetch_one()` → dict? Row? None if not found?
  - Recommendation: Dicts by default. Simple, JSON-serializable, no surprises.
- **[OPEN]** Type mapping: Postgres → Python
  - int4/int8 → int
  - float4/float8 → float
  - text/varchar → str
  - bool → bool
  - timestamp/timestamptz → datetime? str? 
  - json/jsonb → dict (parsed by Zig)
  - uuid → str? uuid.UUID?
  - array types → list
  - bytea → bytes
  - interval, numeric, money, inet, etc. → [OPEN]
- **[OPEN]** LISTEN/NOTIFY support
  - For real-time features (SSE, WebSocket push).
  - A dedicated connection listens for notifications.
  - How do notifications reach Python handlers?
  ```python
  @app.on_notify("new_order")
  async def handle_order(payload):
      await broadcast_to_websockets(payload)
  ```
  - Dedicated connection outside the pool (can't multiplex notifications on pooled connections).
  - Notifications dispatched to Python handlers via sentinel interception.
  - [OPEN] How many LISTEN connections? One shared, or one per channel?

### 7.4 Schema Management
- **[DECIDED]** schema.sql is the source of truth.
- **[DECIDED]** Numbered SQL migration files in migrations/ directory.
- Reference: pgroll for zero-downtime migrations (expand/contract pattern).
- **[OPEN]** Migration CLI:
  - `snek db create` — run schema.sql against empty database
  - `snek db migrate` — run pending migrations
  - `snek db rollback` — undo last migration (requires down migration?)
  - `snek db status` — show which migrations have been applied
  - `snek db reset` — drop and recreate
  - `snek db diff` — compare schema.sql to live database
- **[OPEN]** Migration file format:
  - Just SQL? Or paired up/down files?
  - `001_initial.sql` with `-- migrate:up` / `-- migrate:down` markers?
- **[OPEN]** Migration tracking — `snek_migrations` table in the database.

### 7.5 Redis
- **[DECIDED]** First-class Redis support. RESP3 protocol implemented in Zig.
- **[DECIDED]** Fiber-aware connection pool (same pattern as Postgres pool).
- **[DECIDED]** Commands: strings, hashes, lists, sets, sorted sets, keys.
- **[DECIDED]** Pub/Sub support (critical for real-time: SSE, WebSocket fan-out).
- **[DECIDED]** Lua scripting support (`eval`, `evalsha`, `scriptLoad`).
- **[DECIDED]** Used for: session storage, caching, pub/sub, rate limiting (in user app code).

---

## 8. HTTP Client

### 8.1 Outbound HTTP
- **[DECIDED]** snek includes a fiber-aware HTTP client. Likely the first production framework
  with an io_uring-backed HTTP client.
  ```python
  resp = await app.http.get("https://api.example.com/users")
  resp = await app.http.post("https://api.example.com/users", json=data)
  ```
- **[DECIDED]** Connection pooling per host. Sensible defaults (unlike every other client —
  research found all defaults are wrong in at least one dimension).
- **[OPEN]** Timeouts — connect timeout, read timeout, total timeout
- **[OPEN]** Retry logic — built-in? Configurable?
- **[OPEN]** Follow redirects — automatically? Max redirects?
- **[OPEN]** TLS verification for outbound — verify certs by default, option to disable

### 8.2 OAuth Support
- **[DECIDED]** v1: Authorization code flow + client credentials flow. Provider config in snek.toml.
- **[DEFER]** v2: OIDC discovery, PKCE, token refresh, custom provider protocol.
- **[OPEN]** JWT validation
  - Decode + verify JWT in Zig (avoid Python crypto overhead)
  - Support RS256, ES256, HS256
  - JWKS endpoint fetching + caching
  - Recommendation: Built-in for v1. JWTs are everywhere.
  ```toml
  [auth]
  jwt_secret = "${JWT_SECRET}"       # for HS256
  jwt_jwks_url = "https://..."       # for RS256/ES256
  jwt_algorithms = ["RS256"]
  ```
  ```python
  @app.route("GET", "/protected")
  async def protected(user: snek.AuthUser):
      # snek validated JWT, extracted claims, injected as AuthUser
      return {"user": user.sub}
  ```

### 8.3 Built-in Cache
- **[DEFER]** v2 feature. Multi-tier cache (in-process L1 + Redis L2 + pub/sub invalidation)
  requires Redis support to be solid first. Revisit after Redis is production-ready.
- v1 story: use Redis directly for caching. Simple, correct, no cache coherence complexity.

---

## 9. JSON

### 9.1 JSON Codec
- **[DECIDED]** Zig-native JSON, targeting orjson-level performance.
- **[DECIDED]** SIMD structural scanning (simdjson approach) for parsing.
- **[DECIDED]** Build on Zig `std.json` zero-copy token slices.
- **[DECIDED]** PgRowSerializer: DB rows → JSON with zero Python involvement (the killer feature).
- **[DECIDED]** PyObjectSerializer: bypass Python's json module entirely for response serialization.
- Reference: yyjson as competitive reference (beats simdjson on stringify without explicit SIMD).
- **[OPEN]** JSON compliance edge cases:
  - Duplicate keys — last wins? Error?
  - NaN/Infinity — reject (not valid JSON)?
  - Unicode escapes, surrogate pairs
  - Max nesting depth — prevent stack overflow
  - Max string length, max number magnitude

### 9.2 JSON Serialization
- **[OPEN]** Python object → JSON mapping:
  - dict → JSON object
  - list/tuple → JSON array
  - str → JSON string
  - int/float → JSON number
  - bool → true/false
  - None → null
  - datetime → ISO 8601 string
  - UUID → string
  - Enum → value
  - Custom objects — __json__() method? __dict__? Error?
- **[OPEN]** Serialization options:
  - Pretty print (for debug mode)
  - Sort keys
  - Custom encoders

---

## 10. Static Files

- **[OPEN]** Serve static files from a directory?
  ```toml
  [static]
  path = "/static"
  dir = "./static"
  ```
- **[OPEN]** ETag / Last-Modified / If-None-Match — 304 responses
- **[OPEN]** Sendfile / splice — zero-copy file serving via io_uring
- **[OPEN]** Content-Type detection — from file extension
- **[OPEN]** Directory listing — probably no. Security risk.
- **[OPEN]** Index files — serve index.html for directory requests?

---

## 11. Observability

### 11.1 Logging
- **[OPEN]** Structured logging in Zig (JSON logs)
- **[OPEN]** Access log format — configurable? Common log format? JSON?
- **[OPEN]** Log levels — configurable per-subsystem?
- **[OPEN]** Python logging integration — bridge snek logs into Python's logging module?

### 11.2 Metrics
- **[OPEN]** Built-in Prometheus-compatible metrics endpoint?
  - Request count, latency histogram, error rate
  - Connection pool stats (active, idle, waiting)
  - io_uring stats (submissions, completions, overflow)
  ```toml
  [metrics]
  path = "/metrics"
  ```

### 11.3 Health Checks
- **[DECIDED]** Built-in health endpoint from snek.toml.
- **[OPEN]** What does the health check verify?
  - Server is accepting connections (always)
  - Database is reachable (if check_db = true)
  - Custom health checks from Python hooks?

### 11.4 Request Tracing
- **[OPEN]** Request ID generation — UUID? ULID? Snowflake?
- **[OPEN]** Trace context propagation (W3C traceparent header)
- **[OPEN]** OpenTelemetry integration
  - [DEFER] v2 feature. But design the internals to be trace-friendly.

---

## 12. Security

### 12.1 CORS
- **[DECIDED]** Handled entirely in Zig with pre-rendered headers at startup.
- **[OPEN]** Full CORS spec compliance:
  - Preflight caching (Access-Control-Max-Age)
  - Credentials support (Access-Control-Allow-Credentials)
  - Exposed headers (Access-Control-Expose-Headers)
  - Wildcard vs explicit origins


### 12.3 CSRF Protection
- **[OPEN]** Built-in CSRF tokens for form submissions?
  - [DEFER] v2. Most snek apps will be JSON APIs, not form-based.

### 12.4 Security Headers
- **[OPEN]** Auto-set security headers?
  - X-Content-Type-Options: nosniff
  - X-Frame-Options: DENY
  - Strict-Transport-Security (if TLS enabled)
  - Content-Security-Policy — configurable
  - Recommendation: Sensible defaults, overridable in snek.toml.

---

## 13. CLI

### 13.1 Commands
- `snek run <app:module>` — start the server
  - `--reload` — watch for file changes, restart (dev mode)
  - `--port` / `--host` — override snek.toml
  - `--workers` — override worker count
- `snek db create` — create database from schema.sql
- `snek db migrate` — run pending migrations
- `snek db rollback` — undo last migration
- `snek db status` — show migration status
- `snek db diff` — compare schema to live database
- `snek db reset` — drop and recreate
- `snek routes` — list all registered routes with methods and types
- `snek check` — validate snek.toml, schema.sql, and all queries without starting server
- `snek version` — print version

### 13.2 Dev Mode
- **[OPEN]** File watching: inotify (Linux), FSEvents (macOS).
- **[DECIDED]** Process restart (not in-place reload). In-place reload is fragile.
- **[OPEN]** Restart speed optimization: keep DB/Redis pools alive across restarts? Or clean restart?
- **[OPEN]** Use watchfiles (Rust-based, used by uvicorn) or native Zig file watcher?
- **[OPEN]** Debug error pages — HTML error page with traceback, request info, etc.

---

## 14. Configuration (snek.toml)

### 14.1 Full Config Schema
```toml
[server]
host = "0.0.0.0"          # bind address
port = 8080                # bind port
workers = 4                # worker threads (0 = auto, CPU count)
backlog = 2048             # TCP listen backlog
debug = false              # debug mode (tracebacks in responses)

[tls]
enabled = false
cert = "./certs/cert.pem"
key = "./certs/key.pem"
min_version = "1.2"        # "1.2" or "1.3"

[database]
url = "postgres://user:pass@host:5432/dbname"
pool_min = 2               # minimum connections
pool_max = 20              # maximum connections
statement_cache = 100      # prepared statement cache size
connect_timeout = 5        # seconds
query_timeout = 30         # seconds

[redis]
url = "redis://localhost:6379"
pool_min = 2
pool_max = 20

[session]
backend = "redis"          # redis-backed sessions
ttl = 86400                # session TTL in seconds (24h)
cookie_name = "snek_sid"
cookie_secure = true
cookie_httponly = true
cookie_samesite = "lax"

[cors]
origins = ["*"]
methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"]
headers = ["*"]
credentials = false
max_age = 86400

[limits]
body_size = "10mb"         # max request body
header_size = "8kb"        # max total header size
request_timeout = 30       # seconds
keepalive_timeout = 75     # seconds
max_connections = 10000    # total concurrent connections

[compression]
enabled = true
algorithms = ["br", "gzip"]
min_size = 1024            # don't compress below 1KB

[static]
path = "/static"
dir = "./static"

[auth]
jwt_secret = "${JWT_SECRET}"
jwt_algorithms = ["HS256"]
# jwt_jwks_url = "https://..."  # alternative for RS256

[oauth.github]
client_id = "${GITHUB_CLIENT_ID}"
client_secret = "${GITHUB_CLIENT_SECRET}"
authorize_url = "https://github.com/login/oauth/authorize"
token_url = "https://github.com/login/oauth/access_token"
userinfo_url = "https://api.github.com/user"
redirect_uri = "${GITHUB_REDIRECT_URI}"
scope = "read:user user:email"

[oauth.google]
client_id = "${GOOGLE_CLIENT_ID}"
client_secret = "${GOOGLE_CLIENT_SECRET}"
authorize_url = "https://accounts.google.com/o/oauth2/v2/auth"
token_url = "https://oauth2.googleapis.com/token"
userinfo_url = "https://www.googleapis.com/oauth2/v3/userinfo"
redirect_uri = "${GOOGLE_REDIRECT_URI}"
scope = "openid email profile"

[health]
path = "/health"
check_db = true

[metrics]
enabled = false
path = "/metrics"

[logging]
level = "info"             # debug, info, warn, error
format = "json"            # json or text
access_log = true
```

### 14.2 Environment Variable Interpolation
- **[DECIDED]** `${VAR_NAME}` syntax for secrets.
- **[OPEN]** `.env` file support? Or rely on actual env vars?
  - Recommendation: Support .env file in dev, actual env vars in prod.

---

## 15. Deployment

### 15.1 Process Model
- **[DECIDED]** Single process, multiple worker threads.
- **[OPEN]** Multi-process mode (fork)?
  - For process-level isolation and crash recovery.
  - Recommendation: [DEFER] v2. Single process is simpler. Use k8s replicas
    for horizontal scaling.
- **[DECIDED]** Graceful shutdown protocol:
  1. SIGTERM received → stop accepting new connections
  2. In-flight HTTP requests: wait up to `shutdown_timeout` (default 30s) for completion
  3. In-flight WebSocket connections: send Close frame, wait up to `ws_drain_timeout` (default 5s)
  4. Background tasks: wait up to `task_drain_timeout` (default 10s) for completion, then cancel
  5. Database connections: close pool (wait for in-flight queries to complete)
  6. Redis connections: close pool
  7. Run @app.on_shutdown hooks
  8. Exit
- **[DECIDED]** SIGINT: same protocol but with shorter timeouts (halved).
- **[DECIDED]** Second SIGTERM/SIGINT: immediate exit (for stuck shutdowns).

### 15.2 Container Support
- **[OPEN]** Docker base image recommendations
- **[OPEN]** Health check compatibility with k8s probes
- **[OPEN]** Signal handling for container orchestrators

### 15.3 Systemd
- **[OPEN]** Systemd socket activation — receive fds from systemd
- **[OPEN]** Notify protocol — sd_notify for readiness signaling
- **[OPEN]** Watchdog — periodic sd_notify to prove liveness

---

## 16. Testing

### 16.1 Test Client
- **[DECIDED]** Full-stack test client (real HTTP over loopback, not mocked). Spins up snek
  in-process, makes real HTTP requests. Tests what you ship.
  ```python
  from snek.testing import TestClient

  client = TestClient(app)
  resp = client.get("/users/42")
  assert resp.status == 200
  assert resp.json()["name"] == "Dzara"
  ```
- **[DECIDED]** Conformance test infrastructure. Must pass:
  - Autobahn TestSuite (WebSocket RFC 6455)
  - h2spec (HTTP/2)
  - testssl.sh (TLS)
- **[OPEN]** Database testing — test transactions that auto-rollback?

---

## 17. OpenAPI / Documentation

- **[DECIDED]** Auto-generated OpenAPI 3.1 specs from route decorators, `snek.Model`
  definitions, and type annotations.
- **[DECIDED]** Built-in Swagger UI at `/docs`, ReDoc at `/redoc`, raw JSON at `/openapi.json`.
- **[DECIDED]** CDN-loaded UI (no bundled assets). Only active in debug mode or when
  `docs.enabled = true` in snek.toml.
- **[DECIDED]** Constraint mapping from `snek.Model` annotations to OpenAPI schema:
  - `Gt(0)` → `{"exclusiveMinimum": 0}`
  - `Ge(0)` → `{"minimum": 0}`
  - `Lt(100)` → `{"exclusiveMaximum": 100}`
  - `Le(100)` → `{"maximum": 100}`
  - `MinLen(1)` → `{"minLength": 1}`
  - `MaxLen(100)` → `{"maxLength": 100}`
  - `Pattern(r"...")` → `{"pattern": "..."}`
  - `OneOf(...)` → `{"enum": [...]}`

---

## 18. FFI / Extensibility

### 18.1 Zig Extension API
- **[OPEN]** Can users write Zig extensions for snek?
  - Custom I/O operations, custom protocol handlers, custom middleware in Zig
  - Loaded as Zig packages? Dynamic .so? 
  - [DEFER] v2. Focus on Python-only usage first.

### 18.2 C Library Interop
- **[OPEN]** Can Python handlers call C libraries (numpy, etc.)?
  - Yes, it's just CPython. C extensions work normally.
  - But: C extensions that do their own I/O won't be fiber-aware.
  - Document this: C library I/O blocks the worker thread.

---

## 19. Deterministic Simulation Testing (VOPR-style)

### 19.1 Architecture
- **[DECIDED]** All I/O abstracted behind `comptime IO: type` interfaces.
  Every subsystem — scheduler, connection pool, HTTP parser, Postgres driver,
  Redis client, TLS — is generic over its I/O backend.
- **[DECIDED]** `FakeIO` backend (~200 lines) driven by a deterministic PRNG.
  Single `u64` seed reproduces any execution exactly.
- **[DECIDED]** Simulated time. The simulator controls the clock. No real
  `sleep()` or wall-clock reads in testable code.

### 19.2 What the simulator controls
- **Network**: packet delivery, drops, reordering, delay (exponential distribution)
- **Storage**: read/write faults, corruption, latency spikes
- **Time**: virtual clock advanced by the simulator (enables 1000x speedup)
- **io_uring completions**: simulated SQ/CQ ring behavior
- **GIL contention**: simulated acquire delays, long-held GIL scenarios
- **Client behavior**: slow clients, mid-request disconnects, malformed input

### 19.3 What it verifies
- No leaked connections in the pool under any fault sequence
- No stuck coroutines (liveness)
- Graceful shutdown drains all in-flight requests
- Connection pool doesn't deadlock or starve
- Scheduler correctly steals work and parks/wakes threads
- Request lifecycle completes or errors cleanly under all fault combinations
- Transaction rollback fires on every error path

### 19.4 Swarm testing
- Randomize fault injection parameters per run (probabilities, delays, limits)
- Run thousands of seeds in CI, each exploring different fault combinations
- Any failure → report seed → developer replays exact execution locally

### 19.5 Coverage marks (TigerBeetle pattern)
- Mark code paths with `coverage.mark("pool_exhaustion_queued")`
- Simulator asserts marks were hit: `coverage.check("pool_exhaustion_queued")`
- Creates traceable links from tests to exact code paths they exercise

---

## 20. Durable Execution Runtime (v2)

**[DEFER]** v2 feature. Temporal-inspired durable execution built on snek's runtime.

### 20.1 Vision
snek becomes a full production application runtime, not just a web framework.
The web framework is the entry point; underneath, handlers get:
- **Append-only event log** — source of truth for all state transitions
- **Exactly-once job queue** — background tasks with delivery guarantees
- **DAG workflow scheduler** — workflows as directed graphs of steps
- **Sagas / compensation** — step 3 fails → auto-run compensating actions for steps 1-2
- **Deterministic replay** — reproduce any execution from the event log

### 20.2 Key Architectural Insight (from Temporal)
Separate "what happened" (event log) from "what to do next" (scheduler).
The log is append-only. The scheduler replays it to reconstruct state. If the
process crashes mid-workflow, restart → replay log → continue from last event.

### 20.3 Why v2
- Requires the v1 runtime to be solid (scheduler, IO, coroutines, DB, Redis)
- The Generic-over-IO + VOPR foundation already enables deterministic replay
- Event sourcing changes the handler model (events first, effects derived)
- Scope is massive but the v1 infrastructure is the right foundation

### 20.4 Python API (aspirational)
```python
@app.workflow("onboard_user")
async def onboard(user: User):
    account = await create_account(user)          # step 1
    await send_welcome_email(account)             # step 2
    await provision_resources(account)            # step 3
    # If step 3 fails: compensate step 2 (unsend?), step 1 (delete account)

@app.task(retries=3, timeout=30)
async def create_account(user: User) -> Account:
    return await app.db.fetch_one("INSERT INTO accounts ... RETURNING *", user.email)
```

Each step is logged. On crash, replay the log, skip completed steps, resume.
Like Temporal workflows but native to the web framework.

---

## 21. Build Order (What We Build First)

### Phase 1: Foundation
1. Generic IO interface (`comptime IO: type`) + io_uring backend + kqueue backend
2. FakeIO backend + deterministic simulation harness (from day one)
3. Stackless coroutine types + comptime pipeline builder
4. Work-stealing scheduler (generic over IO)
5. TCP accept loop
6. HTTP/1.1 parser (request)
7. HTTP/1.1 serializer (response)
8. **Milestone: snek serves "hello world" over HTTP (and simulation tests pass)**

### Phase 2: Python Integration
8. CPython C extension (_snek)
9. App/route registration from Python decorators
10. Coroutine driving protocol (coro.send)
11. Type annotation inspection + argument coercion
12. Dependency injection system
13. **Milestone: snek runs Python handlers with DI**

### Phase 3: Database + Redis
14. Postgres wire protocol (connect, auth, query, parse results)
15. Redis RESP3 protocol + connection pool
16. Connection pools (Postgres + Redis)
17. DbQuery / RedisOp sentinels + suspend/resume across Python↔Zig
18. schema.sql parser
19. Query validation at startup
20. **Milestone: snek runs handlers with Postgres and Redis**

### Phase 4: Production Features
21. TLS termination (OpenSSL via @cImport)
22. JSON codec (Zig-native parse + serialize)
23. Request body parsing (JSON, form, multipart)
24. Validation engine (fused decode+validate from type annotations)
25. Response compression (gzip, brotli)
26. CORS, security headers (from snek.toml)
27. Session middleware (Redis-backed)
28. Static file serving
29. Logging + metrics
30. CLI (snek run, snek db, snek check)
31. OpenAPI 3.1 generation + Swagger UI / ReDoc
32. **Milestone: snek is production-usable**

### Phase 5: Advanced
33. HTTP/2 (HPACK, stream mux)
34. WebSocket (Autobahn-conformant)
35. HTTP client (outbound, io_uring-backed)
36. JWT validation
37. Server-Sent Events / streaming responses
38. LISTEN/NOTIFY
39. app.gather() for parallel queries
40. Dev mode (file watching, reload, debug error pages)
41. Test client (full-stack over loopback)
42. **Milestone: snek is feature-complete for v1**

---

## Open Questions Summary (Needs Your Input)

Remaining high-impact decisions:

1. **Cancellation semantics** — what happens when client disconnects mid-handler?
2. **HTTP/2 build vs borrow** — write from scratch or adapt http2.zig?
3. **License** — MIT? Apache 2.0? Something else?
4. **io_uring configuration** — ring size, SQPOLL, registered buffers
5. **Free-threaded Python** — when to support PEP 703 / no-GIL mode?