# Middleware & Pipeline Architecture: State of the Art Reference

> Research compiled 2026-03-21. Covers production middleware systems across Rust, Go, C, Zig, Python, TypeScript/.NET.

---

## Table of Contents

1. [Tower (Rust) — Service + Layer](#1-tower-rust)
2. [tower-async (Rust) — Simplified Tower fork](#2-tower-async-rust)
3. [Axum (Rust) — Tower in practice](#3-axum-rust)
4. [Actix-web (Rust) — Transform-based middleware](#4-actix-web-rust)
5. [Gin (Go) — Index-based handler chain](#5-gin-go)
6. [Echo (Go) — Functional composition with skipper](#6-echo-go)
7. [Fiber (Go) — Zero-allocation fasthttp middleware](#7-fiber-go)
8. [ASP.NET Core — The reference pipeline architecture](#8-aspnet-core)
9. [Express (Node.js) — Sequential next() chain](#9-express-nodejs)
10. [Koa (Node.js) — Onion model with compose](#10-koa-nodejs)
11. [ASGI / Starlette (Python) — What NOT to do](#11-asgi--starlette-python)
12. [http.zig — Comptime middleware chains](#12-httpzig)
13. [Zap (Zig) — Type-safe context middleware](#13-zap-zig)
14. [Horizon (Zig) — Modern Zig middleware](#14-horizon-zig)
15. [TurboAPI (Python+Zig) — Hybrid FFI middleware](#15-turboapi-pythonzig)
16. [Nginx (C) — Phase-based handler chain](#16-nginx-c)
17. [Cross-cutting analysis](#17-cross-cutting-analysis)
18. [Design recommendations for snek](#18-design-recommendations-for-snek)

---

## 1. Tower (Rust)

**URL:** https://github.com/tower-rs/tower
**Language:** Rust
**Production exposure:** Extremely high — foundational to axum, tonic (gRPC), hyper, Linkerd proxy

### Core Traits

```rust
// tower-service crate (kept maximally stable, separate from tower)
pub trait Service<Request> {
    type Response;
    type Error;
    type Future: Future<Output = Result<Self::Response, Self::Error>>;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>>;
    fn call(&mut self, req: Request) -> Self::Future;
}

// tower-layer crate
pub trait Layer<S> {
    type Service;
    fn layer(&self, inner: S) -> Self::Service;
}
```

### Key Design Decisions

1. **`poll_ready` for backpressure.** Services explicitly signal capacity before accepting requests. This enables load shedding, rate limiting, connection pool management. The caller must check readiness before calling — violating this contract may panic. This is the most sophisticated backpressure mechanism in any middleware system.

2. **Associated `type Future` instead of `Box<dyn Future>`.** Allows zero-cost middleware — concrete future types compose without heap allocation. The tradeoff: writing custom `Future` implementations is painful (pin projections, manual poll). Libraries like `pin-project` mitigate this.

3. **`call` takes `&mut self`.** Enables stateful middleware (connection pools, counters). The consequence: services must be `Clone`able for concurrent use, and the async block must move owned state (typically via clone) to avoid lifetime issues.

4. **Trait separation.** `Service` and `Layer` live in tiny, maximally-stable crates (`tower-service`, `tower-layer`) because they are ecosystem integration points. Implementation middleware lives in `tower` proper.

5. **Request is generic, Response is associated.** A service handles one request type but its response type is fixed for that request. This enables protocol-agnostic middleware (Timeout works with any request/response pair).

### Middleware Pattern (Timeout example)

```rust
struct Timeout<S> { inner: S, timeout: Duration }

impl<S, Req> Service<Req> for Timeout<S>
where S: Service<Req>
{
    type Response = S::Response;
    type Error = Box<dyn Error>;  // Tower uses boxed errors
    type Future = ResponseFuture<S::Future>;

    fn poll_ready(&mut self, cx: &mut Context) -> Poll<Result<(), Self::Error>> {
        self.inner.poll_ready(cx)  // Forward backpressure
    }

    fn call(&mut self, req: Req) -> Self::Future {
        ResponseFuture {
            response_future: self.inner.call(req),
            sleep: tokio::time::sleep(self.timeout),
        }
    }
}
```

### Error Handling

Tower uses `Box<dyn Error + Send + Sync>` for errors. Rationale: with nested middleware, error types compound (e.g., `TimeoutError<RateLimitError<AuthError<...>>>`). Boxed errors flatten this. Tradeoff: loses static typing.

### Performance Characteristics

- Zero allocation per request when using concrete future types
- Each middleware layer adds a future to the stack (no heap)
- `ServiceBuilder` composes layers at startup — the chain is fully resolved before any request
- Clone cost on each request (service must be cloned into the spawned task)

### Lessons

- The `poll_ready` / `call` split is brilliant for backpressure but adds complexity for simple middleware that doesn't care. Most middleware just forwards `poll_ready`.
- Boxed errors are pragmatic but lose type information.
- The compile-time chain resolution (via `ServiceBuilder`) is the gold standard for startup-resolved pipelines.
- Concrete future types are the performance ideal but the ergonomic worst — this is the core tension.

---

## 2. tower-async (Rust)

**URL:** https://docs.rs/tower-async
**Language:** Rust
**Production exposure:** Lower than Tower, used in projects that prefer ergonomics

### Simplified Trait

```rust
pub trait Service<Request> {
    type Response;
    type Error;

    fn call(&self, req: Request) -> impl Future<Output = Result<Self::Response, Self::Error>>;
}
```

### Key Differences from Tower

| Aspect | Tower | tower-async |
|--------|-------|-------------|
| `poll_ready` | Required | Removed |
| `call` receiver | `&mut self` | `&self` |
| Future type | Associated type | `impl Future` (RPITIT) |
| Backpressure | Built into trait | External middleware concern |
| Ergonomics | Hard | Easy (native async/await) |

### Design Rationale

- `poll_ready` removal: backpressure is pushed to dedicated middleware at the front of the chain, or handled at service creation time.
- `&self` instead of `&mut self`: removes Clone requirement for concurrent use.
- Uses Rust's `async fn in traits` (RFC 3185) — no manual Future implementations needed.
- Tradeoff: all futures are implicitly boxed (cannot name the return type for zero-cost composition).

### Lessons

- Demonstrates that `poll_ready` is optional if backpressure is handled architecturally.
- The ergonomic gain is massive — middleware authors write normal async functions.
- Shows the design space between "maximum performance" (Tower) and "maximum usability" (tower-async).

---

## 3. Axum (Rust)

**URL:** https://docs.rs/axum
**Language:** Rust
**Production exposure:** Very high — default Rust web framework in the Tokio ecosystem

### Middleware Patterns

Axum provides multiple middleware APIs on top of Tower:

1. **`from_fn`** — Write middleware as async functions (most common):
   ```rust
   async fn my_middleware(req: Request, next: Next) -> Response {
       // before
       let response = next.run(req).await;
       // after
       response
   }
   ```

2. **`from_extractor`** — Use extractors as middleware (reject requests that fail extraction).

3. **`map_request` / `map_response`** — Transform only request or response.

4. **Full Tower `Service` implementation** — For publishable, zero-cost middleware.

### Ordering Semantics

**Critical detail:** `.layer()` calls wrap bottom-to-top (onion model):

```
// Registration order:
router.layer(layer_one).layer(layer_two).layer(layer_three)

// Execution order:
request → layer_three → layer_two → layer_one → handler
         → layer_one → layer_two → layer_three → response
```

Using `tower::ServiceBuilder` reverses this to top-to-bottom (more intuitive):

```rust
// ServiceBuilder makes it intuitive:
ServiceBuilder::new()
    .layer(layer_one)    // executes first
    .layer(layer_two)    // executes second
    .layer(layer_three)  // executes third
```

### State in Middleware

- `from_fn_with_state` passes application state to middleware functions
- State can be forwarded to handlers via request extensions (`req.extensions_mut().insert(value)`)
- This is the request-scoped state propagation mechanism

### Lessons

- The `from_fn` pattern is the ergonomic sweet spot — familiar async/await, no manual futures.
- Middleware ordering is confusing with raw `.layer()` — `ServiceBuilder` fixes this.
- Request extensions (`http::Extensions`) serve as a typed key-value map for request-scoped state.

---

## 4. Actix-web (Rust)

**URL:** https://github.com/actix/actix-web
**Language:** Rust
**Production exposure:** High — one of the most popular Rust web frameworks

### Architecture: Transform + Service Pairs

```rust
// Transform is the builder (like Tower's Layer)
pub trait Transform<S, Req> {
    type Response;
    type Error;
    type Transform: Service<Req>;
    type InitError;
    type Future: Future<Output = Result<Self::Transform, Self::InitError>>;

    fn new_transform(&self, service: S) -> Self::Future;
}
```

### Key Design Decisions

1. **Async initialization.** `new_transform` returns a Future — middleware can perform async setup (database connections, config loading). Tower's `Layer::layer` is synchronous.

2. **Per-thread service instances.** Services created by `new_transform` don't need to be `Send` or `Sync`. Actix uses a per-thread architecture where each worker builds its own service chain.

3. **Reverse registration order.** Last-registered middleware executes first (wrapping model, like Tower).

4. **`from_fn()` helper.** Simple async function middleware without full Transform implementation.

### Tradeoffs vs Tower

| Aspect | Actix | Tower |
|--------|-------|-------|
| Init | Async (Future) | Sync |
| Thread safety | Not required | Required |
| Backpressure | No poll_ready | poll_ready |
| Ecosystem | Actix-only | Cross-framework |

### Lessons

- Async middleware initialization is genuinely useful (database pools, config).
- Per-thread services eliminate Send/Sync bounds — simpler middleware code.
- The ecosystem lock-in is the major downside — actix middleware doesn't work outside actix.

---

## 5. Gin (Go)

**URL:** https://github.com/gin-gonic/gin
**Language:** Go
**Production exposure:** Extremely high — most popular Go web framework

### Architecture: Index-Based Handler Chain

```go
type HandlerFunc func(*Context)
type HandlersChain []HandlerFunc

type Context struct {
    handlers HandlersChain
    index    int8          // Current position in chain
    Keys     map[any]any   // Request-scoped state
    mu       sync.RWMutex  // Protects Keys
    Errors   errorMsgs
    // ...
}
```

### Chain Execution

```go
func (c *Context) Next() {
    c.index++
    for c.index < int8(len(c.handlers)) {
        if c.handlers[c.index] != nil {
            c.handlers[c.index](c)
        }
        c.index++
    }
}
```

### Short-Circuiting

```go
const abortIndex int8 = math.MaxInt8 >> 1  // 63

func (c *Context) Abort() {
    c.index = abortIndex  // Jumps past all handlers
}

func (c *Context) AbortWithStatus(code int) {
    c.Status(code)
    c.Writer.WriteHeaderNow()
    c.Abort()
}

func (c *Context) AbortWithStatusJSON(code int, jsonObj any) { ... }
func (c *Context) AbortWithError(code int, err error) *Error { ... }
```

### Request-Scoped State

```go
func (c *Context) Set(key any, value any) {
    c.mu.Lock()
    defer c.mu.Unlock()
    if c.Keys == nil {
        c.Keys = make(map[any]any)
    }
    c.Keys[key] = value
}

func (c *Context) Get(key any) (value any, exists bool) {
    c.mu.RLock()
    defer c.mu.RUnlock()
    value, exists = c.Keys[key]
    return
}
```

Typed accessors: `GetString()`, `GetInt()`, `GetBool()` via generics.

### Key Design Decisions

1. **int8 index limits chain to 127 handlers.** Practical but hard-coded.
2. **`Copy()` for goroutine safety.** Context must be cloned for use outside request scope.
3. **RWMutex on Keys.** Thread-safe state map — necessary because Go handlers may spawn goroutines.
4. **HandlersChain is a slice.** Chain is built at route registration time, not per-request.
5. **Abort via index jump.** No boolean flag — just sets index past all handlers.

### Performance

- Chain is a flat slice — no function pointer indirection beyond the slice lookup.
- Context is pooled (`sync.Pool`) — zero allocation per request for the context object.
- Keys map is lazily allocated (nil until first Set call).

### Lessons

- Index-based traversal is simple and fast — no recursion, no allocation.
- Abort via sentinel index is elegant.
- The flat handler chain is resolved at route registration (startup), not per-request.
- RWMutex on state is necessary overhead in Go's concurrent model.

---

## 6. Echo (Go)

**URL:** https://github.com/labstack/echo
**Language:** Go
**Production exposure:** High — second most popular Go web framework

### Architecture: Functional Composition

```go
type HandlerFunc func(c *Context) error
type MiddlewareFunc func(next HandlerFunc) HandlerFunc
```

### Chain Building

```go
func applyMiddleware(h HandlerFunc, middleware ...MiddlewareFunc) HandlerFunc {
    for i := len(middleware) - 1; i >= 0; i-- {
        h = middleware[i](h)
    }
    return h
}
```

### Skipper Pattern

Echo middleware conventionally accepts a `Skipper` function:

```go
type Skipper func(c echo.Context) bool

type MiddlewareConfig struct {
    Skipper Skipper
    // ... other config
}
```

The skipper lets middleware conditionally bypass itself based on the request — e.g., skip auth for health check endpoints.

### Two-Phase Middleware

1. **Pre-middleware** — Executes before routing (even for 404s).
2. **Standard middleware** — Executes after route matching, before handler.

### Key Differences from Gin

| Aspect | Gin | Echo |
|--------|-----|------|
| Chain model | Index + slice | Functional composition |
| Next mechanism | `c.Next()` mutates index | Wrapped handler call |
| Error handling | `c.Errors` accumulator | Return `error` |
| Short-circuit | `c.Abort()` | Don't call `next` |
| Pre-routing MW | No | Yes (Pre) |

### Lessons

- Functional composition (wrapping) vs. index traversal — both work, wrapping is more idiomatic in functional styles.
- The Skipper pattern is elegant for conditional middleware bypass without pipeline modification.
- Error return from handlers is cleaner than error accumulation (Gin's approach).
- Pre-routing middleware is useful for concerns that apply regardless of route match (logging, request ID).

---

## 7. Fiber (Go)

**URL:** https://github.com/gofiber/fiber
**Language:** Go
**Production exposure:** High — Express-inspired, built on fasthttp

### Zero-Allocation Strategy

- Built on **fasthttp** (not net/http) — zero-copy I/O, no per-request allocation.
- `fiber.Ctx` objects are **pooled and reused** across requests.
- **Critical constraint:** values returned from `fiber.Ctx` are NOT immutable — they are reused. Callers must copy values they need to retain.

### Middleware Pattern

```go
app.Use(func(c *fiber.Ctx) error {
    // before
    err := c.Next()
    // after
    return err
})
```

Express-like `app.Use`, `c.Next()`, error returns.

### Lessons

- Context pooling eliminates GC pressure — critical for high-throughput Go servers.
- The "values are reused" contract is dangerous but fast. Most frameworks copy; Fiber doesn't.
- Shows that Express-style API can sit atop zero-allocation internals.

---

## 8. ASP.NET Core

**URL:** https://learn.microsoft.com/en-us/aspnet/core/fundamentals/middleware/
**Language:** C#
**Production exposure:** Extremely high — Microsoft's primary server framework

### Architecture: Compiled RequestDelegate Pipeline

```csharp
// The fundamental type
public delegate Task RequestDelegate(HttpContext context);

// Middleware signature
Func<RequestDelegate, RequestDelegate>
```

### Pipeline Construction (at startup, NOT per-request)

The `ApplicationBuilder.Build()` method:

1. Creates a terminal delegate (returns 404).
2. **Reverses** the middleware list.
3. Iteratively wraps each middleware around the previous delegate.
4. Returns the outermost `RequestDelegate`.

```csharp
// Simplified Build() logic:
RequestDelegate app = context => { context.Response.StatusCode = 404; return Task.CompletedTask; };
foreach (var component in _components.Reverse()) {
    app = component(app);
}
return app;
```

**This pipeline is built ONCE and reused for every request.** No per-request resolution, no middleware factory calls.

### Three Registration Patterns

1. **`Use()`** — Receives `next` delegate, can call or skip it:
   ```csharp
   app.Use(async (context, next) => {
       // before
       await next.Invoke(context);
       // after
   });
   ```

2. **`Run()`** — Terminal middleware (no `next` parameter). First `Run()` terminates the pipeline.

3. **`Map()`** — Branch the pipeline based on path prefix. Creates a sub-pipeline.

### Short-Circuiting

- Don't call `next.Invoke()` → pipeline stops, response returns.
- `Run()` delegate never receives `next` → always terminal.
- .NET 8+ added `ShortCircuit()` and `MapShortCircuit()` for explicit short-circuiting after routing, skipping all remaining middleware.

### Recommended Middleware Order

1. Exception/Error handling (outermost — catches everything)
2. HSTS
3. HTTPS Redirection
4. Static Files (can short-circuit here)
5. Routing
6. CORS
7. Authentication
8. Authorization
9. Custom middleware
10. Endpoint execution

### Middleware Lifetimes

- **Convention-based middleware:** Singleton — created once at startup, reused. Must be thread-safe.
- **IMiddleware interface:** Resolved from DI container per request — respects scoped lifetimes.

### Key Design Decisions

1. **Pipeline built once at startup.** The `RequestDelegate` chain is a compiled graph of delegates — no dictionary lookups, no factory resolution per request.
2. **HttpContext is the universal context.** All request-scoped state flows through it (Items dictionary, Features collection, User principal).
3. **Ordering is explicit and manual.** No dependency resolution — developers must get the order right.
4. **Terminal delegates prevent dead code.** `Run()` makes it impossible for later middleware to execute.

### Lessons

- The "build once, execute many" model is the performance standard.
- Branch pipelines (`Map`) enable path-specific middleware without conditional logic inside middleware.
- The recommended ordering is battle-tested and should be studied for any framework.
- Having both convention-based (singleton) and interface-based (per-request) middleware is a good flexibility pattern.

---

## 9. Express (Node.js)

**URL:** https://expressjs.com/
**Language:** JavaScript/TypeScript
**Production exposure:** Extremely high — most deployed Node.js framework

### Architecture: Sequential next() Chain

```javascript
app.use((req, res, next) => {
    // before
    next();      // continue chain
    // after (but response may already be sent)
});
```

### Error Handling

Error middleware has **4 parameters** (Express detects the arity):

```javascript
app.use((err, req, res, next) => {
    // Handle error
    // next(err) forwards to next error handler
});
```

When `next(err)` is called with any argument (except `'route'`), Express skips all normal middleware and jumps to the next error-handling middleware.

### Short-Circuiting

- Don't call `next()` → chain stops.
- Sending a response (`res.send()`, `res.json()`) without calling `next()` is the short-circuit pattern.

### Key Issues

- **Express 4:** Errors in async functions don't propagate automatically — unhandled rejections crash the process.
- **Express 5:** Async errors automatically propagate to error handlers.
- **No built-in backpressure.** If middleware is slow, requests pile up with no signaling.

### Lessons

- Arity-based error handler detection is clever but fragile.
- The lack of async error propagation in v4 caused widespread production issues.
- Express's simplicity is its strength — but the `next()` contract is easy to violate (calling next after response is sent, calling next multiple times).

---

## 10. Koa (Node.js)

**URL:** https://koajs.com/ | https://github.com/koajs/compose
**Language:** JavaScript
**Production exposure:** High — successor to Express by the same team

### Architecture: Onion Model via koa-compose

```javascript
// koa-compose core logic (simplified):
function compose(middleware) {
    return function(ctx, next) {
        let index = -1;
        function dispatch(i) {
            if (i <= index) throw new Error('next() called multiple times');
            index = i;
            const fn = i === middleware.length ? next : middleware[i];
            if (!fn) return Promise.resolve();
            return Promise.resolve(fn(ctx, () => dispatch(i + 1)));
        }
        return dispatch(0);
    }
}
```

### Onion Execution Model

```
         ┌──────────────────────────────────┐
         │  Middleware 1 (before next)       │
         │    ┌──────────────────────────┐   │
         │    │  Middleware 2 (before)    │   │
         │    │    ┌──────────────────┐   │   │
         │    │    │  Handler          │   │   │
         │    │    └──────────────────┘   │   │
         │    │  Middleware 2 (after)     │   │
         │    └──────────────────────────┘   │
         │  Middleware 1 (after next)        │
         └──────────────────────────────────┘
```

### Key Design Decisions

1. **Promise-based composition.** Every middleware is wrapped in `Promise.resolve()` — sync or async, doesn't matter.
2. **Multiple-call detection.** Tracks index to detect `next()` called more than once — throws immediately.
3. **Production vs. dev modes.** `composeSlim` in production skips safety checks for speed.
4. **Single context object.** No `req`/`res` — everything on `ctx`.

### Lessons

- The onion model gives clean before/after semantics — code after `await next()` runs in reverse order.
- Multiple-next detection prevents subtle ordering bugs.
- Production/development mode split for compose is a good optimization pattern.
- The compose function is ~30 lines — proof that middleware composition can be simple.

---

## 11. ASGI / Starlette (Python)

**URL:** https://www.starlette.io/middleware/
**Language:** Python
**Production exposure:** Very high — underlies FastAPI

### What snek should learn FROM (not copy)

#### BaseHTTPMiddleware Problems

1. **ContextVar propagation broken.** `BaseHTTPMiddleware` prevents `contextvars.ContextVar` changes from propagating upwards. If an endpoint sets a context variable, middleware reading it sees a stale value. This is a fundamental architectural flaw.

2. **Performance overhead.** BaseHTTPMiddleware is 20-30% slower than pure ASGI middleware due to:
   - anyio task group management
   - Memory object streams for message passing
   - Request body caching (entire body buffered in memory)
   - Exception context preservation

3. **Threading model complexity.** Uses anyio task groups to run the downstream app concurrently with response handling — adds coordination overhead.

4. **Body handling dilemma.** If `body()` is called, the entire request body is cached in memory. If `stream()` is used, an empty body is sent downstream to prevent hangs. Neither is ideal.

#### Pure ASGI Middleware

```python
class PureASGIMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        # Process request/response at ASGI level
        await self.app(scope, receive, send)
```

#### Middleware Ordering

1. `ServerErrorMiddleware` (automatic, outermost)
2. User middleware (top-to-bottom registration order)
3. `ExceptionMiddleware` (automatic)
4. Routing → endpoints

#### Key Design Mistakes to Avoid

1. **Don't buffer the full request body** in middleware unless absolutely necessary.
2. **Don't break context variable propagation** — this destroys observability, auth token passing, and database session management.
3. **Don't use task groups for simple request/response interception** — the overhead is massive.
4. **Don't require middleware to understand the raw protocol** (ASGI's `scope`/`receive`/`send`) — this is too low-level for most middleware authors.
5. **Statelessness requirement:** Storing mutable state on middleware instances causes cross-request data leaks in concurrent environments.

#### Performance Data

| Middleware Type | Relative Performance |
|----------------|---------------------|
| Pure ASGI | Baseline |
| BaseHTTPMiddleware | +20-30% slower |

### Lessons

- BaseHTTPMiddleware's problems are architectural, not implementation bugs.
- The right abstraction level for middleware is Request/Response, not raw protocol messages.
- Context variable propagation MUST work through middleware — it's essential for modern Python.
- Middleware should not buffer request bodies by default.

---

## 12. http.zig

**URL:** https://github.com/karlseguin/http.zig
**Language:** Zig
**Production exposure:** Moderate — powers Jetzig framework

### Architecture: Comptime-Configured Middleware Chain

Middleware is a struct with a specific compile-time interface:

```zig
pub const MyMiddleware = struct {
    pub const Config = struct {
        // Configuration parameters
    };

    // Called once at startup
    pub fn init(config: Config) MyMiddleware { ... }

    // Called per-request
    pub fn execute(
        self: *const MyMiddleware,
        req: *Request,
        res: *Response,
        next: fn() !void,
    ) !void {
        // before
        try next();
        // after
    }

    // Called on shutdown
    pub fn deinit(self: *MyMiddleware) void { ... }
};
```

### Zero-Allocation Strategy

- **Thread-local arena buffers.** `req.arena` and `res.arena` use a configurable thread-local buffer that falls back to `std.heap.ArenaAllocator`.
- **Memory budget:** `thread_pool.count * thread_pool.buffer_size` — total memory is bounded and predictable.
- **No per-request heap allocation** for normal middleware operations.

### Comptime Chain Resolution

- Middleware types are known at compile time — the chain is resolved during compilation, not at runtime.
- Zig's comptime features enable the compiler to generate optimized dispatch code.
- Configuration like `middleware_strategy = .append | .replace` determines merge behavior with global middleware.

### Lessons

- Comptime middleware chains are the ultimate "compiled pipeline" — zero runtime overhead for chain resolution.
- Arena allocators per thread eliminate per-request allocation entirely.
- The struct-based interface (Config/init/execute/deinit) is clean and discoverable.
- `next` as a function pointer is simple and avoids context threading through the call.

---

## 13. Zap (Zig)

**URL:** https://github.com/zigzap/zap
**Language:** Zig
**Production exposure:** Moderate — high-performance Zig backends

### Architecture: Type-Safe Context Middleware

```zig
// Each middleware defines its own context type
const AuthContext = struct {
    user_id: u64,
    role: []const u8,
};

// Middleware chain with typed context
var chain = zap.Middleware.init(allocator);
```

### Key Design Decisions

1. **Generic context structs.** Each middleware layer can define its own typed context — compile-time type checking on data flow between handlers.

2. **Endpoint embedding.** `zap.Middleware.EndpointHandler` allows mixing simplified endpoint APIs with custom middleware.

3. **Escape hatches.** `r.setUserContext()` and `r.getUserContext()` use `*anyopaque` — type safety sacrificed for cross-boundary access.

4. **Per-thread arena allocator.** Each request callback receives a per-thread arena — throwaway allocations without deallocation.

### Lessons

- Typed context structs at compile time are the ideal for middleware data flow — catches errors at compile time.
- The `anyopaque` escape hatch shows the tension between type safety and practicality across middleware boundaries.
- Per-thread arenas are the standard Zig pattern for request-scoped allocation.

---

## 14. Horizon (Zig)

**URL:** https://harmonicom.github.io/horizon/
**Language:** Zig
**Production exposure:** Early-stage

### Architecture

```zig
pub const CustomMiddleware = struct {
    prefix: []const u8,
    enabled: bool,

    pub fn middleware(
        self: *const Self,
        allocator: std.mem.Allocator,
        req: *horizon.Request,
        res: *horizon.Response,
        ctx: *horizon.Middleware.Context,
    ) horizon.Errors.Horizon!void {
        // Process request
        try ctx.next(allocator, req, res);  // Continue chain
    }
};
```

### Key Patterns

| Pattern | Implementation |
|---------|---------------|
| Error propagation | `Horizon!void` error union — errors bubble up through chain |
| Context threading | Allocator passed explicitly (no hidden state) |
| Control flow | `ctx.next()` — middleware decides whether to proceed |
| Composability | `use()` stacks middleware; order matters |
| Global vs route | `srv.router.middlewares.use()` vs `MiddlewareChain` per route |

### Zero-Allocation

- Allocators passed explicitly, not stored.
- Stack-allocated middleware state (struct fields).
- Zig's ownership model for borrowed references.

### Lessons

- Explicit allocator passing is the Zig way — no hidden allocation.
- Error unions propagate naturally through the chain.
- Route-specific middleware chains via `MiddlewareChain` enable per-route customization.

---

## 15. TurboAPI (Python+Zig)

**URL:** https://github.com/justrach/turboAPI
**Language:** Python + Zig
**Production exposure:** Early but benchmarked

### Architecture: Hybrid FFI Pipeline

This is the most relevant reference for snek's Zig+Python model.

#### What Runs in Zig (No GIL)

- TCP accept and connection pooling (24-thread pool)
- HTTP header parsing (8KB stack buffers)
- Radix trie route matching
- Request body buffering (16MB cap)
- JSON schema validation (dhi)
- Response serialization and socket writes
- **CORS header injection** — pre-rendered at startup, injected via `memcpy`
- Static route responses
- OPTIONS preflight handling

#### What Runs in Python (Requires GIL)

- Handler execution
- Business logic
- Async operations
- Dependency resolution

#### Handler Classification (at startup)

| Tier | Description | GIL? |
|------|-------------|------|
| `native_ffi` | C/Zig shared library | No |
| `simple_sync_noargs` | Zero-param GET | Minimal |
| `model_sync` | POST with dhi validation | After validation |
| `simple_sync` | GET with path/query params | Yes |
| `body_sync` | POST without validation | Yes |
| `enhanced` | Full Python dispatch | Yes |

#### Key Design Decision: Validate Before GIL

For POST requests with models:
1. Body read in Zig
2. JSON parsing in Zig
3. Schema validation in Zig
4. Invalid → 422 response **without acquiring GIL**
5. Valid → Convert JSON tree to Python dict → Call handler

#### CORS: 0% Overhead

Headers pre-rendered at startup, injected via `memcpy`. Python middleware-based CORS adds 24% latency.

#### Performance

| Endpoint | TurboAPI | FastAPI | Speedup |
|----------|----------|---------|---------|
| GET /health | 179,113/s | 11,168/s | 16.0x |
| POST /items | 155,687/s | 8,667/s | 18.0x |

Average latency: 0.13ms vs 9.3ms.

### Lessons for snek

- **Middleware that doesn't need Python should run in Zig.** CORS, rate limiting, compression, static files, validation — all can be Zig-side.
- **Pre-render headers at startup** — eliminates per-request string formatting.
- **Validate before acquiring GIL** — reject bad requests without touching Python.
- **Handler classification** determines the optimal dispatch path — decide at startup, not per-request.
- **FFI overhead is negligible** (~0.2µs) — the boundary cost is near-zero.

---

## 16. Nginx (C)

**URL:** https://nginx.org/en/docs/dev/development_guide.html
**Language:** C
**Production exposure:** Maximum — handles ~35% of web traffic

### Architecture: Phase-Based Handler Chain

Nginx processes requests through 11 phases, each with registered handlers:

| Phase | Purpose | Custom handlers? |
|-------|---------|-----------------|
| `SERVER_REWRITE` | Server-level URI rewrite | Yes |
| `FIND_CONFIG` | Location lookup | No (internal) |
| `REWRITE` | Location-level URI rewrite | Yes |
| `POST_REWRITE` | Post-rewrite processing | No (internal) |
| `PREACCESS` | Resource limits | Yes |
| `ACCESS` | Access control | Yes |
| `POST_ACCESS` | Access result interpretation | No (internal) |
| `TRY_FILES` | try_files directive | No (internal) |
| `CONTENT` | Response generation | Yes |
| `LOG` | Logging | Yes |

### Handler Return Values

| Return | Meaning |
|--------|---------|
| `NGX_OK` | Proceed to next phase |
| `NGX_DECLINED` | Continue to next handler in same phase |
| `NGX_AGAIN` / `NGX_DONE` | Suspend, await events, resume |
| `NGX_ERROR` | Terminate with error |

### Filter Chain (separate from phases)

Output filters use Chain of Responsibility:
- Each filter processes output and calls the next.
- Filters don't wait for previous filter to finish — pipeline-style processing.
- `ngx_chain_t` links are pooled from `ngx_pool_t` for reuse (zero allocation).

### Key Design Decisions

1. **Phases are fixed at compile time.** You register handlers into specific phases — you cannot create new phases.
2. **LIFO within phases.** Last-registered handler in a phase executes first.
3. **Separation of concerns by phase.** Access control can ONLY run in ACCESS phase — enforced architecturally.
4. **Chain link pooling.** `ngx_alloc_chain_link(pool)` reuses chain links from a pool.

### Lessons

- Phase-based architecture enforces ordering at the framework level — developers cannot mess up the order of fundamentally different concerns.
- Fixed phases eliminate ordering ambiguity — access checks always run before content generation.
- Filter chain pooling shows that even C achieves zero-allocation middleware with proper pool design.
- The suspend/resume model (`NGX_AGAIN`) enables non-blocking middleware in a single-threaded event loop.

---

## 17. Cross-Cutting Analysis

### Middleware Composition Models

| Model | Frameworks | Characteristics |
|-------|-----------|-----------------|
| **Onion/Wrapping** | Tower, Koa, ASP.NET, Axum, Actix | Each middleware wraps the next; before/after semantics via await |
| **Index-based chain** | Gin, Express | Flat array traversal; `next()` advances index |
| **Functional composition** | Echo | `func(next) -> handler` wrapping; chain built by folding |
| **Phase-based** | Nginx | Fixed phases with handler slots; enforced ordering |
| **Comptime chain** | http.zig | Chain resolved at compile time; zero runtime overhead |

### Short-Circuiting Patterns

| Framework | Mechanism |
|-----------|-----------|
| Tower | Return error from `call` or return response without calling inner service |
| Gin | `c.Abort()` sets index to sentinel (63) |
| Echo | Don't call `next` handler |
| ASP.NET | Don't call `next.Invoke()`; or use `ShortCircuit()` (.NET 8+) |
| Express | Don't call `next()`; or call `next(err)` to jump to error handlers |
| Koa | Don't call `await next()` |
| Nginx | Return `NGX_OK` (skip to next phase) or `NGX_ERROR` (terminate) |

### Error Propagation

| Strategy | Frameworks | Tradeoffs |
|----------|-----------|-----------|
| **Boxed errors** | Tower | Flexible, loses type info |
| **Error return** | Echo, Fiber, Koa | Clean, requires consistent handling |
| **Error accumulator** | Gin (`c.Errors`) | Collects multiple errors, not standard |
| **Arity-based error MW** | Express | Fragile (4-arg detection), clever |
| **Error union** | http.zig, Horizon, Zap | Compile-time checked, Zig-native |
| **Exception** | ASP.NET, Starlette | Unwind through chain, caught by outermost |

### Request-Scoped State

| Mechanism | Frameworks | Type Safety |
|-----------|-----------|-------------|
| `map[any]any` + mutex | Gin | None (runtime cast) |
| `http::Extensions` (TypeMap) | Axum/Tower | Typed (generic get<T>) |
| `HttpContext.Items` | ASP.NET | Partial (dictionary) |
| `ctx.state` | Koa | None (JS dynamic) |
| `req.extensions()` | Express | None (JS dynamic) |
| Typed context structs | Zap | Full (compile-time) |
| `contextvars.ContextVar` | Python/ASGI | Full (typed, but broken in BaseHTTPMiddleware) |

### Pipeline Resolution Timing

| Timing | Frameworks | Performance Impact |
|--------|-----------|-------------------|
| **Compile-time** | http.zig, Zap | Zero overhead — chain is code |
| **Startup** | ASP.NET, Tower/ServiceBuilder, TurboAPI | Near-zero — delegate chain built once |
| **Route registration** | Gin, Echo | Near-zero — chain built when routes added |
| **Per-request** | Express, Koa, Starlette | Overhead — chain walked each request |

### Backpressure

| Approach | Frameworks |
|----------|-----------|
| Explicit `poll_ready` | Tower |
| External/architectural | tower-async, most frameworks |
| None (rely on OS TCP backpressure) | Express, Gin, Echo, Koa |

---

## 18. Design Recommendations for snek

Based on this research, here are the architectural patterns most relevant to snek's Zig+Python hybrid model:

### 1. Two-Tier Middleware: Zig-side and Python-side

Following TurboAPI's proven model:

**Zig-side middleware** (no GIL, maximum performance):
- CORS (pre-render headers at startup)
- Compression
- Rate limiting
- Request validation / schema checking
- Static file serving
- Request ID generation
- Timing/metrics collection
- Security headers

**Python-side middleware** (requires GIL, for business logic):
- Authentication (may need database)
- Authorization
- Custom business logic middleware
- Session management

### 2. Compiled Pipeline (resolve at startup)

Follow ASP.NET and Tower's `ServiceBuilder` model:
- Build the complete middleware chain once at application startup.
- Store as a function pointer chain (Zig) or delegate chain (Python).
- No per-request chain resolution, no dictionary lookups.

### 3. Middleware Interface

Inspired by http.zig's struct pattern, adapted for snek:

```zig
pub const Middleware = struct {
    // Resolved at startup
    pub const Config = struct { ... };

    pub fn init(config: Config) @This() { ... }

    // Called per-request — the hot path
    pub fn execute(
        self: *const @This(),
        ctx: *RequestContext,   // typed, not anyopaque
        next: *const fn(*RequestContext) Error!void,
    ) Error!void {
        // before
        try next(ctx);
        // after
    }

    pub fn deinit(self: *@This()) void { ... }
};
```

### 4. Request Context (not anyopaque)

Avoid Gin's `map[any]any` and Zap's `*anyopaque`. Use typed context:
- Zig-side: struct with known fields (request, response, timing, request_id).
- Python-side: typed extensions via a mechanism that preserves compile-time safety on the Zig side.

### 5. Short-Circuiting

Adopt Gin's sentinel approach adapted for Zig:
- Don't call `next` → chain stops.
- Error return → chain stops, error propagates up through error unions.
- No sentinel index tricks needed — Zig error unions handle this naturally.

### 6. Error Propagation

Use Zig error unions — they are the ideal error propagation mechanism:
- Compile-time checked.
- Zero-cost when no error.
- Natural unwinding through the chain.
- No boxing, no dynamic dispatch.

### 7. Ordering

Follow nginx's philosophy of phase-like ordering, but with lighter touch:
- Define middleware phases: `pre_routing`, `post_routing`, `pre_handler`, `post_handler`, `on_error`, `on_response`.
- Within each phase, execute in registration order.
- This prevents developers from accidentally running auth before routing or logging after response.

### 8. What NOT to Do (lessons from Starlette/ASGI)

- Do NOT buffer request bodies in middleware by default.
- Do NOT break context variable propagation.
- Do NOT use task groups for simple request/response interception.
- Do NOT require middleware authors to understand the raw protocol layer.
- Do NOT resolve middleware chains per-request.

---

## Sources

### Frameworks
- [Tower (Rust)](https://github.com/tower-rs/tower) | [Service trait docs](https://docs.rs/tower/latest/tower/trait.Service.html) | [Layer trait docs](https://docs.rs/tower/latest/tower/trait.Layer.html)
- [tower-async](https://docs.rs/tower-async/latest/tower_async/trait.Service.html)
- [Axum middleware](https://docs.rs/axum/latest/axum/middleware/index.html)
- [Actix-web](https://github.com/actix/actix-web)
- [Gin](https://github.com/gin-gonic/gin)
- [Echo](https://github.com/labstack/echo)
- [Fiber](https://github.com/gofiber/fiber)
- [ASP.NET Core Middleware](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/middleware/)
- [Express.js](https://expressjs.com/en/guide/writing-middleware.html)
- [Koa / koa-compose](https://github.com/koajs/compose)
- [Starlette middleware](https://www.starlette.io/middleware/)
- [http.zig](https://github.com/karlseguin/http.zig)
- [Zap](https://github.com/zigzap/zap)
- [Horizon](https://harmonicom.github.io/horizon/)
- [TurboAPI](https://github.com/justrach/turboAPI)
- [Nginx development guide](https://nginx.org/en/docs/dev/development_guide.html) | [Nginx phases](https://www.nginxguts.com/2011/01/phases.html)

### Key Articles
- [Inventing the Service trait (Tokio blog)](https://tokio.rs/blog/2021-05-14-inventing-the-service-trait) — Essential reading on Tower's design rationale
- [Building Tower middleware from scratch](https://github.com/tower-rs/tower/blob/master/guides/building-a-middleware-from-scratch.md)
- [How ASP.NET Core middleware pipeline is built](https://www.stevejgordon.co.uk/how-is-the-asp-net-core-middleware-pipeline-built)
- [Analysing FastAPI middleware performance](https://medium.com/@ssazonov/analysing-fastapi-middleware-performance-8abe47a7ab93)
- [Middleware as Chain of Responsibility](https://leapcell.io/blog/unpacking-middleware-in-web-frameworks-a-chain-of-responsibility-deep-dive)
- [Zig+Python web server architecture](https://dev.to/brogrammerjohn/a-performant-and-extensible-web-server-with-zig-and-python-4adl)
- [Comptime as Configuration (http.zig)](https://www.openmymind.net/Comptime-as-Configuration/)
- [ASP.NET Core middleware ordering](https://thesoftwarearchitect.com/proper-ordering-of-middleware-components-in-asp-net-core/)
- [Short-circuit routing in .NET 8](https://andrewlock.net/exploring-the-dotnet-8-preview-short-circuit-routing/)


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-ad021a31b338875f5.jsonl`
