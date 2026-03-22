# Dependency Injection: State of the Art Reference

Exhaustive survey of DI implementations across languages, with focus on web framework integration,
scoping, async lifecycle management, and testing patterns. Compiled March 2026.

---

## Table of Contents

1. [Python: FastAPI Depends()](#fastapi-depends)
2. [Python: python-dependency-injector](#python-dependency-injector)
3. [Python: Dishka](#dishka)
4. [Python: Lagom](#lagom)
5. [Python: that-depends](#that-depends)
6. [Python: injector](#injector)
7. [Python: Other Notable Libraries](#python-other)
8. [Rust: DI Patterns](#rust-di)
9. [Go: DI Patterns](#go-di)
10. [C#: ASP.NET Core DI](#aspnet-core-di)
11. [TypeScript: NestJS DI](#nestjs-di)
12. [Java: Spring DI](#spring-di)
13. [Cross-Cutting Concerns](#cross-cutting)
14. [Lessons & Design Principles](#lessons)
15. [C#/Unity: Zenject / Extenject](#zenject)

---

## 1. FastAPI Depends() {#fastapi-depends}

- **URL**: https://fastapi.tiangolo.com/tutorial/dependencies/
- **Language**: Python
- **Stars**: 85k+ (FastAPI itself)

### Design

FastAPI's `Depends()` is a function-level DI system built on top of Starlette. Dependencies are
declared as function parameters with `Depends(callable)` annotations. The framework resolves the
dependency graph per-request, calling each dependency function (or class `__init__`) and injecting
results into the route handler.

### Key Strengths

- **Intuitive API**: `Depends(get_db)` in a function signature is dead simple.
- **Dependency caching per request**: Same dependency used twice in one request resolves once.
- **Yield-based lifecycle**: `async def get_db(): ... yield db ... db.close()` provides clean
  setup/teardown within request scope.
- **Sub-dependencies**: Dependencies can themselves declare dependencies, forming a DAG.
- **Type-hint driven**: Works with Python's type system, good IDE support.

### Critical Limitations

- **No DI in middleware**: Middleware runs at Starlette level, below FastAPI's dependency resolution.
  `Depends()` simply does not work in middleware classes. This is a fundamental architectural
  constraint, not a bug. ([GitHub issue #402](https://github.com/fastapi/fastapi/issues/402))
  - Workaround: Store resources in `request.state` from middleware, access in routes.
  - Workaround: Use router-level dependencies instead of middleware.
  - Workaround: Use yield-based dependencies for lifecycle management instead of middleware.
- **No DI outside HTTP**: Background tasks, CLI commands, scheduled jobs, workers — none of these
  have access to the `Depends()` system. You must manually wire dependencies.
- **No singleton scope**: Everything is per-request. App-level singletons require manual management
  (module-level globals or `app.state`).
- **No container**: There is no IoC container. `Depends()` is syntactic sugar for a call graph
  resolver, not a proper DI framework.
- **No graph validation at startup**: Dependency errors are discovered at request time, not at boot.
- **No circular dependency detection**: Will stack overflow at runtime.
- **Tight coupling to framework**: Dependencies are not portable outside FastAPI routes.

### Production Exposure

Massive. FastAPI is one of the most popular Python web frameworks. The `Depends()` pattern is used
in virtually every FastAPI application.

### Lessons

- Simple is powerful: `Depends()` proves that a minimal DI system covers 80% of web app needs.
- The remaining 20% (middleware, background tasks, singletons, testing overrides) requires
  either manual wiring or a real DI container alongside FastAPI.
- Yield-based lifecycle is a genuinely good pattern that other frameworks should adopt.

---

## 2. python-dependency-injector {#python-dependency-injector}

- **URL**: https://github.com/ets-labs/python-dependency-injector
- **Language**: Python (Cython for performance)
- **Stars**: ~4,800
- **PyPI**: `dependency-injector`

### Design

Full-featured IoC container with explicit provider declarations. Uses a `DeclarativeContainer`
class where you define providers (Factory, Singleton, Resource, etc.) that describe how to build
each dependency.

### Key Design Decisions

- **Explicit over implicit**: Every dependency relationship is declared in the container. No
  auto-wiring by default.
- **Provider types**: Factory (transient), Singleton, ThreadLocalSingleton, Resource (lifecycle
  with init/shutdown), Callable, Coroutine, Object, List, Dict, Configuration, Selector.
- **Cython core**: Performance-critical resolution path is compiled C, making it fast.
- **Wiring system**: `@inject` decorator + `Provide[Type]` markers wire container providers into
  function parameters.

### Scoping

- Singleton: One instance per container.
- Factory: New instance per resolution.
- ThreadLocalSingleton: One per thread.
- Resource: Managed lifecycle (init function + shutdown function, or generator with yield).
- No built-in request scope — must be implemented via sub-containers or framework integration.

### Async Support

Supports async factories and async Resource providers. Can `await` container resolution.

### Testing

Provider overriding is first-class: `container.service.override(mock_service)`. No monkey-patching
needed. Can override any provider with any other provider, including for dev/staging environments.

### Limitations

- Substantial boilerplate for container definitions.
- Learning curve for the provider type system.
- Wiring system uses string-based module paths, somewhat fragile.
- Maintenance cadence has slowed (last major release 4.48.x).

### Production Exposure

Widely used in production Python applications. Integrations exist for Django, Flask, Aiohttp,
Sanic, FastAPI.

### Lessons

- Explicit container definitions trade verbosity for clarity.
- The Resource provider with generator yield is an excellent lifecycle pattern.
- Provider overriding for tests is significantly better than `unittest.mock.patch`.

---

## 3. Dishka {#dishka}

- **URL**: https://github.com/reagento/dishka
- **Docs**: https://dishka.readthedocs.io/
- **Language**: Python
- **Stars**: ~1,100
- **PyPI**: `dishka`

### Design

Modern, async-first DI framework. Emphasizes clean API, proper scope management, and zero
decoration of business logic. Providers are organized in `Provider` classes with `@provide`
decorated methods.

### Key Design Decisions

- **No markers on business code**: Your domain classes don't need decorators or base classes.
- **Hierarchical scopes**: APP → REQUEST → ACTION → STEP (customizable). Each scope is a
  nested container that inherits from its parent.
- **Generator-based finalization**: Providers that yield automatically clean up on scope exit:
  ```python
  @provide(scope=Scope.REQUEST)
  def get_connection(self) -> Iterable[Connection]:
      conn = sqlite3.connect(":memory:")
      yield conn
      conn.close()
  ```
- **Component system**: Providers can be grouped into components for isolation.
- **Async-first**: `make_async_container()` for async apps, full `async def` provider support.

### Scoping

Explicit hierarchical scopes. You define the scope hierarchy and assign each provider to a scope.
Objects are cached within their scope and finalized when the scope exits. This is more flexible
than the typical singleton/request/transient trichotomy.

### Framework Integrations

FastAPI, aiohttp, Flask, Starlette, Litestar, and more. FastAPI integration uses `FromDishka[Type]`
type hints and `@inject` decorator, replacing `Depends()` entirely.

### Testing

Override providers by replacing them in test containers. Clean scope isolation means tests don't
leak state.

### Production Exposure

Growing adoption. Actively maintained (v1.7.2 as of Sep 2025, continued releases into 2026).
Used in production by Russian tech companies.

### Lessons

- Hierarchical scopes beyond singleton/request/transient are genuinely useful.
- Generator-based cleanup is the right pattern for Python.
- Keeping business code free of DI markers is worth the effort.
- Performance claims suggest it outperforms python-dependency-injector.

---

## 4. Lagom {#lagom}

- **URL**: https://github.com/meadsteve/lagom
- **Docs**: https://lagom-di.readthedocs.io/
- **Language**: Python
- **Stars**: ~347
- **PyPI**: `lagom`

### Design

Auto-wiring DI container that resolves dependencies from type hints with zero configuration.
Named after a Swedish concept meaning "just enough" — the library aims to provide just enough
DI without over-engineering.

### Key Design Decisions

- **Type-based auto-wiring**: If `__init__` has type hints, lagom builds it automatically. No
  registration needed for most classes.
- **Minimal intrusion**: Almost no code needs to know about lagom. Only the composition root
  touches the container.
- **mypy integration**: Strong type safety, container operations are properly typed.

### Scoping

- Transient (default): New instance every resolution.
- Singleton: Explicit `container[MyClass] = instance`.
- Shared (request-scoped): `@dependency_definition` with `shared=True` makes a class act as a
  singleton for the lifetime of a single function invocation.

### Async Support

Supports async Python.

### Framework Integrations

Flask, Django, Starlette, FastAPI via `@bind_to_container` decorator.

### Limitations

- Auto-wiring can be surprising when type hierarchies are complex.
- "Shared" scoping is tied to function invocation, not HTTP request lifecycle.
- Smaller community than alternatives.

### Production Exposure

Moderate. Used in production by some teams. Stable API (v2.7.x).

### Lessons

- Auto-wiring from type hints is the most Pythonic DI approach.
- "Just enough" DI is a valid philosophy — not every app needs a full IoC container.
- The tension between auto-wiring and explicit registration is real.

---

## 5. that-depends {#that-depends}

- **URL**: https://github.com/modern-python/that-depends
- **Docs**: https://that-depends.readthedocs.io/
- **Language**: Python
- **Stars**: ~244
- **PyPI**: `that-depends`

### Design

Async-first DI framework inspired by python-dependency-injector but simpler. Zero external
dependencies. Full mypy strict mode compliance.

### Key Design Decisions

- **Zero dependencies**: The package has no runtime dependencies.
- **Async-first**: Built for async from the ground up, not bolted on.
- **Type safety**: Full mypy strict mode support.
- **Scope-based lifecycle**: Context management with explicit scopes.

### Scoping

Dependency context management with scopes. Supports request-scoped and application-scoped
dependencies with proper cleanup.

### Framework Integrations

Built-in compatibility with FastAPI, FastStream, and Litestar.

### Testing

Dependency overriding for test isolation without monkey-patching.

### Production Exposure

Moderate. Active development with frequent releases (v3.9.x as of 2026).

### Lessons

- Zero-dependency DI libraries are achievable and valuable.
- Async-first design avoids the sync/async impedance mismatch.
- Strict typing from day one pays off.

---

## 6. injector {#injector}

- **URL**: https://github.com/alecthomas/injector
- **PyPI**: `injector`
- **Language**: Python
- **Stars**: ~1,500

### Design

Guice-inspired DI framework. Uses `Module` classes to configure bindings, `@inject` decorator
for constructor injection, and `Injector` class as the container.

### Key Design Decisions

- **Module-based configuration**: Bindings are defined in Module classes, similar to Java's Guice.
- **Decorator-based injection**: `@inject` marks constructors for injection.
- **Scope support**: SingletonScope, RequestScope (with thread-local storage), custom scopes.

### Scoping

- Singleton: `@singleton` decorator or `scope=singleton` in binding.
- Request: Thread-local scoping for web requests.
- Transient: Default (new instance per injection).

### Limitations

- Thread-local request scoping doesn't work well with async.
- API feels more Java-like than Pythonic.
- Less actively maintained than newer alternatives.

### Lessons

- Direct ports of Java DI patterns to Python feel awkward.
- Thread-local scoping is fundamentally incompatible with async Python.

---

## 7. Other Notable Python DI Libraries {#python-other}

### FastDepends (~492 stars)
- Extracted FastAPI dependency system as standalone library.
- URL: https://github.com/Lancetnik/FastDepends
- Useful for bringing `Depends()` pattern to non-FastAPI code.

### svcs (~400 stars)
- Service locator pattern (explicitly not DI).
- URL: https://github.com/hynek/svcs
- By Hynek Schlawack (attrs, structlog author).
- Simple registry + health checks. Opinionated: "You don't need a DI framework."

### Punq (~417 stars)
- Minimal IoC container. Register/resolve pattern.
- URL: https://github.com/bobthemighty/punq

### Wireup (~367 stars)
- Type-safe, concise DI. Annotation-driven.
- URL: https://github.com/maldoinc/wireup

### Picodi (~31 stars)
- Inspired by FastAPI's Depends(). Yield-based lifecycle.
- URL: https://github.com/yakimka/picodi

### diwire (~216 stars)
- Auto-wiring with zero dependencies, type-safe.
- URL: https://github.com/amoallim15/diwire

### Modern DI (~49 stars)
- Scopes + IoC container. Newer entrant.

The Python DI ecosystem is fragmented with 25+ active libraries. The top contenders are
python-dependency-injector (mature, full-featured), dishka (modern, async-first), and lagom
(auto-wiring, minimal).

---

## 8. Rust: DI Patterns {#rust-di}

### Shaku

- **URL**: https://github.com/AzureMarker/shaku
- **Stars**: ~582
- **Crate**: `shaku`

**Design**: Compile-time DI via derive macros. Components implement `Interface` traits and are
assembled into modules at compile time.

**Key decisions**:
- **Components** (singletons): Same instance on every resolution via `Arc<dyn Trait>`.
- **Providers** (transient): New instance on every resolution via `Box<dyn Trait>`.
- **Module macro**: `module!` macro defines the dependency graph, checked at compile time.
- **Submodules**: Hierarchical module composition for large applications.
- **Compile-time guarantees**: Missing dependencies are compilation errors, not runtime panics.

**Web integrations**: shaku_rocket, shaku_axum, shaku_actix.

**Limitations**:
- Requires `Arc<dyn Trait>` for all injected dependencies (virtual dispatch overhead).
- Maintenance has slowed (last release Jan 2024).
- No built-in request scoping — must be implemented manually.

### Nject

- **Crate**: `nject`
- Compile-time codegen, zero runtime overhead.
- Does not support cross-crate dependencies.
- More limited but truly zero-cost.

### Manual Patterns (Dominant in Rust)

The Rust community largely favors manual DI:
- **Generic trait bounds**: `fn handler<D: Database>(db: &D)` — zero overhead, compile-time checked.
- **Type-keyed state**: Axum's `State<T>` and `Extension<T>` extractors.
- **Builder pattern**: Explicit construction at the composition root.
- **Vocabulary crate**: Shared traits crate that multiple implementations depend on.

Community consensus: "Before doing any dependency wrangling, double check that you actually get
anything out of doing this." Rust's type system and ownership model make manual DI more viable
than in garbage-collected languages.

### Lessons from Rust

- Compile-time DI eliminates an entire class of runtime errors.
- `Arc<dyn Trait>` overhead is negligible except at millions of resolutions per second.
- Manual DI via generics is the most Rust-idiomatic approach.
- The language's type system is strong enough that DI frameworks add less value than in Python/Java.

---

## 9. Go: DI Patterns {#go-di}

### Wire (Google)

- **URL**: https://github.com/google/wire
- **Type**: Compile-time (code generation)

**Design**: You write "injector functions" that declare what types you need. `wire` CLI generates
the actual construction code. Zero runtime overhead.

**Key decisions**:
- Code generation, not reflection.
- Errors caught at compile time.
- Generated code is readable and debuggable.
- Requires re-running `wire` when dependencies change.

**Limitations**:
- Extra build step.
- Generated files add noise.
- Not flexible for dynamic configuration.

### Dig (Uber)

- **URL**: https://github.com/uber-go/dig
- **Type**: Runtime (reflection-based)

**Design**: Register constructors, resolve at runtime. Uses reflection to match function
parameters to registered types.

**Key decisions**:
- Runtime flexibility: swap implementations without regenerating code.
- Reflection overhead (small but measurable).
- Errors detected at runtime, not compile time.
- Supports optional dependencies, named values, groups.

### Fx (Uber)

- **URL**: https://github.com/uber-go/fx
- **Type**: Runtime framework (built on Dig)

**Design**: Full application framework with lifecycle management. `fx.New()` creates an app with
injected dependencies and managed startup/shutdown hooks.

**Key decisions**:
- `fx.Provide()` registers constructors.
- `fx.Invoke()` triggers side effects at startup.
- `fx.Lifecycle` manages `OnStart`/`OnStop` hooks — proper ordered startup/shutdown.
- Built-in logging and observability.
- Batteries-included: more framework than library.

**Production exposure**: Used extensively at Uber in production microservices.

### Manual DI (Go Community Preference)

Most Go projects use manual constructor injection:
```go
func NewServer(db *Database, logger *Logger) *Server {
    return &Server{db: db, logger: logger}
}
```

The Go community generally recommends starting with manual DI and only reaching for Wire/Fx
when the boilerplate becomes unmanageable.

### Production Recommendations

| Scenario | Tool | Why |
|---|---|---|
| Small-medium apps | Manual DI | No dependencies, no magic |
| Large static graphs | Wire | Compile-time safety, zero runtime cost |
| Complex microservices | Fx | Lifecycle management, runtime flexibility |
| Runtime flexibility | Dig | Dynamic component swapping |

### Lessons from Go

- Compile-time code generation (Wire) is the sweet spot: no runtime overhead, no reflection.
- Lifecycle management (Fx's OnStart/OnStop) is essential for production microservices.
- The Go community's skepticism of DI frameworks is healthy — most apps don't need them.

---

## 10. ASP.NET Core DI {#aspnet-core-di}

- **URL**: https://learn.microsoft.com/en-us/aspnet/core/fundamentals/dependency-injection
- **Language**: C#
- **Framework**: ASP.NET Core (built-in)

### Design

First-party, built-in DI container. Constructor injection is the primary mechanism. Services
are registered in `Program.cs` with explicit lifetime declarations.

### The Three Lifetimes

| Lifetime | Method | Behavior |
|---|---|---|
| **Transient** | `AddTransient<T>()` | New instance every resolution |
| **Scoped** | `AddScoped<T>()` | One instance per HTTP request (or Blazor circuit) |
| **Singleton** | `AddSingleton<T>()` | One instance for app lifetime |

### Key Design Decisions

- **Constructor injection preferred**: Framework explicitly recommends constructor injection over
  service locator (`RequestServices`). Constructor injection yields testable classes.
- **Scoped = per-request**: The framework creates a scope per HTTP request automatically. All
  scoped services share the same instance within a request.
- **Keyed services** (ASP.NET Core 8+): `AddKeyedSingleton<T>("key")` + `[FromKeyedServices("key")]`
  for multiple implementations of the same interface.
- **IServiceScopeFactory**: For manually creating scopes (e.g., in background services/IHostedService
  where no request scope exists).
- **Automatic disposal**: Container calls `Dispose()` / `DisposeAsync()` on `IDisposable` services
  it created when the scope ends.

### Middleware and Scoping

- Middleware constructors receive **singleton** services only.
- Scoped/transient services must be injected into `InvokeAsync()` method parameters.
- Factory-based middleware (`IMiddlewareFactory`) activates per-request, allowing constructor
  injection of scoped services.

### Captive Dependency Detection

A **captive dependency** occurs when a scoped service is injected into a singleton — the scoped
service becomes effectively singleton, causing subtle bugs. ASP.NET Core detects this at startup
in Development mode and throws an `InvalidOperationException`. This is called **scope validation**.

### Graph Validation

- In Development mode, the container validates that scoped services aren't resolved from the
  root provider (which would make them singletons).
- Missing registration errors surface at first resolution, not at startup (unlike some Java
  frameworks).

### Performance

Benchmark data from [IocPerformance](https://danielpalme.github.io/IocPerformance/):
- Microsoft.Extensions.DependencyInjection: competitive with specialized containers.
- Singleton resolution: ~20-60ns.
- Transient resolution: ~40-75ns.
- Top performers (Grace, DryIoc, Pure.DI) are marginally faster.
- For web apps, DI resolution cost is negligible compared to I/O.

### Testing

- `WebApplicationFactory<T>` allows replacing services via `ConfigureTestServices()`.
- Clean override pattern: register a mock implementation that replaces the real one.
- No monkey-patching needed — proper interface-based substitution.

### Production Exposure

Universal. Every ASP.NET Core application uses this DI system. It is the most battle-tested
web framework DI in existence.

### Why It's the Gold Standard

1. Built into the framework — zero configuration for basic use.
2. Three clear lifetimes that cover 99% of use cases.
3. Captive dependency detection catches a common, subtle bug class.
4. Automatic disposal prevents resource leaks.
5. Keyed services solve the "multiple implementations" problem cleanly.
6. Middleware scoping rules are well-defined (unlike FastAPI).
7. `IServiceScopeFactory` provides escape hatch for non-request contexts.
8. Excellent documentation and massive production exposure.

### Lessons from ASP.NET Core

- Three lifetimes (transient/scoped/singleton) are sufficient for nearly all applications.
- Captive dependency detection should be standard in all DI frameworks.
- Automatic disposal on scope exit is essential.
- Built-in DI > third-party DI for framework adoption.
- Keyed services are a clean solution to the named/tagged dependency problem.

---

## 11. NestJS DI {#nestjs-di}

- **URL**: https://docs.nestjs.com/fundamentals/injection-scopes
- **Language**: TypeScript
- **Framework**: NestJS

### Design

Angular-inspired DI using TypeScript decorators and `reflect-metadata`. Classes marked with
`@Injectable()` are automatically managed by the IoC container. Dependencies are resolved via
constructor parameter types using `emitDecoratorMetadata`.

### Key Design Decisions

- **Decorator-based**: `@Injectable()` marks classes for DI. `@Inject()` for non-class tokens.
- **Module system**: `@Module({ providers: [...], imports: [...] })` organizes the dependency graph.
- **Reflection metadata**: TypeScript's `emitDecoratorMetadata` compiler option emits
  `design:paramtypes` metadata, which NestJS reads to resolve constructor dependencies.
- **Hierarchical modules**: Modules can import other modules, creating a tree of DI scopes.

### Scoping

| Scope | Behavior |
|---|---|
| **DEFAULT (Singleton)** | Single instance shared across entire app (default) |
| **REQUEST** | New instance per incoming request; garbage collected after response |
| **TRANSIENT** | New instance per consumer (each injection point gets its own) |

Request scope propagates up the dependency chain — if a controller depends on a request-scoped
service, the controller also becomes request-scoped.

### Circular Dependency Handling

NestJS detects circular dependencies at startup and throws a clear error. It provides
`forwardRef(() => Type)` to break circular references when they're intentional.

### Testing

- `Test.createTestingModule()` creates isolated module instances.
- `.overrideProvider(Token).useValue(mock)` for clean test overrides.
- No monkey-patching — pure interface substitution.

### Limitations

- `emitDecoratorMetadata` is required — doesn't work with SWC/esbuild without plugins.
- Request-scoped services have measurable performance overhead (new instance per request for
  entire dependency chain).
- Module boilerplate can be verbose.

### Production Exposure

Very large. NestJS is the most popular Node.js framework for enterprise applications.

### Lessons from NestJS

- Module-based organization scales well for large applications.
- Request scope propagation is a double-edged sword — convenient but can cause unexpected
  performance degradation.
- `forwardRef()` is a pragmatic solution to circular dependencies.
- Decorator-based DI is ergonomic but creates a hard dependency on TypeScript compiler features.

---

## 12. Spring DI {#spring-di}

- **URL**: https://docs.spring.io/spring-framework/reference/core/beans.html
- **Language**: Java/Kotlin
- **Framework**: Spring Boot

### Design

The original enterprise DI framework. Uses `@Component`/`@Service`/`@Repository` annotations
for auto-detection, `@Autowired` for injection, and `@Configuration` + `@Bean` for explicit
factory methods.

### Key Design Decisions

- **Classpath scanning**: Automatically discovers `@Component`-annotated classes.
- **Constructor injection preferred**: Since Spring 4.3, single-constructor classes don't even
  need `@Autowired`.
- **`@Bean` methods**: Explicit factory methods in `@Configuration` classes for complex construction.
- **Profiles**: `@Profile("dev")` / `@Profile("prod")` for environment-specific beans.

### Scoping

| Scope | Behavior |
|---|---|
| **singleton** | Default. One instance per application context. |
| **prototype** | New instance per injection (≈ transient). |
| **request** | One per HTTP request (web apps). |
| **session** | One per HTTP session. |
| **application** | One per ServletContext. |
| **websocket** | One per WebSocket session. |

### Circular Dependency Detection

- Spring Boot 2.6+ **prohibits circular dependencies by default** — the app fails fast at startup.
- Detection mechanism: Tracks beans on a creation stack. If same bean appears twice before being
  fully created, it throws `BeanCurrentlyInCreationException`.
- Constructor cycles fail immediately. Setter/field injection cycles can be broken with `@Lazy`.
- Three-level cache system (singletonObjects, earlySingletonObjects, singletonFactories) used
  internally for early exposure of partially-created beans.

### Graph Validation

The entire bean graph is validated at startup. Missing dependencies, ambiguous types, and circular
references are all caught before the first request is served. This is one of Spring's most
important properties for production reliability.

### Testing

- `@MockBean` / `@SpyBean` for test overrides (being replaced by `@MockitoBean` in newer versions).
- `@TestConfiguration` for test-specific beans.
- `@DirtiesContext` for context isolation between tests.

### Production Exposure

Dominant in enterprise Java. Millions of production applications worldwide.

### Lessons from Spring

- Startup validation of the full dependency graph is extremely valuable.
- Failing fast on circular dependencies (Spring Boot 2.6+) is the right default.
- Six scope levels (singleton through websocket) covers every enterprise use case.
- Auto-wiring by type with `@Qualifier` for disambiguation is a proven pattern.

---

## 13. Cross-Cutting Concerns {#cross-cutting}

### Compile-Time vs Runtime DI Resolution

| Aspect | Compile-Time | Runtime |
|---|---|---|
| **Examples** | Wire (Go), Shaku (Rust), Dagger (Java/Android), Pure.DI (.NET) | Spring, ASP.NET Core, NestJS, Dig/Fx (Go) |
| **Error detection** | At compilation | At startup or first resolution |
| **Performance** | Zero overhead (generated code) | Reflection/dictionary lookup overhead |
| **Flexibility** | Static graph, can't change at runtime | Dynamic, can swap implementations |
| **Boilerplate** | Code generation artifacts | Less boilerplate, more magic |
| **Cold start** | Fast (no graph resolution) | Slower (graph resolution at boot) |

**Performance impact**: Dagger 2 (compile-time) resolves in ~64ms vs Roboguice (runtime) at
~3923ms on Android. For server apps, the difference is negligible — DI resolution cost is
dwarfed by I/O. Compile-time DI matters most for mobile and serverless cold starts.

### Async Generator-Based Lifecycles (Yield Pattern)

The yield pattern for setup/teardown is used by:
- **FastAPI**: `Depends()` with `yield` — setup before yield, cleanup after.
- **python-dependency-injector**: `Resource` provider with generator functions.
- **Dishka**: `@provide` methods that yield — cleanup on scope exit.
- **Picodi**: Yield-based lifecycle inspired by FastAPI.

This is the most Pythonic lifecycle pattern:

```python
async def get_db() -> AsyncIterator[AsyncSession]:
    session = async_sessionmaker()
    yield session        # <-- request handler runs here
    await session.close()
```

Advantages over context managers:
- Flatter code (no `async with` nesting).
- Works naturally with DI frameworks.
- Setup and teardown are co-located.

### DI Graph Validation at Startup

| Framework | Validates at startup? | What's validated? |
|---|---|---|
| Spring | Yes (full graph) | Missing deps, circular deps, scope conflicts |
| ASP.NET Core | Partial (scope validation in dev) | Captive dependencies only |
| NestJS | Yes | Circular dependencies, missing providers |
| Shaku (Rust) | Yes (compile time) | All dependencies resolved |
| Wire (Go) | Yes (compile time) | All dependencies resolved |
| FastAPI | No | Nothing — errors at request time |
| dishka | Partial | Provider graph validated |

### Circular Dependency Detection

| Framework | Detection | Resolution mechanism |
|---|---|---|
| Spring | Startup (fails fast since 2.6) | `@Lazy`, setter injection, `ObjectFactory` |
| ASP.NET Core | None built-in | Manual refactoring |
| NestJS | Startup | `forwardRef(() => Type)` |
| Angular | Startup | `forwardRef()` |
| Shaku (Rust) | Compile time | Impossible to express |
| FastAPI | None (stack overflow) | Manual refactoring |

### Testing with DI: Overrides vs Monkey-Patching

**Why DI overrides are superior to `unittest.mock.patch`**:
1. You patch the *interface*, not the *implementation*. Implementation changes don't break tests.
2. No fragile string-based module paths (`"myapp.services.db.get_connection"`).
3. Type-checked: mock must satisfy the interface.
4. Works the same in async and sync code.
5. No `monkeypatch` fixtures, no `@patch` decorators.

**Override patterns by framework**:
- ASP.NET Core: `ConfigureTestServices(services => services.AddSingleton<IDb>(mockDb))`
- NestJS: `.overrideProvider(DbService).useValue(mockDb)`
- python-dependency-injector: `container.db.override(providers.Object(mock_db))`
- Dishka: Replace provider in test container.
- Spring: `@MockBean` / `@TestConfiguration`

### Performance Cost of DI Resolution Per Request

For most web applications, DI resolution cost is **negligible**:
- .NET containers: 20-75ns per resolution. A typical request resolves ~10-50 services = ~1-4μs.
- Compare to: network I/O (~1-100ms), database queries (~1-50ms), JSON serialization (~10-100μs).
- DI resolution is <0.01% of typical request latency.

**When it matters**:
- Request-scoped services in NestJS: entire dependency chain is re-created per request.
- Mobile/serverless cold starts: full graph resolution at boot.
- Extremely hot paths (millions of resolutions/second): consider compile-time DI.

---

## 14. Lessons & Design Principles {#lessons}

### What the best DI systems share

1. **Clear lifetime semantics**: Transient/Scoped/Singleton covers 99% of use cases. More is
   sometimes useful (Dishka's hierarchical scopes, Spring's session scope) but rarely necessary.

2. **Scope validation**: Catching captive dependencies (scoped service in singleton) at startup
   prevents subtle production bugs. ASP.NET Core and Spring both do this.

3. **Graph validation at startup**: Discovering missing dependencies at boot, not at request time,
   is critical for production reliability. Spring and NestJS do this; FastAPI does not.

4. **Generator/yield-based lifecycle**: The Python yield pattern and C#'s `IAsyncDisposable` both
   provide clean setup/teardown co-located with the factory. This is superior to separate
   init/shutdown callbacks.

5. **Testing via overrides, not patching**: Every good DI framework provides a way to swap
   implementations for testing without monkey-patching. This is one of the primary *reasons*
   to use DI.

6. **DI in middleware**: ASP.NET Core solves this correctly (scoped services in `InvokeAsync`
   parameters). FastAPI fundamentally cannot. This is a critical gap.

7. **Escape hatch for non-request contexts**: `IServiceScopeFactory` (ASP.NET Core) and
   `ObjectProvider` (Spring) let you create scopes in background tasks, CLI tools, etc.
   FastAPI has no equivalent.

### What to avoid

1. **Service Locator pattern**: Resolving from the container directly (`container.get(Type)`)
   instead of constructor injection. Hides dependencies and makes testing harder.

2. **Global mutable container state**: python-inject's global configuration is an anti-pattern.

3. **Thread-local scoping for async**: Doesn't work. Async tasks share threads. Use proper
   async-aware scoping (contextvars in Python, AsyncLocal in .NET).

4. **Over-engineering**: Most small-to-medium Python apps don't need a DI container. Manual
   constructor injection at the composition root is sufficient. Reach for a container when
   the wiring becomes painful.

5. **Decorator pollution**: Requiring `@inject` or `@injectable` on every class couples your
   code to the DI framework. Prefer type-hint-based auto-wiring (lagom, dishka) or explicit
   container definitions (dependency-injector).

### Recommendations for a Python web framework DI system

Based on this survey, the ideal DI system for a Python web framework would combine:

- **ASP.NET Core's** three-lifetime model (transient/scoped/singleton) with scope validation
- **Dishka's** generator-based lifecycle with hierarchical scopes
- **FastAPI's** simplicity of declaring dependencies in function signatures
- **ASP.NET Core's** middleware DI support (scoped services in invoke parameters)
- **Spring's** startup graph validation (detect missing deps and circular refs at boot)
- **Lagom's** auto-wiring from type hints (zero-config for simple cases)
- **python-dependency-injector's** provider override system for testing

The key insight: FastAPI proved that function-signature-based DI is the right UX for Python.
The missing pieces are proper scoping, lifecycle management, middleware support, and startup
validation.

---

## 15. Zenject / Extenject (Unity C# DI) {#zenject}

- **URL**: https://github.com/modesttree/Zenject (original), https://github.com/Mathijs-Bakker/Extenject (maintained fork)
- **Language**: C#
- **Target**: Unity game engine (also usable outside Unity)
- **Stars**: ~7k (combined)
- **Notable users**: Beat Saber, Pokémon Go, Ingress Prime

### Design

Zenject is a lightweight, high-performance DI framework purpose-built for Unity. It provides a
fluent binding API, hierarchical containers mirroring Unity's scene/project structure, and
first-class support for runtime object creation (factories), memory pooling, and decoupled
event communication (signal bus). Unlike enterprise DI systems that focus on request/response
lifecycles, Zenject is optimized for game loops — long-lived processes with high-frequency
object creation/destruction and strict GC pressure constraints.

### Key Design Decisions

- **Fluent binding API**: `Container.Bind<IFoo>().To<Foo>().AsSingle()` — reads like a sentence.
  Construction methods include `FromNew()`, `FromInstance()`, `FromMethod()`,
  `FromComponentInHierarchy()` (Unity-specific). This is the most expressive binding API in
  the survey.
- **Installer pattern (composition roots)**: Bindings are organized into `Installer` classes —
  `MonoInstaller` (scene-attached), `ScriptableObjectInstaller` (editor-configurable assets),
  plain `Installer` (code-only), and `CompositeInstaller` (groups of installers). Installers
  are the composition roots; no binding logic leaks into business code.
- **`[Inject]` attribute**: Constructor injection is preferred, but field/property/method
  injection via `[Inject]` is supported for Unity MonoBehaviours (which cannot use constructor
  injection due to Unity's lifecycle).
- **Automatic lifecycle interfaces**: Classes implementing `IInitializable`, `ITickable`,
  `ILateTickable`, `IFixedTickable`, `IDisposable` are automatically hooked into Unity's
  update loop and cleanup — DI-managed game loop participation.

### Container Hierarchy (Scoping)

| Container | Scope | Analogy to web DI |
|---|---|---|
| **ProjectContext** | Global singleton, survives scene changes | Application/singleton scope |
| **SceneContext** | Per-scene, destroyed on scene unload | Request scope (one "request" = one scene) |
| **GameObjectContext** | Per-object subcontainer | Sub-scope / child container |

Child containers inherit all parent bindings. Resolution walks up the hierarchy.
**Scene Parenting** allows selective inheritance (scene A parents scene B) without forcing
everything through the global ProjectContext — this avoids the "god container" anti-pattern.

This is structurally identical to ASP.NET Core's `IServiceScopeFactory` creating child scopes,
but with a visual, editor-driven configuration layer on top.

### Binding Lifetimes

| Lifetime | Method | Behavior |
|---|---|---|
| **Singleton** | `.AsSingle()` | One instance per container |
| **Transient** | `.AsTransient()` | New instance every resolution |
| **Cached** | `.AsCached()` | Like singleton but within a specific binding context |

### Factory Pattern (Runtime Object Creation)

Zenject's `PlaceholderFactory<T>` solves a problem most web DI systems ignore: creating
fully-injected objects *after* the container is built.

```csharp
public class Enemy {
    public class Factory : PlaceholderFactory<Enemy> {}
}
// In installer:
Container.BindFactory<Enemy, Enemy.Factory>();
// At runtime:
var enemy = _enemyFactory.Create();  // fully injected
```

Factories can accept runtime parameters: `PlaceholderFactory<float, string, Enemy>` passes
`float` and `string` to the constructor alongside injected dependencies. This cleanly separates
"DI-resolved dependencies" from "runtime parameters" — a distinction most web DI systems
muddle (FastAPI's `Depends()` conflates the two).

### Memory Pooling Integration

Pools extend factories with object reuse — critical for games (GC spikes cause frame drops),
but the pattern applies anywhere allocation pressure matters (high-throughput servers).

```csharp
public class Bullet : IPoolable<IMemoryPool>, IDisposable {
    public class Pool : MemoryPool<Bullet> {}
    public void OnSpawned(IMemoryPool pool) => _pool = pool;
    public void OnDespawned() { /* reset state */ }
    public void Dispose() => _pool.Despawn(this);
}
// In installer:
Container.BindMemoryPool<Bullet, Bullet.Pool>()
    .WithInitialSize(50)
    .WithMaxSize(200)
    .ExpandByDoubling();
```

Key insight: **the consumer doesn't know it's using a pool**. The API is identical to a factory
(`pool.Spawn()` / `obj.Dispose()`). This is the Liskov substitution principle applied to
object lifecycle — swap factory for pool without changing call sites.

Configuration: `WithInitialSize()` (pre-warm), `WithMaxSize()` (cap), `ExpandByDoubling()`
vs `ExpandByOneAtATime()`. Reset is mandatory — `OnDespawned()` must clear all state to
prevent cross-lifecycle contamination.

### Signal Bus (Pub/Sub via DI)

DI-managed event bus that decouples publishers from subscribers:

```csharp
// Declare in installer:
Container.DeclareSignal<PlayerDiedSignal>();
Container.BindSignal<PlayerDiedSignal>()
    .ToMethod<GameManager>(x => x.OnPlayerDied).FromResolve();

// Fire:
_signalBus.Fire(new PlayerDiedSignal { PlayerId = id });

// Or subscribe directly:
_signalBus.Subscribe<PlayerDiedSignal>(OnPlayerDied);
```

Design decisions:
- **Sync by default**: `Fire()` invokes all handlers immediately. Async mode defers to a
  configurable tick priority.
- **Missing subscriber policy**: `RequireSubscriber` (throw), `OptionalSubscriber` (silent,
  default), `OptionalSubscriberWithWarning` (log).
- **`Fire()` vs `TryFire()`**: `Fire()` throws if signal undeclared; `TryFire()` is silent.
- **Container-scoped**: Signals are declared per-container and can be copied/moved to
  subcontainers, giving fine-grained event scope control.
- **UniRx integration**: `SignalBus.GetStream<T>()` returns an `IObservable<T>` for reactive
  composition.

### What Makes It Loved

Dzara (and many Unity developers) love Zenject because:

1. **The binding API is genuinely fun to write**. The fluent chain
   `Bind<IWeapon>().To<Sword>().AsSingle().WhenInjectedInto<Knight>()` reads like a
   specification, not boilerplate. Conditional binding (`WhenInjectedInto`, `When(ctx => ...)`)
   is expressive without XML/config files.
2. **It replaces Unity's worst patterns**. Unity encourages singletons (`FindObjectOfType`,
   static instances, `DontDestroyOnLoad`). Zenject replaces all of these with proper DI,
   making code testable and refactorable.
3. **Factories + pools are first-class**. Runtime object creation is a core game dev need.
   Zenject is the only DI framework that treats factories and pools as equal citizens alongside
   bindings — not afterthoughts.
4. **Installers make large projects manageable**. Splitting bindings into installers (one per
   feature/system) scales naturally. `CompositeInstaller` enables reuse across scenes.
5. **The signal bus removes coupling without adding complexity**. Event-driven communication
   is built into the DI system, not a separate library.
6. **Testability is transformative for Unity**. Writing a test installer that swaps
   implementations makes unit testing game logic feasible — something Unity's default
   architecture actively discourages.

### Comparison with ASP.NET Core DI

| Aspect | Zenject | ASP.NET Core DI |
|---|---|---|
| **Binding API** | Fluent, expressive, conditional | Minimal (`AddScoped<I, T>()`) |
| **Lifetimes** | Single/Transient/Cached | Singleton/Scoped/Transient |
| **Scope hierarchy** | Project → Scene → GameObject | Root → Request scope |
| **Factories** | First-class `PlaceholderFactory<T>` | Manual `IServiceScopeFactory` or `ActivatorUtilities` |
| **Pooling** | Built-in `MemoryPool<T>` | Not built-in (use `ObjectPool<T>` from Extensions) |
| **Event bus** | Built-in signal bus | Not built-in (use MediatR or similar) |
| **Captive dependency detection** | No | Yes (Development mode) |
| **Graph validation at startup** | Partial (circular dep detection, optional) | Partial (scope validation in dev) |
| **Conditional binding** | Yes (`WhenInjectedInto`, `When(predicate)`) | No |

ASP.NET Core DI is deliberately minimal — it does three lifetimes and does them perfectly.
Zenject is maximalist — it provides factories, pools, signals, conditional binding, and
lifecycle interfaces because game development demands runtime dynamism that web apps don't.

### Trade-Offs

1. **Complexity ceiling**: Zenject's feature surface is enormous. New developers face a steep
   learning curve. The documentation is extensive but the sheer number of options (binding
   methods, construction methods, scope modifiers, conditional bindings) can overwhelm.
2. **Performance at scale**: VContainer (a competitor) demonstrated that Zenject's approach of
   reflecting over all GameObjects at scene start is expensive. VContainer isolates reflection
   to the container build stage, achieving better startup performance.
3. **Maintenance uncertainty**: The original `modesttree/Zenject` repo is largely unmaintained.
   Extenject (`Mathijs-Bakker/Extenject`) is the community fork. Unity briefly adopted it
   internally but the organizational ownership has been fragmented.
4. **No captive dependency detection**: Unlike ASP.NET Core, Zenject does not detect when a
   transient/scene-scoped service is captured by a singleton. This is a real source of bugs.
5. **Signal bus vs proper event sourcing**: The signal bus is convenient but untyped at the
   subscription level (runtime method binding). It can become a debugging nightmare in large
   projects — "who's listening to this signal?" requires grep, not the type system.
6. **Over-injection risk**: The `[Inject]` attribute on fields/properties enables injection
   without constructor parameters, which can hide dependencies and create implicit coupling —
   the very problem DI is supposed to solve.

### Patterns Transferable to snek's DI

1. **Fluent binding API**: snek could offer `container.bind(IFoo).to(Foo).as_singleton()` —
   more expressive than `add_scoped(IFoo, Foo)` while remaining Pythonic. The chain is
   discoverable via IDE autocomplete.

2. **Installer/module pattern**: Grouping bindings into `Installer` classes that can be
   composed, reused, and swapped for testing. This maps to Python modules/classes that
   configure a container:
   ```python
   class DatabaseInstaller(Installer):
       def install(self, container):
           container.bind(Database).to(PostgresDB).as_scoped()
   ```

3. **Factory as first-class provider**: A `Factory[T]` type that, when injected, lets you
   create fully-injected instances at runtime with additional parameters. This solves the
   "I need a new X per loop iteration with runtime args" problem that `Depends()` can't.

4. **Pool provider**: `Pool[T]` as a factory variant that reuses instances — useful for
   connection pools, worker objects, reusable computation contexts. The key insight is that
   pools and factories share the same consumer-facing API.

5. **Signal bus as optional DI-integrated pub/sub**: Declaring events in the container and
   binding handlers during configuration. This gives compile-time-like visibility into
   event wiring (vs scattered `addEventListener` calls).

6. **Conditional binding**: `when_injected_into(Handler)` or `when(predicate)` for
   context-sensitive resolution. Useful for per-route or per-handler configuration without
   separate containers.

7. **Hierarchical containers with selective inheritance**: Scene parenting maps to
   "middleware group scoping" — a group of routes shares a sub-container that inherits from
   app scope but adds route-group-specific bindings.

### Lessons

- A DI framework can be *beloved* rather than merely tolerated. The difference is API
  ergonomics — Zenject's fluent bindings are a joy; Spring's XML was not.
- Factories and pools belong in the DI system, not as external add-ons. When the container
  knows about object lifecycle beyond create/inject, it can optimize and validate.
- Signal bus is powerful but needs guardrails. Typed signals with declaration requirements
  (`DeclareSignal`) prevent the "invisible event spaghetti" problem.
- Hierarchical containers with selective inheritance are strictly better than a flat
  global-vs-request two-tier model. Web frameworks should learn from this.
- The `[Inject]` attribute anti-pattern (field injection hiding dependencies) is a cautionary
  tale: always prefer explicit constructor/parameter injection.

---

## Source URLs

### Python
- FastAPI Depends: https://fastapi.tiangolo.com/tutorial/dependencies/
- FastAPI middleware issue: https://github.com/fastapi/fastapi/issues/402
- python-dependency-injector: https://github.com/ets-labs/python-dependency-injector
- Dishka: https://github.com/reagento/dishka
- Lagom: https://github.com/meadsteve/lagom
- that-depends: https://github.com/modern-python/that-depends
- injector: https://pypi.org/project/injector/
- FastDepends: https://github.com/Lancetnik/FastDepends
- svcs: https://github.com/hynek/svcs
- Awesome DI in Python: https://github.com/sfermigier/awesome-dependency-injection-in-python
- DI comparison blog: https://wasinski.dev/comparison-of-dependency-injection-libraries-in-python/

### Rust
- Shaku: https://github.com/AzureMarker/shaku
- Rust DI comparison forum: https://users.rust-lang.org/t/comparing-dependency-injection-libraries-shaku-nject/102619

### Go
- Wire: https://github.com/google/wire
- Dig: https://github.com/uber-go/dig
- Fx: https://github.com/uber-go/fx
- Go DI comparison: https://dev.to/rezende79/dependency-injection-in-go-comparing-wire-dig-fx-more-3nkj

### C# / .NET
- ASP.NET Core DI: https://learn.microsoft.com/en-us/aspnet/core/fundamentals/dependency-injection
- IocPerformance benchmarks: https://danielpalme.github.io/IocPerformance/
- StrongInject (compile-time): https://github.com/YairHalberstadt/stronginject

### TypeScript
- NestJS DI: https://docs.nestjs.com/fundamentals/injection-scopes
- NestJS circular deps: https://www.digitalocean.com/community/tutorials/understanding-circular-dependency-in-nestjs

### Java
- Spring circular deps: https://www.baeldung.com/circular-dependencies-in-spring
- Spring Boot circular dep detection: https://medium.com/@AlexanderObregon/the-mechanics-behind-how-spring-boot-handles-dependency-cycles-in-bean-creation-e57c08a5692d

### C# / Unity (Zenject)
- Zenject (original): https://github.com/modesttree/Zenject
- Extenject (maintained fork): https://github.com/Mathijs-Bakker/Extenject
- Zenject Signals docs: https://github.com/modesttree/Zenject/blob/master/Documentation/Signals.md
- Zenject Memory Pools docs: https://github.com/modesttree/Zenject/blob/master/Documentation/MemoryPools.md
- Zenject SubContainers docs: https://github.com/modesttree/Zenject/blob/master/Documentation/SubContainers.md
- VContainer comparison: https://vcontainer.hadashikick.jp/comparing/comparing-to-zenject
- DeepWiki overview: https://deepwiki.com/modesttree/Zenject

### General
- Compile-time vs runtime DI: https://news.ycombinator.com/item?id=19787372
- DI testing patterns: https://betterprogramming.pub/testing-in-python-dependency-injection-vs-mocking-5e542783cb20


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-ae8446d8c5695b1e8.jsonl`
