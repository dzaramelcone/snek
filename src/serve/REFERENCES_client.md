# HTTP Client Implementation Reference

State-of-the-art survey across high-performance systems languages.
Compiled 2026-03-21.

---

## Table of Contents

1. [Rust: reqwest](#rust-reqwest)
2. [Rust: hyper client](#rust-hyper-client)
3. [Rust: ureq](#rust-ureq)
4. [C: libcurl](#c-libcurl)
5. [Go: fasthttp client](#go-fasthttp-client)
6. [Go: net/http client](#go-nethttp-client)
7. [Zig: std.http.Client](#zig-stdhttpclient)
8. [Cross-Cutting Concerns](#cross-cutting-concerns)
   - [Connection Pooling](#connection-pooling)
   - [Keep-Alive Management](#keep-alive-management)
   - [HTTP/2 Multiplexing](#http2-multiplexing)
   - [Retry Strategies](#retry-strategies)
   - [Timeout Layering](#timeout-layering)
   - [DNS Resolution Caching](#dns-resolution-caching)
   - [Cookie Jar Management](#cookie-jar-management)
   - [Redirect Following](#redirect-following)
   - [Proxy Support](#proxy-support)
   - [io_uring Integration](#io_uring-integration)
9. [Comparative Analysis](#comparative-analysis)
10. [Key Lessons](#key-lessons)

---

## Rust: reqwest

- **URL**: https://github.com/seanmonstar/reqwest
- **Docs**: https://docs.rs/reqwest/latest/reqwest/
- **Language**: Rust
- **Version**: Latest stable (actively maintained, 16k+ GitHub stars)
- **License**: MIT/Apache-2.0

### Design Decisions

- **Built on hyper + tokio**. reqwest is a high-level facade over hyper's low-level HTTP engine and tokio's async runtime. This gives it production-grade HTTP parsing with an ergonomic API.
- **Async-first, blocking opt-in**. The primary API is async. A `blocking` feature flag enables a synchronous API that internally spawns a tokio runtime.
- **Client = connection pool**. Creating a `Client` implicitly creates a connection pool. The docs explicitly state: reuse the same `Client` across requests. `Client` uses `Arc` internally, so cloning is cheap and no `Rc`/`Arc` wrapper is needed.

### Configuration Surface

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `pool_max_idle_per_host` | `usize::MAX` (unlimited) | Max idle connections per host |
| `pool_idle_timeout` | 90 seconds | How long idle connections survive |
| `timeout` | None (no timeout) | Total request timeout |
| `connect_timeout` | None | TCP connection establishment timeout |
| `read_timeout` | None | Response body read timeout |
| `connection_verbose` | false | Verbose connection logging |

### TLS

- Default: **rustls** (pure Rust, no OpenSSL dependency)
- Optional: **native-tls** (platform TLS: SChannel on Windows, Security.framework on macOS, OpenSSL on Linux)
- HTTP/2 via ALPN negotiation
- Experimental HTTP/3 (QUIC) support behind unstable feature flag

### Features

- Automatic redirect following (configurable policy, max redirects)
- Cookie store (opt-in `cookie_store` feature)
- JSON serialization/deserialization via serde
- Multipart form uploads
- Proxy support (HTTP, HTTPS, SOCKS5)
- Gzip, brotli, deflate, zstd decompression
- WebSocket upgrade support

### Trade-offs

- **Heavy dependency tree**: tokio + hyper + rustls/native-tls + tower. Compile times are significant.
- **Binary size**: Larger than minimal alternatives.
- **Flexibility vs. simplicity**: You get a lot out of the box but limited control over low-level connection behavior.

### Production Exposure

De facto standard Rust HTTP client. Used across the Rust ecosystem in production by thousands of crates and services. Maintained by seanmonstar (also hyper maintainer).

---

## Rust: hyper client

- **URL**: https://github.com/hyperium/hyper
- **Docs**: https://docs.rs/hyper/latest/hyper/
- **Language**: Rust
- **Version**: 1.8.1 (Nov 2025)
- **License**: MIT
- **Stars**: 16k+, 2900+ commits

### Design Decisions

- **Deliberately low-level**. hyper provides the building blocks; it does not provide connection pooling, DNS resolution, or TLS out of the box. The official recommendation: use reqwest for a convenient client, use hyper when you need control.
- **Correctness and performance as co-equal goals**. Extensively tested and fuzzed. Leading HTTP/1 and HTTP/2 performance in Rust benchmarks.
- **Sans-middleware architecture**. hyper itself has no middleware. Tower middleware can be layered on via `hyper-util` and `tower-http`.

### Architecture

```
hyper::client::conn::http1  -- low-level HTTP/1 connection
hyper::client::conn::http2  -- low-level HTTP/2 connection
hyper-util::client::legacy  -- higher-level client with connection pool
tower-http                  -- middleware (timeouts, retries, compression, auth)
```

- `hyper::client::conn` gives you a single connection. You manage pooling, DNS, TLS yourself.
- `hyper-util` provides `HttpConnector` (DNS resolution in a thread pool + TCP connect) and a legacy `Client` type with connection pooling.
- Pool default: `usize::MAX` idle connections per host.

### Key Trade-offs

- **Maximum control**: You choose your TLS library, your DNS resolver, your pool strategy.
- **Maximum effort**: You wire everything together yourself.
- **Performance**: Leading benchmarks for raw HTTP throughput in Rust. Used as the engine behind reqwest, axum, warp.

### Production Exposure

Foundation of the Rust HTTP ecosystem. Used by Cloudflare, AWS, Discord, and many others in production.

---

## Rust: ureq

- **URL**: https://github.com/algesten/ureq
- **Docs**: https://docs.rs/ureq/latest/ureq/
- **Language**: Rust
- **Version**: 3.x (actively maintained)
- **License**: MIT/Apache-2.0

### Design Decisions

- **Blocking I/O only**. No async runtime dependency. No tokio. This is the defining trade-off: simplicity and minimal dependencies at the cost of async support.
- **Sans-IO architecture** (ureq 3.x). Protocol logic lives in `ureq-proto` crate, separated from I/O operations. The `Transport` trait allows plugging in custom I/O backends.
- **Zero unsafe code**. Pure Rust, `#![forbid(unsafe_code)]`.
- **Agent = connection pool + cookie store**. An `Agent` holds pooled connections and cookies. Cloning is cheap (internal `Arc`).

### Features

- HTTP/1.1 only (no HTTP/2)
- TLS via rustls (default) or native-tls
- Connection pooling via Agent
- Gzip, brotli decompression (optional features)
- JSON via serde (optional)
- Cookie support (optional)
- SOCKS4/SOCKS5 proxy support (optional)
- HTTP CONNECT proxy support
- Charset decoding
- Multipart forms

### Trade-offs

- **Minimal compile time and binary size**. Default feature set pulls far fewer dependencies than reqwest.
- **No async**. Not suitable for high-concurrency workloads where you want thousands of concurrent outbound requests on few threads.
- **No HTTP/2**. Single-stream-per-connection only.
- **Ideal for**: CLI tools, build scripts, small services, testing, anywhere blocking I/O is acceptable.

### Production Exposure

Widely used in the Rust ecosystem for CLI tools and simpler HTTP needs. 1,294+ commits, actively maintained.

---

## C: libcurl

- **URL**: https://github.com/curl/curl
- **Docs**: https://everything.curl.dev/
- **Language**: C
- **Version**: 8.x (continuously released since 1998)
- **License**: MIT-like (curl license)

### Design Decisions

- **Two interfaces**: Easy (simple, blocking, one transfer at a time) and Multi (event-driven, concurrent, scalable).
- **Battle-tested over 26+ years**. The reference implementation for HTTP clients. Used by virtually every platform and language.
- **Protocol breadth**: HTTP/1.0, HTTP/1.1, HTTP/2, HTTP/3 (QUIC), plus FTP, SMTP, IMAP, etc.

### Connection Pool Architecture

| Setting | Default | Purpose |
|---------|---------|---------|
| `CURLOPT_MAXCONNECTS` | 5 | Max connections in pool |
| `CURLOPT_MAXAGE_CONN` | 118 seconds | Max idle age before eviction |
| `CURLOPT_MAXLIFETIME_CONN` | unlimited | Max total connection lifetime |
| `CURLOPT_FORBID_REUSE` | false | Disable connection reuse |
| `CURLOPT_TCP_KEEPALIVE` | false | Enable TCP keep-alive probes |
| `CURLOPT_TCP_KEEPIDLE` | 60 seconds | Idle time before first probe |

#### Pool Scoping

- **Easy API**: Pool is per-handle. Reuse the same easy handle to reuse connections.
- **Multi API**: Pool is per-multi-handle. All easy handles in the same multi handle share the pool. This is the recommended approach for concurrent use.
- **Share interface** (since 7.57.0): Allows unrelated transfers to share a common connection pool.

#### Connection Matching

Connection reuse matching is **hostname-based** (done before DNS resolution), then verified by port, protocol, and other properties. This means DNS changes are invisible to reused connections -- a known trade-off for performance.

### DNS Cache

| Setting | Default | Purpose |
|---------|---------|---------|
| `CURLOPT_DNS_CACHE_TIMEOUT` | 60 seconds | DNS entry TTL in cache |
| DNS cache max entries | 30,000 | Hard limit, entries pruned beyond this |

Since curl 8.16.0, failed DNS lookups are cached for half the timeout period.

**Critical insight**: Connection reuse skips DNS entirely. A reused connection keeps using the original IP even if DNS has changed. This is deliberate for performance but means DNS failover requires connection eviction.

### Multi Interface

Two flavors:
1. **Select-based**: `curl_multi_perform()` + `curl_multi_poll()` (simpler)
2. **Event-driven**: `curl_multi_socket_action()` + callbacks (high-performance, integrates with libevent/libev/epoll/kqueue)

The event-driven approach scales to thousands of parallel connections. HTTP/2 multiplexing is enabled by default since curl 7.62.0 -- 100+ parallel requests over a single TCP connection.

**Known blocking operations** even in multi mode: DNS resolution (without c-ares), `file://` transfers, TELNET.

### Trade-offs

- **C memory safety**: Manual memory management, though curl's track record is excellent.
- **Global state**: Some curl operations require global initialization (`curl_global_init`).
- **Feature completeness vs. complexity**: libcurl handles every edge case but has hundreds of options.

### Production Exposure

The most deployed HTTP client on Earth. Ships in virtually every OS, language runtime, and container image.

---

## Go: fasthttp client

- **URL**: https://github.com/valyala/fasthttp
- **Language**: Go
- **Version**: Actively maintained
- **License**: MIT

### Design Decisions

- **Zero allocations in hot paths**. The core design principle. Uses aggressive object pooling via `sync.Pool` for request/response objects and byte buffers.
- **HTTP/1.1 only**. Deliberately does not implement HTTP/2. The trade-off is raw HTTP/1.1 throughput over protocol modernity.
- **Not a drop-in net/http replacement**. Different API designed around buffer reuse rather than Go idioms.

### Performance Claims vs. Reality

| Scenario | fasthttp | net/http | Ratio |
|----------|----------|---------|-------|
| Synthetic in-memory (GOMAXPROCS=1) | 4,827 ns/op, 0 allocs | 26,878 ns/op | ~5.6x |
| Real-world same server | - | - | ~1.13x |
| 70% CPU utilization | - | - | 1.3-1.7x |

**Key insight**: The claimed 10x improvement is synthetic. Real-world gains are 30-70% under load, down to 13% when connecting to the same server. The gains come primarily from reduced GC pressure, not raw I/O speed.

### Client Features

- Connection pooling with aggressive reuse
- Load-balanced client (`lbclient`) for distributing across backends
- Custom TCP dialer
- TLS support
- Request/response streaming

### Trade-offs

- **No HTTP/2**: Major limitation for modern workloads.
- **Non-standard API**: Cannot use net/http middleware ecosystem.
- **Complexity**: Requires understanding buffer ownership semantics.
- **Best for**: High-throughput HTTP/1.1 proxies, API gateways, load balancers where you control both ends.

### Production Exposure

Used by high-performance Go services. The `fiber` web framework is built on fasthttp.

---

## Go: net/http client

- **URL**: https://pkg.go.dev/net/http (Go stdlib)
- **Language**: Go
- **Version**: Ships with Go (continuously updated)
- **License**: BSD-3-Clause

### Design Decisions

- **Batteries included**. Connection pooling, keep-alive, HTTP/2, TLS, cookies, redirects, proxies -- all built into the standard library.
- **Late binding pattern**. The most interesting architectural decision. When acquiring a connection, two goroutines race in parallel:
  1. One tries to dial a new TCP connection
  2. One tries to retrieve an idle connection from the pool
  The fastest wins (via Go `select`). This minimizes latency by avoiding sequential pool-check-then-dial.

### Transport Configuration

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `MaxIdleConns` | 100 | Total idle connections across all hosts |
| `MaxIdleConnsPerHost` | 2 | Idle connections per host |
| `MaxConnsPerHost` | 0 (unlimited) | Total connections per host |
| `IdleConnTimeout` | 90 seconds | Idle connection eviction time |
| `TLSHandshakeTimeout` | 10 seconds | TLS handshake deadline |
| `DisableKeepAlives` | false | Force connection-per-request |
| `ResponseHeaderTimeout` | 0 (none) | Time to wait for response headers |
| `ExpectContinueTimeout` | 1 second | Wait for 100-continue |

**Critical defaults pitfall**: `MaxIdleConnsPerHost` defaults to 2, which is far too low for most production workloads. Services calling the same backend repeatedly will thrash connections unless this is raised.

### HTTP/2 Support

- Automatic HTTP/2 when using HTTPS with default Transport
- `StrictMaxConcurrentStreams` (opt-in): Limits concurrent streams per connection, mimicking HTTP/1.1 connection-per-request behavior
- HTTP/2 is transparent -- same API, no code changes

### Connection Lifecycle

1. Request arrives at `Transport.RoundTrip()`
2. Late binding race: pool lookup vs. new dial
3. Winner provides the connection
4. Request sent, response read
5. Connection returned to pool (if keep-alive) or closed
6. Idle connections evicted after `IdleConnTimeout`
7. When pool hits `MaxConnsPerHost`, requests queue FIFO until a connection frees up

### Trade-offs

- **Good defaults for moderate workloads**. Terrible defaults for high-throughput single-backend scenarios (MaxIdleConnsPerHost=2).
- **Allocations**: More GC pressure than fasthttp, but acceptable for most workloads.
- **HTTP/2 transparent**: Great for general use, but limits fine-grained HTTP/2 stream control.

### Production Exposure

The standard Go HTTP client. Used by every Go service in production. Kubernetes, Docker, Terraform, and the entire Go ecosystem.

---

## Zig: std.http.Client

- **URL**: https://github.com/ziglang/zig/blob/master/lib/std/http/Client.zig
- **Language**: Zig
- **Version**: Ships with Zig std (0.13+)
- **License**: MIT

### Design Decisions

- **Part of the standard library**. No external dependencies needed for basic HTTP.
- **Thread-safe connection opening, non-thread-safe individual requests**. Connections are opened safely across threads, but a single request must not be shared.
- **LRU connection pool**. Uses doubly-linked lists for both active (`used`) and idle (`free`) connections.

### Connection Pool Architecture

```
ConnectionPool:
  used: DoublyLinkedList  -- currently active connections
  free: DoublyLinkedList  -- available for reuse
  free_size: u32          -- capacity limit (default 32)
  mutex: Mutex            -- protects pool state
```

Matching is by host + port + protocol. When capacity is exceeded, the oldest idle connection is destroyed (LRU eviction).

### HTTP Version Support

- HTTP/1.0 and HTTP/1.1
- HTTP/1.1 is the default request version
- HTTP/1.0: default connection close
- HTTP/1.1: default connection persist (keep-alive)
- **No HTTP/2 support**

### Redirect Handling

Three-state system:
- `not_allowed`: immediate error on redirect
- `unhandled`: passed to caller for manual handling
- Numeric (0-65534): remaining redirect count, auto-decremented

Automatic method changes: POST becomes GET for 301, 302, 303 responses. Cross-domain redirects strip privileged headers but preserve extra headers.

### Proxy Support

- HTTP proxy (request URI rewriting)
- HTTPS CONNECT tunneling (with fallback to standard proxying)
- Proxy authentication via `proxy-authorization` header
- Environment variable configuration: `http_proxy`, `HTTP_PROXY`, `https_proxy`, `HTTPS_PROXY`, `all_proxy`, `ALL_PROXY`

### TLS

- Compile-time optional via `std.options.http_disable_tls`
- Uses `std.crypto.tls.Client` with dedicated buffers
- Certificate bundle (`ca_bundle`) with mutex-protected lazy loading
- Rescans certificates on first HTTPS request

### Compression

Supports gzip, deflate, zstd, and identity encodings. Transparent decompression via `readerDecompressing()`.

### Trade-offs

- **No HTTP/2**: Limits use for modern services.
- **No async**: Uses blocking I/O (though Zig's async story is evolving).
- **Minimal feature set**: No cookies, no retry logic, no JSON -- you build those yourself.
- **Young implementation**: Active development, API not fully stable.

### Production Exposure

Limited. Zig ecosystem is still maturing. Used primarily by Zig projects and the Zig package manager itself.

---

## Cross-Cutting Concerns

### Connection Pooling

#### Strategies Compared

| Implementation | Pool Scope | Default Size | Eviction | Matching |
|---------------|-----------|-------------|----------|----------|
| reqwest | Per-Client | unlimited/host | 90s idle | Hostname+port+scheme |
| hyper | Per-Client (via hyper-util) | unlimited/host | configurable | Hostname+port+scheme |
| ureq | Per-Agent | configurable | configurable | Hostname+port+scheme |
| libcurl (easy) | Per-handle | 5 | 118s idle age | Hostname (pre-DNS) |
| libcurl (multi) | Per-multi-handle | 5 | 118s idle age | Hostname (pre-DNS) |
| fasthttp | Per-Client | configurable | aggressive reuse | Host+port |
| net/http | Per-Transport | 2/host, 100 total | 90s idle | Host+port+scheme |
| Zig std | Per-Client | 32 | LRU eviction | Host+port+protocol |

#### Design Lessons

1. **Pool-per-client is the dominant pattern**. Every implementation ties the pool to a client/agent/handle object. This makes the lifecycle clear and avoids global state.

2. **"Reuse the client" is universal advice**. reqwest, ureq, libcurl, Go net/http -- all explicitly document that creating a new client per request destroys pooling benefits.

3. **libcurl's hostname-based matching (pre-DNS) is unique**. Other implementations match after resolution. libcurl's approach is faster (skips DNS for reused connections) but means DNS changes are invisible to live connections.

4. **Go's late binding (pool race vs. dial) is the most sophisticated acquisition strategy**. It avoids head-of-line blocking on pool lookup while still preferring reuse.

5. **Stale connection detection is fundamentally racy**. The server can close a connection at any moment. There is no reliable way to detect this without attempting I/O. Apache HttpClient's stale check costs 15-30ms and still isn't 100% reliable. The pragmatic approach: retry on connection reset.

---

### Keep-Alive Management

#### TCP Keep-Alive vs. HTTP Keep-Alive

These are different mechanisms:

- **HTTP Keep-Alive**: Application-layer. Connection: keep-alive header (HTTP/1.1 default). Means "don't close after this response."
- **TCP Keep-Alive**: Transport-layer. OS-level probes to detect dead connections. Configurable via `SO_KEEPALIVE`, `TCP_KEEPIDLE`, `TCP_KEEPINTVL`, `TCP_KEEPCNT`.

#### Implementation Patterns

- **libcurl**: `CURLOPT_TCP_KEEPALIVE` enables OS-level probes. `CURLOPT_TCP_KEEPIDLE` = 60s default.
- **Go net/http**: TCP keep-alive enabled by default on dialed connections. Probe interval is 15 seconds.
- **Zig std**: HTTP/1.0 defaults to close, HTTP/1.1 defaults to persist. No TCP keep-alive configuration exposed.
- **reqwest/hyper**: Inherits tokio's TCP keep-alive defaults.

#### Key Insight

The keep-alive timeout race condition is a universal problem: the client sends a request at the exact moment the server decides to close the idle connection. The only robust solution is to retry on connection reset errors for idempotent requests.

---

### HTTP/2 Multiplexing

#### Client-Side Considerations

- **Single connection, multiple streams**: HTTP/2 multiplexes requests over one TCP connection. This eliminates connection pool sizing as a concern but introduces stream management complexity.
- **Flow control**: Per-stream and per-connection. Initial window: 65,535 bytes. Sender must respect receiver's window; receiver sends WINDOW_UPDATE frames.
- **Stream limits**: Server advertises MAX_CONCURRENT_STREAMS. Client must respect it and queue excess requests.
- **Head-of-line blocking moves to TCP**: While HTTP/2 eliminates HTTP-level HOL blocking, TCP-level HOL blocking remains (a packet loss blocks all streams). This is what HTTP/3/QUIC solves.

#### Implementation Status

| Client | HTTP/2 | Multiplexing |
|--------|--------|-------------|
| reqwest | Yes (ALPN) | Yes |
| hyper | Yes | Yes |
| ureq | No | No |
| libcurl | Yes (default since 7.62.0) | Yes, 100+ streams/connection |
| fasthttp | No | No |
| net/http | Yes (automatic with HTTPS) | Yes |
| Zig std | No | No |

---

### Retry Strategies

#### Exponential Backoff with Jitter

The industry-standard pattern (per AWS Builders' Library):

```
sleep = min(cap, base * 2^attempt) + random_between(0, jitter)
```

- **Base delay**: Typically 100ms-1s
- **Cap**: Maximum delay (e.g., 30s-60s)
- **Jitter**: Random component to prevent thundering herd. Three variants:
  - Full jitter: `random(0, base * 2^attempt)` -- most effective
  - Equal jitter: `base * 2^attempt / 2 + random(0, base * 2^attempt / 2)`
  - Decorrelated jitter: `min(cap, random(base, sleep_prev * 3))`

#### Retryable vs. Non-Retryable

- **Retry**: 5xx, 429 (Too Many Requests), connection reset, timeout, DNS failure
- **Do not retry**: 4xx (except 429, 408), malformed request, authentication failure
- **Idempotency requirement**: Only retry non-idempotent requests (POST) if the server guarantees idempotency (e.g., via idempotency keys)

#### Circuit Breaker Pattern

Three states:
1. **Closed**: Normal operation, requests pass through. Track failure rate.
2. **Open**: Failure threshold exceeded. All requests fail fast without calling the backend. Timer starts.
3. **Half-Open**: Timer expired. Allow a limited number of probe requests. If they succeed, return to Closed. If they fail, return to Open.

**Key parameters**: failure threshold (e.g., 50% of last 100 requests), open duration (e.g., 30s), probe count (e.g., 3).

#### Production Lessons (Amazon)

- Retries are "selfish" -- they increase load on an already-failing system.
- Set an overall operation timeout that includes all retry attempts.
- Monitor retry rates as a health signal.
- Pre-establish connections before accepting traffic to avoid timeout storms during deployment.

---

### Timeout Layering

A properly layered HTTP client has distinct timeouts for each phase:

```
|<---------------------- Total Timeout ---------------------->|
|                                                              |
|<-- DNS -->|<-- Connect -->|<-- TLS -->|<-- First Byte -->|<-- Transfer -->|
|           |               | Handshake |   (TTFB)         |               |
```

#### Phase Breakdown

| Phase | What it covers | Typical range |
|-------|---------------|---------------|
| DNS resolution | Name lookup | 1-50ms (cached), 50-500ms (cold) |
| TCP connect | SYN/SYN-ACK/ACK | 1-100ms (same region), 50-300ms (cross-region) |
| TLS handshake | Certificate exchange, key derivation | 1 RTT (TLS 1.3), 2 RTT (TLS 1.2) |
| First byte (TTFB) | Server processing time | Application-dependent |
| Transfer | Body download | Size and bandwidth dependent |
| Total | End-to-end | Sum of all phases + safety margin |

#### Implementation Coverage

| Client | DNS | Connect | TLS | First Byte | Transfer | Total |
|--------|-----|---------|-----|------------|----------|-------|
| reqwest | No | `connect_timeout` | (included in connect) | No | `read_timeout` | `timeout` |
| hyper | No (bring your own) | Manual | Manual | Manual | Manual | Manual |
| libcurl | `CURLOPT_DNS_SERVER_TIMEOUT` | `CURLOPT_CONNECTTIMEOUT` | Included in connect | `CURLOPT_SERVER_RESPONSE_TIMEOUT` | `CURLOPT_TIMEOUT` | `CURLOPT_TIMEOUT` |
| Go net/http | No | `DialContext` deadline | `TLSHandshakeTimeout` | `ResponseHeaderTimeout` | No explicit | Context deadline |
| Zig std | No | `ConnectTcpOptions.timeout` | No | No | No | No |

#### Design Recommendations

1. **Always set a total timeout**. Without it, a hung server can block a client goroutine/task forever.
2. **Connect timeout should be shorter than total timeout**. Typically 5-10 seconds for cross-region, 1-3 seconds for same-region.
3. **TLS handshake timeout is separate from connect timeout in some implementations** (Go), included in others (reqwest, libcurl). The separate approach is more debuggable.
4. **First-byte timeout catches slow servers** without penalizing large responses. This is the most underused timeout.

---

### DNS Resolution Caching

#### Strategies

1. **OS-level caching**: Rely on the system resolver (nscd, systemd-resolved, macOS mDNSResponder). Most HTTP clients do this implicitly.
2. **Library-level caching**: libcurl caches DNS for 60 seconds by default. Chromium caches up to 1000 entries for exactly 60 seconds.
3. **No caching**: Some clients resolve fresh every time (unless connection is reused, which skips DNS entirely).

#### The DNS-Connection Reuse Tension

This is a fundamental design tension:

- **Connection reuse skips DNS**. A reused connection uses the original IP forever, regardless of DNS changes.
- **DNS TTL may expire** while a connection is alive. The connection continues working on the old IP.
- **Failover depends on new connections**. If all connections are reused, DNS-based failover never happens.

**Solutions**:
- `CURLOPT_MAXAGE_CONN` (libcurl): Force-close connections older than N seconds, triggering re-resolution.
- `CURLOPT_MAXLIFETIME_CONN` (libcurl): Absolute lifetime limit.
- Go: No built-in max connection lifetime. Must implement custom `DialContext` or periodically create new Transports.

#### Practical Guidance

- Cache DNS for 30-60 seconds for most workloads.
- For services behind load balancers with DNS-based failover, set connection max lifetime to match DNS TTL.
- Never cache DNS indefinitely (Java's default with security manager) -- this breaks failover.

---

### Cookie Jar Management

#### RFC 6265 Requirements

- Cookies are scoped by domain, path, secure flag, and httponly flag.
- User agents should support at least 50 cookies per domain and 3000 total.
- Eviction order: expired cookies first, then domains with excess cookies, then by oldest last-access date.

#### Implementation Support

| Client | Cookie Support | Persistent Storage |
|--------|---------------|-------------------|
| reqwest | Opt-in (`cookie_store` feature) | No (in-memory only) |
| ureq | Opt-in (`cookies` feature) | No |
| libcurl | Yes (`CURLOPT_COOKIEFILE`, `CURLOPT_COOKIEJAR`) | Yes (Netscape/HTTP format files) |
| Go net/http | `http.CookieJar` interface | User-provided (e.g., `cookiejar` package) |
| Zig std | No | No |

libcurl is the only implementation with built-in persistent cookie storage. All others are in-memory or require external storage.

---

### Redirect Following

#### Strategy Comparison

| Client | Default Max | Method Change on 301/302 | Cross-Origin Behavior |
|--------|------------|--------------------------|----------------------|
| reqwest | 10 | Yes (POST -> GET) | Strips sensitive headers |
| libcurl | 50 (`-L` flag) | Configurable | Strips credentials by default |
| Go net/http | 10 | Yes (POST -> GET for 301/302/303) | Strips Authorization header |
| Zig std | Configurable (0-65534) | POST -> GET for 301/302/303 | Strips privileged headers, preserves extras |

#### Security Concerns

1. **Credential leakage**: Redirects to different hosts must strip `Authorization` headers. All major implementations do this.
2. **Open redirect attacks**: Following redirects blindly can be exploited. Limit max redirects and optionally restrict redirect targets.
3. **HTTPS -> HTTP downgrade**: Some implementations warn or refuse to follow redirects that downgrade from HTTPS to HTTP.
4. **Redirect loops**: All implementations cap max redirects to prevent infinite loops.

---

### Proxy Support

#### Protocol Support

| Client | HTTP Proxy | HTTPS CONNECT | SOCKS4 | SOCKS5 |
|--------|-----------|--------------|--------|--------|
| reqwest | Yes | Yes | No | Yes |
| ureq | Yes | Yes | Yes | Yes |
| libcurl | Yes | Yes | Yes | Yes |
| Go net/http | Yes | Yes | No | Yes (via `golang.org/x/net/proxy`) |
| Zig std | Yes | Yes | No | No |

#### HTTP CONNECT Tunneling

The standard approach for proxying HTTPS:
1. Client sends `CONNECT host:443` to proxy
2. Proxy establishes TCP connection to target
3. Proxy responds `200 Connection Established`
4. Client performs TLS handshake directly with target through the tunnel
5. Proxy relays encrypted bytes without inspection

#### Environment Variable Convention

Most implementations read proxy configuration from environment variables: `http_proxy`, `HTTP_PROXY`, `https_proxy`, `HTTPS_PROXY`, `no_proxy`, `NO_PROXY`, `all_proxy`, `ALL_PROXY`.

---

### io_uring Integration

#### Current State for HTTP Clients

io_uring is a Linux kernel interface (since 5.1) for asynchronous I/O using shared ring buffers between user space and kernel space. Two rings: submission queue (SQ) and completion queue (CQ).

#### Rust io_uring Runtimes

| Runtime | Model | HTTP Client? | Status |
|---------|-------|-------------|--------|
| **tokio-uring** | Layered on tokio | No dedicated client | Stale (last release 2022) |
| **monoio** (ByteDance) | Thread-per-core, pure io_uring | No dedicated client | Active, 2-3x tokio throughput at 16 cores |
| **glommio** (Datadog) | Thread-per-core, 3 rings/thread | No dedicated client | Active |

#### Performance Reality

- **File I/O**: io_uring is a clear win (batch syscalls, zero-copy).
- **Network I/O**: Modest gains. Existing non-blocking APIs (epoll) are already efficient for networking. The main benefit is reducing syscall count for high volumes of small operations.
- **PostgreSQL case study**: 11-15% throughput improvement with io_uring + DEFER_TASKRUN.

#### Architectural Implications

- io_uring requires **ownership-based buffer management** (buffers must live until completion). This conflicts with Rust's borrow checker and tokio's `AsyncRead`/`AsyncWrite` traits.
- Thread-per-core model (monoio, glommio) avoids Send/Sync requirements but prevents work-stealing.
- No production HTTP client library currently uses io_uring as its primary I/O backend. The runtimes exist but the HTTP client layers haven't been built on top of them yet.

#### Key Insight

For HTTP clients specifically, io_uring's benefit is marginal compared to epoll. The bottleneck is usually DNS resolution, TLS handshake, and server processing time -- not syscall overhead. io_uring matters more for HTTP *servers* handling thousands of concurrent connections with small payloads.

---

## Comparative Analysis

### Feature Matrix

| Feature | reqwest | hyper | ureq | libcurl | fasthttp | Go net/http | Zig std |
|---------|---------|-------|------|---------|----------|-------------|---------|
| HTTP/1.1 | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| HTTP/2 | Yes | Yes | No | Yes | No | Yes | No |
| HTTP/3 | Experimental | No | No | Yes | No | Experimental | No |
| Async | Yes | Yes | No | Event-driven | Goroutines | Goroutines | No |
| Connection pool | Yes | Manual | Yes | Yes | Yes | Yes | Yes |
| TLS | rustls/native | Manual | rustls/native | Many backends | Go stdlib | Go stdlib | std.crypto.tls |
| Cookies | Opt-in | No | Opt-in | Yes | No | Interface | No |
| Compression | Yes | No | Opt-in | Yes | No | No | Yes |
| Proxy | HTTP/SOCKS5 | Manual | HTTP/SOCKS4/5 | Full | No | HTTP/SOCKS5 | HTTP CONNECT |
| Redirects | Yes | No | Yes | Yes | No | Yes | Yes |

### When to Use What

| Scenario | Best Choice | Why |
|----------|-------------|-----|
| General Rust HTTP client | reqwest | Complete feature set, good defaults |
| Custom Rust HTTP infrastructure | hyper + tower | Maximum control, composable middleware |
| Rust CLI tool / simple script | ureq | Minimal deps, fast compile, simple API |
| C/C++ project, any platform | libcurl | Universal availability, battle-tested |
| High-throughput Go HTTP/1.1 proxy | fasthttp | Zero-alloc hot paths, buffer reuse |
| General Go HTTP client | net/http | Stdlib, HTTP/2, good enough performance |
| Zig project, basic HTTP | std.http.Client | No external deps, ships with Zig |

---

## Key Lessons

### 1. Pool the Client, Not the Connection

Every implementation agrees: the client object owns the pool. Create one client, share it across your application. This is the single most impactful performance optimization.

### 2. Defaults Are Usually Wrong for Production

- Go's `MaxIdleConnsPerHost=2` is too low for single-backend services.
- libcurl's `MAXCONNECTS=5` is too low for concurrent workloads.
- reqwest's `pool_max_idle_per_host=unlimited` can leak connections to many backends.
- No implementation sets a default total timeout. You must set one.

### 3. Stale Connections Are Inevitable

The server can close a connection at any time. No client-side detection is 100% reliable. The robust pattern: detect connection reset, retry idempotent requests transparently, surface errors for non-idempotent requests.

### 4. DNS and Connection Reuse Are in Tension

Reusing connections is fast. Respecting DNS changes requires new connections. The solution is connection lifetime limits (libcurl's `MAXAGE_CONN` / `MAXLIFETIME_CONN`), not disabling reuse.

### 5. Timeout Layering Prevents Cascading Failures

A single "total timeout" is necessary but insufficient. Separate connect, TLS, first-byte, and transfer timeouts let you diagnose where time is being spent and set appropriate limits for each phase.

### 6. Retries Must Be Bounded and Jittered

Exponential backoff without jitter causes thundering herds. Cap the backoff, add full jitter, set an overall operation deadline, and track retry rates as a health metric.

### 7. HTTP/2 Changes the Pooling Game

With HTTP/2 multiplexing, connection pool size becomes less important (one connection handles many streams). But stream limits, flow control, and TCP-level head-of-line blocking introduce new concerns. HTTP/3 (QUIC) eliminates TCP HOL blocking.

### 8. io_uring Is Not Yet Relevant for HTTP Clients

The runtimes exist (monoio, glommio) but no production HTTP client library uses io_uring as its primary backend. For HTTP clients, the bottleneck is rarely syscall overhead. Watch this space for 2026-2027.

### 9. The Sans-IO Pattern Is Gaining Traction

ureq 3.x and Zig's std.http separate protocol logic from I/O. This enables testing protocol handling without network access and plugging in custom transport layers. hyper has always been somewhat Sans-IO by being transport-agnostic.

### 10. libcurl Remains the Reference Implementation

After 26+ years, libcurl's design decisions (connection aging, DNS cache timeout, multi-interface event loop, share interface) remain the benchmark against which newer implementations are measured. Study its options when designing a new HTTP client.

---

## Sources

### Primary Documentation
- [reqwest GitHub](https://github.com/seanmonstar/reqwest)
- [reqwest Client docs](https://docs.rs/reqwest/latest/reqwest/struct.Client.html)
- [reqwest ClientBuilder docs](https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html)
- [hyper GitHub](https://github.com/hyperium/hyper)
- [hyper client::conn docs](https://docs.rs/hyper/latest/hyper/client/conn/index.html)
- [ureq GitHub](https://github.com/algesten/ureq)
- [ureq docs](https://docs.rs/ureq/latest/ureq/)
- [libcurl multi interface](https://curl.se/libcurl/c/libcurl-multi.html)
- [everything curl: connection reuse](https://everything.curl.dev/transfers/conn/reuse.html)
- [everything curl: keep alive](https://everything.curl.dev/transfers/conn/keepalive.html)
- [CURLOPT_DNS_CACHE_TIMEOUT](https://curl.se/libcurl/c/CURLOPT_DNS_CACHE_TIMEOUT.html)
- [CURLOPT_MAXCONNECTS](https://curl.se/libcurl/c/CURLOPT_MAXCONNECTS.html)
- [CURLOPT_TCP_KEEPALIVE](https://curl.se/libcurl/c/CURLOPT_TCP_KEEPALIVE.html)
- [fasthttp GitHub](https://github.com/valyala/fasthttp)
- [Go net/http package](https://pkg.go.dev/net/http)
- [Zig std.http.Client source](https://github.com/ziglang/zig/blob/master/lib/std/http/Client.zig)

### Architecture Deep Dives
- [Cloudflare: What's inside net/http? Late binding in Go](https://blog.cloudflare.com/whats-inside-net-http-socket-late-binding-in-the-go-standard-library/)
- [Deep Dive into Go's HTTP Client Transport Layer](https://leapcell.io/blog/deep-dive-into-go-s-http-client-transport-layer)
- [Orhun: Zig HTTP client/server from scratch](https://blog.orhun.dev/zig-bits-04/)
- [LogRocket: How to choose the right Rust HTTP client](https://blog.logrocket.com/best-rust-http-client/)
- [Comparing deboa and reqwest](https://dev.to/rogrio_arajo_55dae16f0d/comparing-deboa-and-reqwest-two-rust-http-clients-in-2025-ooa)
- [fasthttp vs net/http performance comparison](https://www.sobyte.net/post/2022-03/nethttp-vs-fasthttp/)

### Retry and Resilience
- [AWS Builders' Library: Timeouts, retries, and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/)
- [AWS: Retry with backoff pattern](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/retry-backoff.html)
- [DZone: Retry pattern with exponential backoff and circuit breaker](https://dzone.com/articles/understanding-retry-pattern-with-exponential-back)

### io_uring and Async Runtimes
- [tokio-uring announcement](https://tokio.rs/blog/2021-07-tokio-uring)
- [monoio GitHub (ByteDance)](https://github.com/bytedance/monoio)
- [Datadog: Introducing Glommio](https://www.datadoghq.com/blog/engineering/introducing-glommio/)
- [Tonbo: Async Rust is not safe with io_uring](https://tonbo.io/blog/async-rust-is-not-safe-with-io-uring)
- [Red Hat: Why you should use io_uring for network I/O](https://developers.redhat.com/articles/2023/04/12/why-you-should-use-iouring-network-io)
- [io_uring kernel paper](https://kernel.dk/io_uring.pdf)

### Protocols and Standards
- [RFC 7540: HTTP/2](https://httpwg.org/specs/rfc7540.html)
- [RFC 9113: HTTP/2 (revised)](https://datatracker.ietf.org/doc/html/rfc9113)
- [RFC 6265: HTTP State Management (Cookies)](https://www.rfc-editor.org/rfc/rfc6265.html)
- [HPBN: HTTP/2](https://hpbn.co/http2/)

### Connection Management
- [Apache HttpClient: Connection management tutorial](https://hc.apache.org/httpcomponents-client-4.5.x/current/tutorial/html/connmgmt.html)
- [HAProxy: HTTP keep-alive, pipelining, multiplexing & connection pooling](https://www.haproxy.com/blog/http-keep-alive-pipelining-multiplexing-and-connection-pooling)
- [Stale connection race condition analysis](https://www.webperformance.com/load-testing-tools/blog/2011/01/load-testing-back-to-basics-avoiding-the-keepalivetimeout-race-condition/)
- [DNS client TTL survey](https://www.ctrl.blog/entry/dns-client-ttl.html)


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-a9dd0699bfe2424b5.jsonl`
