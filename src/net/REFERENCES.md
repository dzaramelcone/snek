# HTTP/1.1 and HTTP/2 Server Implementation References

Exhaustive survey of state-of-the-art HTTP implementations across high-performance systems languages.
Last updated: 2026-03-21.

---

## Table of Contents

1. [Rust Implementations](#rust-implementations)
2. [C Implementations](#c-implementations)
3. [Zig Implementations](#zig-implementations)
4. [Go Implementations](#go-implementations)
5. [Odin Implementations](#odin-implementations)
6. [HTTP/1.1 Parsing Strategies](#http11-parsing-strategies)
7. [HTTP/2 HPACK Compression](#http2-hpack-compression)
8. [HTTP/2 Stream Multiplexing and Flow Control](#http2-stream-multiplexing-and-flow-control)
9. [HTTP/2 Priority and Scheduling](#http2-priority-and-scheduling)
10. [Request Smuggling Prevention](#request-smuggling-prevention)
11. [Header Parsing Optimization](#header-parsing-optimization)
12. [Chunked Transfer Encoding](#chunked-transfer-encoding)
13. [100-Continue Handling](#100-continue-handling)
14. [Connection Upgrade Mechanism](#connection-upgrade-mechanism)
15. [HTTP Pipelining](#http-pipelining)
16. [Research Papers](#research-papers)
17. [Benchmark References](#benchmark-references)

---

## Rust Implementations

### hyper

- **URL**: https://github.com/hyperium/hyper
- **Language**: Rust
- **License**: MIT
- **Stars**: 16,000+ | **Commits**: 2,908 | **Releases**: 187 (latest v1.8.1, Nov 2025)

**Design decisions and architecture**:
- Low-level building block library, not a framework. Higher-level abstractions (axum, warp, reqwest) build atop it.
- Async-native, built on Tokio for non-blocking I/O.
- Dual HTTP/1 and HTTP/2 support in a single crate.
- Pure Rust, memory-safe by construction.
- Architecture: listener -> service factory -> service handler pattern.
- Uses `httparse` for HTTP/1.x parsing (see below).
- Uses `h2` crate for HTTP/2 protocol handling (see below).

**Performance claims**:
- ~787,000 req/s with average latency ~310us.
- Over 98% of requests within one standard deviation of mean latency (consistent, predictable).
- TechEmpower Round 23 (2025): Rust/Actix (built on hyper ecosystem) ranks 3rd overall at 19.1x baseline.

**Production exposure**:
- Foundation for the Rust HTTP ecosystem: reqwest, axum, warp, tonic (gRPC).
- Used by Cloudflare, AWS, Discord, Dropbox, and many others in production.
- 317,000+ dependent crates (via h2 alone).

**Trade-offs**:
- Low-level API requires more boilerplate than frameworks.
- HTTP/2 support delegates to separate `h2` crate (clean separation but another dependency).
- Async-only design means no sync API.

### httparse

- **URL**: https://github.com/seanmonstar/httparse
- **Language**: Rust
- **License**: MIT/Apache-2.0

**Design decisions**:
- Push parser: stateless, zero-copy, zero-allocation. Design inspired by picohttpparser.
- Stateless by choice: "Keeping state means branches, which slow down individual parsing attempts." Socket state managed externally.
- Handles partial requests gracefully -- returns `is_partial()` for incomplete data, allowing incremental feeding.
- `no_std` compatible for embedded/constrained environments.
- Uses an internal `Iterator` to avoid bounds checks while maintaining memory safety.

**SIMD support**:
- Automatic SIMD detection since Rust 1.27.0.
- Runtime detection of SSE4.2 and AVX2 support.
- Compile-time optimization with `-C target_cpu=native`.
- SIMD used for scanning header bytes (same approach as picohttpparser).

**Trade-offs**:
- HTTP/1.x only -- no HTTP/2 parsing.
- Stateless means re-parsing from the start on each call (mitigated by fast SIMD scanning).
- Safe Rust wrapper around inherently unsafe SIMD intrinsics.

### h2 (Rust)

- **URL**: https://github.com/hyperium/h2
- **Language**: Rust
- **License**: MIT
- **Latest release**: v0.4.13 (Jan 2026)

**Design decisions**:
- Full HTTP/2 specification implementation with h2spec compliance.
- Built on Tokio async runtime.
- Deliberately excludes: TCP lifecycle, HTTP/1.x upgrade, TLS handling.
- Clean separation of concerns: protocol mechanics only.
- Both client and server APIs.

**Production exposure**:
- 317,000+ dependent projects.
- Foundation for hyper's HTTP/2 support.
- Passes formal h2spec test suite.

**Key implementation details**:
- Stream multiplexing with per-stream and connection-level flow control.
- HPACK header compression with static and dynamic tables.
- Priority/weight-based scheduling (RFC 7540, with RFC 9218 extensible priorities support).

---

## C Implementations

### H2O

- **URL**: https://github.com/h2o/h2o
- **Language**: C (70.5%)
- **License**: MIT
- **Stars**: 11,400+ | **Commits**: 12,424 | **Contributors**: 139

**Design decisions and architecture**:
- Designed from ground-up for HTTP/2, not retrofitted.
- Supports HTTP/1.x, HTTP/2, HTTP/3 (experimental).
- Uses picohttpparser for HTTP/1.x parsing.
- Event-driven architecture with handler chain.
- Server-push with cache-aware optimization: maintains browser cache fingerprint via `h2o_casper` cookie using Golomb-compressed sets to avoid pushing already-cached content.
- Detects browsers with poor priority specification and applies server-driven prioritization.
- Modular design: can be used as a library.

**Performance claims**:
- 337,751 req/s (ECDHE-RSA-AES128-GCM-SHA256) on c3.8xlarge instances.
- 328,669 req/s (ECDHE-RSA-AES256-SHA).
- 30% reduction in first-paint time vs HTTP/1.1.
- Benchmarks: 612-byte file, 250 concurrent clients, wrk (HTTP/1) / h2load (HTTP/2).

**Production exposure**:
- Used by Fastly CDN.
- Continuous fuzzing via OSS-Fuzz.
- Coverity Scan for static analysis.
- Dedicated security vulnerability reporting process.

**Lessons learned**:
- Server-push effectiveness depends on cache-awareness; blind pushing wastes bandwidth.
- Priority handling matters more than raw throughput for user-perceived performance.
- HTTP/2 improves UX even when raw req/s is similar to HTTP/1.1.

### picohttpparser

- **URL**: https://github.com/h2o/picohttpparser
- **Language**: C
- **License**: MIT / Perl

**Design decisions**:
- Tiny, stateless, zero-copy parser. Does not allocate memory.
- Accepts buffer pointer + output struct; sets pointers into the buffer. No data copying.
- Four functions: `phr_parse_request`, `phr_parse_response`, `phr_parse_headers`, `phr_decode_chunked`.
- Return values: >0 (success, bytes consumed), -1 (parse error), -2 (incomplete).
- In-place chunked decoding.

**SIMD optimization (SSE4.2)**:
- Uses `PCMPESTRI` instruction to check 16 bytes at once for character ranges.
- `findchar_fast` wrapper iterates 16 bytes at a time to find delimiter bytes.
- 68-90% faster than scalar code.
- Limitation: PCMPESTRI has 11-cycle latency, limiting throughput to 1.45 bytes/cycle.

**SIMD optimization (AVX2)** -- Cloudflare contribution:
- AVX2 operates on 32 bytes with 0.5 cycles/instruction throughput.
- ~22 AVX2 instructions execute in time of single PCMPESTRI.
- Creates bitmaps of 128 bytes at a time, generating dual bitmasks for name/value delimiter AND newline delimiter simultaneously.
- Uses `PMOVMSKB` to extract byte mask, `TZCNT` to locate set bits.
- **1.79x improvement** over PCMPESTRI on bench.c (6,963,788 vs 3,900,156).
- **1.68x improvement** on fukamachi.c (8,064,516 vs 4,807,692).
- Benchmarked on Haswell i5-4278U, gcc 4.9.2 -mavx2 -mbmi2 -O3.

**Production exposure**:
- HTTP/1 parser for H2O web server.
- Widely deployed in Perl ecosystem (Plack, Starman, Starlet, Furl).
- Claimed 10x faster than http-parser (Node.js predecessor).

**Key insight**: The shift from "find first occurrence" (SSE4.2) to "find all occurrences as bitmask" (AVX2) is the fundamental architectural improvement. Bitmask approach amortizes per-character work across wider vectors.

### llhttp

- **URL**: https://github.com/nodejs/llhttp
- **Language**: TypeScript (specification) -> C (generated output)
- **License**: MIT

**Design decisions**:
- Port of http_parser, generated from TypeScript via llparse.
- ~1,400 lines TypeScript (parser description) + ~450 lines C (helpers) vs ~2,500 lines hand-optimized C in http_parser.
- State machine graph explicitly encoded; llparse automatically verifies absence of loops and correct input range reporting.
- All optimizations and multi-character matching generated automatically -- zero extra maintenance cost.
- Lenient parsing modes available (with security warnings) for legacy compatibility.

**Performance claims**:
- **156% faster** than http_parser.
- llhttp: 1,777.24 MB/s bandwidth, 3,583,799 req/s.
- http_parser: 694.66 MB/s bandwidth, 1,406,180 req/s.
- **More than 2x** the throughput.

**Production exposure**:
- Default Node.js parser since v12.0.0.
- Powers every Node.js HTTP server worldwide.

**Lessons learned**:
- Code generation from a higher-level specification produces both faster AND more maintainable code.
- Manual optimization of C parsers hits diminishing returns and creates maintenance burden.
- Automatic verification catches bugs that manual review misses.
- "Introduction of a single new method results in a significant code churn" in hand-written parsers.

---

## Zig Implementations

### http.zig (httpz)

- **URL**: https://github.com/karlseguin/http.zig
- **Language**: Zig (100%)

**Design decisions**:
- Pure Zig, does not use `std.http.Server` (considered "very slow and assumes well-behaved clients").
- Generic handler pattern using comptime generics (`Server(H)`).
- Per-request arena allocator with thread-local buffer and automatic heap fallback.
- Dispatch takeover hierarchy: `handle()` > `dispatch()` > route handlers > `notFound()` > `uncaughtError()`.
- Request-scoped context structs for safe concurrent handling.

**Performance claims**:
- ~140K req/s on Apple M2 (basic request).

**Production exposure**:
- Used as the HTTP backend for Jetzig framework.
- Also planned as backend for Tokamak.

**Trade-offs**:
- HTTP/1.1 only, no HTTP/2.
- No WebSocket documentation (mentioned but undocumented).

### Zap

- **URL**: https://github.com/zigzap/zap
- **Language**: Zig (wraps C library facil.io)

**Design decisions**:
- Wraps facil.io rather than implementing HTTP natively.
- Two programming models: app-based (global context + per-thread arena) and middleware (chaining with type-safe context).
- Explicit error handling, no hidden control flow.

**Performance claims**:
- ~118,040 req/s on Apple M1 Pro.
- ~30% faster than simple Go HTTP server.
- >50% more throughput than Go.
- Author acknowledges micro-benchmarks have limited real-world relevance.

**Trade-offs**:
- Not pure Zig (C dependency on facil.io).
- Windows unsupported (facil.io limitation).
- Networking layer opaque (abstracted by facil.io).
- Author hopes pure-Zig frameworks will eventually make Zap obsolete.

### zzz

- **URL**: https://github.com/zxhoper/zig-http-zzz
- **Language**: Zig

**Design decisions**:
- Pure Zig, io_uring support on Linux.
- Allocation at startup, avoids thread contention.
- Currently TCP-only transport with arbitrary protocol support.

**Performance claims**:
- 66.4% faster than Zap.
- 77% faster than http.zig.
- Uses ~3% of memory used by Zap.
- Uses ~18% of memory used by http.zig.

**Trade-offs**:
- Alpha software, API still changing rapidly.
- Linux primary platform; Windows/macOS/BSD planned.
- Not yet updated to Zig 0.15.1.

### Jetzig

- **URL**: https://github.com/jetzig-framework/jetzig
- **Language**: Zig (97.5%)
- **Stars**: 1,400+

**Design decisions**:
- Full web framework (not just HTTP server), built on http.zig.
- File-system-based routing with dynamic slug matching.
- Dual response formats: HTML (Zmpl templates) and JSON.
- Per-request arena allocator.
- Background jobs, email delivery, session/cookie handling.
- Development server with auto-reload.

**Trade-offs**:
- Higher-level framework, not suitable as a low-level HTTP building block.
- Inherits http.zig's limitations (HTTP/1.1 only).

---

## Go Implementations

### fasthttp

- **URL**: https://github.com/valyala/fasthttp
- **Language**: Go
- **License**: MIT

**Design decisions and zero-allocation strategy**:
1. **Worker pool model**: Pre-initialized workers with channel-based connection dispatch. Workers fetched from ready queue or object pool. Avoids per-goroutine allocation overhead of stdlib's `go c.serve()`.
2. **RequestCtx reuse via sync.Pool**: Parsed HTTP data produces `*fasthttp.RequestCtx` which is pooled and reused. **Critical constraint**: references to RequestCtx MUST NOT be held after handler returns -- "data races are inevitable."
3. **Byte-slice processing**: Processes most data as `[]byte`, avoiding string conversions and copies.
4. **Single-function handler**: `func(ctx *RequestCtx)` instead of interface-based handlers, eliminating allocation overhead.
5. **No header map**: Avoids `map[string][]string` allocation that net/http requires for every request.

**Performance claims**:
- Server: 451.4 ns/op vs net/http's 2,179 ns/op (10K requests per connection).
- Benchmark: 0 B/op, 0 allocs/op vs net/http's 2,385-3,263 B/op, 21-36 allocs/op.
- Claims "up to 6x faster" than net/http (server), "up to 4x faster" (client).

**Production exposure**:
- VertaMedia: 200K req/s from 1.5M+ concurrent keep-alive connections per physical server.
- Used by many high-performance Go services.

**Trade-offs**:
- API incompatible with net/http (no drop-in replacement).
- RequestCtx lifetime restriction makes async processing difficult (requires explicit copy).
- Designed for "thousands of small to medium requests per second" -- not general purpose.
- "Blind switching from net/http to fasthttp won't give you performance boost" if handler is the bottleneck.
- HTTP/1.1 only, no HTTP/2 support.

---

## Odin Implementations

### odin-http

- **URL**: https://github.com/laytan/odin-http
- **Language**: Odin (pure, except SSL)

**Design decisions**:
- Platform-specific kernel APIs for I/O:
  - Linux: io_uring
  - macOS: KQueue
  - Windows: IOCP
- Lua pattern-based routing (Odin lacks regex implementation).
- Modular I/O subsystem usable independently for file/socket operations (UDP and TCP), fully cross-platform.
- HTTP/1.1 only.

**Trade-offs**:
- Beta software, API unstable.
- Odin ecosystem for web development is still immature.
- No HTTP/2 support.
- Limited community and production exposure.

---

## HTTP/1.1 Parsing Strategies

### Zero-Copy Parsing

The dominant high-performance approach. Instead of copying data from the network buffer into parsed structures, the parser returns pointers/slices into the original buffer.

**Implementations using this approach**:
- picohttpparser (C): sets pointers into input buffer
- httparse (Rust): returns `&[u8]` slices into input buffer
- fasthttp (Go): returns slices directly, avoiding string conversions
- llhttp (C): callback-based but avoids internal allocation

**Trade-off**: Buffer must remain valid for the lifetime of parsed references. This complicates buffer management (can't free/reuse buffer until all references are consumed).

### SIMD-Accelerated Parsing

Two generations of approach:

**Generation 1: SSE4.2 (PCMPESTRI)**
- Check 16 bytes at once against character ranges.
- Find first occurrence of delimiter character.
- Throughput limited by 11-cycle instruction latency: ~1.45 bytes/cycle.
- Used by: picohttpparser (original), httparse (Rust).

**Generation 2: AVX2 (Bitmask)**
- Process 128 bytes simultaneously.
- Generate bitmasks for ALL occurrences of multiple delimiters at once.
- Use TZCNT to iterate set bits.
- Throughput: significantly higher due to 0.5 cycle/instruction for boolean ops.
- 1.68-1.79x improvement over SSE4.2.
- Used by: picohttpparser (Cloudflare patch).

**Key insight from Cloudflare**: The paradigm shift is from "find first match" to "find all matches as bitmask." This is the same insight that powers simdjson.

### State Machine Approaches

**Explicit state machines (llhttp)**:
- Parser logic defined in higher-level language (TypeScript).
- State machine compiled to optimized C.
- Enables automatic verification (no loops, correct range reporting).
- 156% faster than hand-optimized C (http_parser).

**Implicit state machines (http_parser, nginx)**:
- Hand-written C with manual state tracking.
- Difficult to maintain: adding a new HTTP method causes significant code churn.
- Performance ceiling from manual optimization.

**Research finding** (IEEE SPW 2014): DFA-based parsers "are sufficiently expressive for meaningful protocols, sufficiently performant for high-throughput applications, and sufficiently simple to construct and maintain." Outperform nginx and Apache parsers.

### Push vs Pull Parsers

**Push parsers** (httparse, picohttpparser):
- Caller pushes data into parser.
- Parser returns: complete, incomplete, or error.
- Stateless: no internal state between calls.
- Natural fit for event-driven I/O.

**Pull/callback parsers** (llhttp, http_parser):
- Parser calls back into user code for each parsed element.
- Can maintain state between callbacks.
- More complex API but handles streaming naturally.

---

## HTTP/2 HPACK Compression

### Overview (RFC 7541)

HPACK compresses HTTP/2 headers using three complementary techniques:

### Static Table

- 61 predefined header fields with common values.
- Single-byte references for frequent headers (`:method: GET`, `:path: /`, `:scheme: https`).
- Fixed, never changes.
- **Implementation**: array lookup by index (O(1)).

### Dynamic Table

- Connection-specific, stores headers encountered during the session.
- Limited size controlled by `SETTINGS_HEADER_TABLE_SIZE`.
- FIFO eviction: new entries evict oldest when table is full.
- Enables 1-2 byte references for recently-used headers.
- **Implementation**: circular buffer for efficient insertion/eviction.

### Huffman Encoding

- Static Huffman code optimized for HTTP header content.
- Shorter codes for frequent characters (ASCII digits, lowercase letters).
- Maximum compression ratio: 8:5 (37.5% reduction).
- Huffman alone saves ~30% of header size.
- **Implementation optimization**: 4-bit based decoding is 2.69x faster than bit-by-bit.

### Compression Results (Cloudflare production data)

- Request headers: **76% average compression**.
- Response headers: **69% average compression**.
- Total ingress traffic: **53% reduction** from header compression.
- Repeated requests: 300-byte cookie + 130-byte user-agent compressed to 4 bytes (**99% compression**).

### Implementation Optimization Techniques

From Yamamoto (2017):
- Hash-based lookups for fast header retrieval in both static and dynamic tables.
- HPACK encoding with optimization techniques is **2.10x faster** than naive implementation.
- 4-bit based HPACK decoding is **2.69x faster** than bit-by-bit implementation.
- Optional Huffman: only use when beneficial (some short values are shorter without Huffman).
- Progressive/incremental decoding for header blocks.

### Security: CRIME Resistance

HPACK was specifically designed to resist CRIME-style attacks:
- No partial backward string matches (unlike DEFLATE).
- No dynamic Huffman codes.
- Attacker must guess entire header value, not gradually probe character by character.

---

## HTTP/2 Stream Multiplexing and Flow Control

### Stream Multiplexing

- Each HTTP request/response exchange gets its own stream ID.
- Streams are largely independent; blocked/stalled streams don't prevent progress on others.
- Frames are the smallest unit: tagged with stream ID, interleaved on the wire.
- A response becomes: HEADERS frame (status) + multiple DATA frames (body).

### Flow Control Design (RFC 9113)

- **Credit-based**: receiver advertises window size, sender decrements on DATA frames, receiver increments via WINDOW_UPDATE.
- **Two levels**: per-stream windows AND connection-level window.
- **Initial window**: 65,535 bytes for both stream and connection.
- **DATA frames only**: control frames (HEADERS, SETTINGS, WINDOW_UPDATE, etc.) are never flow-controlled.
- **Implementation freedom**: RFC defines frame format/semantics but not when to send WINDOW_UPDATE or what values to use.

### Flow Control Deadlock (Critical Implementation Bug)

**Root cause** (documented by nitely, 2024): If an implementation does not read and process frames from the TCP buffer promptly, WINDOW_UPDATE frames can be blocked behind unprocessed DATA frames, causing permanent stall.

**RFC 9113 requirement**: "Endpoints MUST read and process HTTP/2 frames from the TCP receive buffer as soon as data is available."

**Prevention strategy**:
1. Process ALL frames asynchronously and immediately upon arrival.
2. Store DATA frames in internal stream buffer (bounded by stream window size).
3. Send WINDOW_UPDATE after application consumes buffered data (not upon receipt).
4. Total buffer consumption cannot exceed connection window size.
5. Never let application-level processing block frame reception.

**Application-level deadlocks**: Simultaneous bidirectional data transmission on a single stream without concurrent receiving. gRPC prevents this with structured message protocols defining sender/receiver patterns.

---

## HTTP/2 Priority and Scheduling

### Original Priority Tree (RFC 7540) -- DEPRECATED

- Complex system: clients signal stream dependencies and weights forming an unbalanced tree.
- Suffered from limited deployment and poor interoperability.
- Most implementations ignored or poorly implemented it.
- Deprecated in RFC 9113 (HTTP/2 revision).

### Extensible Priorities (RFC 9218) -- Current Standard

- Replaces dependency tree with simple absolute values.
- HTTP version-independent (works for HTTP/2 and HTTP/3).
- Two parameters:
  - **Urgency**: 0-7 (lower = higher priority, default 3).
  - **Incremental**: boolean (false = benefits from complete delivery, true = benefits from partial/streaming).
- Communicated via `Priority` header field.
- Reprioritization via HTTP/2 and HTTP/3 frames.
- Designed for future extensibility.

### Implementation Status

- Firefox: implementing (Bugzilla 1865040).
- Go x/net/http2: open issue (#75500) for RFC 9218 support.
- H2O: early adopter of priority-based scheduling.

---

## Request Smuggling Prevention

### The Fundamental Problem

HTTP/1.1 request boundaries are ambiguous. Requests are concatenated on TCP/TLS with no delimiters. Four ways to specify length create parsing disagreements:
- **CL** (Content-Length)
- **TE** (Transfer-Encoding: chunked)
- **0** (Implicit zero-length body)
- **H2** (HTTP/2's built-in length framing)

### Attack Variants

| Variant | Front-end uses | Back-end uses |
|---------|---------------|---------------|
| CL.TE | Content-Length | Transfer-Encoding |
| TE.CL | Transfer-Encoding | Content-Length |
| CL.0 | Content-Length | Implicit zero |
| 0.CL | Implicit zero | Content-Length |
| H2.CL | HTTP/2 length | Content-Length (after downgrade) |
| H2.TE | HTTP/2 length | Transfer-Encoding (after downgrade) |
| H2.0 | HTTP/2 length | Implicit zero (after downgrade) |

### "HTTP/1.1 Must Die" (James Kettle, 2025)

Presented at DEF CON 33 and Black Hat USA 2025. Key findings:

- **New attack class: 0.CL desync** -- previously thought unexploitable. Uses "early-response gadgets" (e.g., IIS's `/con` reserved filename) enabling "double-desync" technique.
- **Expect-based desync**: `Expect: 100-continue` header creates proxy handling complexity. Four vulnerability sub-categories discovered.
- **Scale of impact**: Cloudflare H2.0 desync exposed 24 million websites. Akamai CDN, Netlify CDN, AWS ALB + IIS all affected.
- **$200K+ in bug bounties** from this research alone.
- **Core thesis**: "HTTP/1.1 implementations are so densely packed with critical vulnerabilities, you can literally find them by mistake."

### Prevention Strategies for Server Implementors

1. **Use HTTP/2 end-to-end**: Binary framing eliminates boundary ambiguity. THE most effective mitigation.
2. **Strict header validation**:
   - Reject requests with BOTH Content-Length AND Transfer-Encoding.
   - Reject newlines in headers.
   - Reject colons in header names.
   - Reject spaces in request method.
   - Disallow obsolete line folding.
   - Reject duplicate Content-Length headers with differing values.
3. **Normalize ambiguous requests** at the front-end before routing.
4. **Reject bodies on bodyless methods** (GET, HEAD, OPTIONS).
5. **Disable HTTP downgrading** if possible (HTTP/2 -> HTTP/1.1 is where most smuggling occurs).
6. **Disable upstream connection reuse** (nuclear option, prevents smuggling entirely but hurts performance).
7. **Close TCP connection** on any ambiguous request (back-end servers).

---

## Header Parsing Optimization

### Perfect Hashing for Known Headers

**H3 library** (https://github.com/c9s/h3):
- Pre-built minimal perfect hash table for standard HTTP header field names.
- Generated via `gperf`.
- Known headers: O(1) lookup via perfect hash.
- Custom headers (X-* etc.): simple/quick hash function.
- All header fields lazily parsed -- details only parsed when accessed.

**The problem**: Case-insensitive string comparison of header names is the biggest obstacle in high-performance HTTP parsing. Perfect hashing eliminates per-character comparison.

### Alternative Approaches

**Length + first-byte dispatch**: Branch on header name length, then first byte, to narrow to a small set of candidates. Used by some hand-optimized parsers.

**Trie-based lookup**: Build a trie of known header names. O(n) in header name length but cache-friendly for short names.

**Pre-computed enum mapping**: Map known headers to integer enum at parse time. All subsequent operations use integer comparison. Used by hyper/httparse internally.

---

## Chunked Transfer Encoding

### Specification (RFC 9112)

Format:
```
<chunk-size-hex>\r\n
<chunk-data>\r\n
...
0\r\n
<optional trailers>\r\n
```

### Edge Cases and Pitfalls

1. **Chunk size parsing**: Must be valid hexadecimal. Implementations must handle leading zeros, chunk extensions (`;ext=val` after size), and maximum size limits.

2. **Terminal chunk**: Without the final `0\r\n\r\n`, clients hang or discard. Server MUST send terminal chunk.

3. **Header conflict**: `Content-Length` + `Transfer-Encoding: chunked` together creates ambiguity. **This is the #1 request smuggling vector.** Implementation MUST reject or prioritize one deterministically (RFC says TE takes precedence, but disagreements between proxies cause smuggling).

4. **Status code restrictions**: MUST NOT send `Transfer-Encoding` with 1xx or 204 responses.

5. **Double-chunking**: MUST NOT apply chunked encoding more than once.

6. **Keep-alive socket pollution**: Junk data remaining on socket after chunked transfer interferes with next request. Server must properly cleanup socket buffer.

7. **Chunk size extremes**: Very small chunks (1 byte) create high overhead. Very large chunks risk buffer overflow. Implementations should bound maximum chunk size.

8. **In-place decoding**: picohttpparser's `phr_decode_chunked` decodes in-place, modifying the buffer. Efficient but requires careful buffer management.

9. **Trailers**: Rarely used but must be handled. Trailer headers arrive after the final chunk.

---

## 100-Continue Handling

### Protocol (RFC 9110)

1. Client sends request with `Expect: 100-continue` header, withholds body.
2. Server examines headers and responds with either:
   - `100 Continue` -- client sends body.
   - Error status (e.g., 401, 413) -- client skips body, saves bandwidth.

### Implementation Requirements

- Server MUST NOT wait for request body before sending 100 response.
- Server MUST either send 100 or a final status code.
- If server sends 100, it MUST still read and process the subsequent body.
- Client SHOULD implement a timeout: if no 100 response arrives, send body anyway.

### Server Response Options

- **Accept**: Send `100 Continue`, then read body.
- **Decline**: Send 401/405/413 etc., close connection.
- **Reject expectation**: Send `417 Expectation Failed`, client re-sends without Expect header.

### Security Implications

- The `Expect` header is a request smuggling vector (Kettle 2025): proxy handling differences for `Expect: 100-continue` enable four distinct desync attack categories.
- Obfuscated Expect headers (e.g., `Expect: 100-Continue` with capital C, or `Expect: 100-continue\r\n`) trigger different behavior in different implementations.

---

## Connection Upgrade Mechanism

### HTTP/1.1 Upgrade (RFC 7230)

1. Client sends request with `Upgrade: <protocol>` and `Connection: Upgrade` headers.
2. Server agrees: responds `101 Switching Protocols` with `Upgrade: <protocol>`.
3. Connection transitions to new protocol.

**Primary use case**: WebSocket (`Upgrade: websocket`).

### h2c (HTTP/2 Cleartext) -- DEPRECATED

- Upgrade token: `h2c`.
- Never widely deployed.
- Deprecated in current HTTP/2 specification.
- **Security risk**: h2c smuggling allows bypassing reverse proxy access controls (Bishop Fox 2020). Proxies that blindly forward Upgrade headers enable attackers to establish direct HTTP/2 connections to backend servers.

### HTTP/2 WebSocket (RFC 8441)

- HTTP/2 does NOT support Upgrade header or 101 status.
- Instead: Extended CONNECT method creates a tunnel on a single HTTP/2 stream.
- More efficient: no connection-per-WebSocket, benefits from HTTP/2 multiplexing.

### Implementation Notes

- `Upgrade` is a hop-by-hop header; `Connection: Upgrade` is required.
- Proxies MUST NOT forward Upgrade headers unless explicitly configured.
- After upgrade, the connection is no longer HTTP -- all subsequent data follows the new protocol.

---

## HTTP Pipelining

### Overview (HTTP/1.1)

Allows sending multiple requests without waiting for responses. Responses MUST be returned in request order.

### Why It Failed

1. **Head-of-line blocking**: A slow response blocks all subsequent responses.
2. **Implementation bugs**: Some servers respond out of order or corrupt responses in pipelined scenarios.
3. **Security concerns**: Buggy servers behind shared proxies can leak responses between users.
4. **Proxy incompatibility**: Many intermediaries break pipelining.
5. **Browser abandonment**: Only Opera ever fully supported it. Firefox removed support in v54. All other browsers never enabled it by default.

### Server Implementation Pitfalls

- MUST buffer complete responses and send in request order.
- Cannot interleave response data from different requests (unlike HTTP/2).
- Must handle client disconnect mid-pipeline gracefully.
- Must not assume clients support pipelining.

### Modern Replacement

HTTP/2 multiplexing solves the same problem properly:
- True concurrent streams, no ordering requirement.
- Per-stream flow control.
- No head-of-line blocking at application layer (but still at TCP layer -- solved by HTTP/3/QUIC).

---

## Research Papers

### "Finite State Machine Parsing for Internet Protocols: Faster Than You Think"
- **Authors**: IEEE SPW 2014
- **URL**: https://www.ieee-security.org/TC/SPW2014/papers/5103a185.PDF
- **Key findings**: DFA-based parsers outperform nginx/Apache implementations. Sufficiently expressive for real protocols, sufficiently performant for high throughput, sufficiently simple to maintain. Cache hit latency is the key hardware parameter affecting throughput.

### "Exploring HTTP/2 Header Compression" (Yamamoto, 2017)
- **URL**: https://www.mew.org/~kazu/doc/paper/hpack-2017.pdf
- **Key findings**: Three optimization techniques for HPACK. Encoding 2.10x faster than naive. 4-bit decoding 2.69x faster than bit-by-bit. Hash-based lookups + circular buffer for dynamic table.

### "Improving Parser Performance using SSE Instructions" (Kazuho Oku, 2014)
- **URL**: http://blog.kazuhooku.com/2014/12/improving-parser-performance-using-sse.html
- **Key findings**: SSE4.2 PCMPESTRI for HTTP parsing. 68-90% speedup over scalar.

### "Improving PicoHTTPParser Further with AVX2" (Cloudflare, Vlad Krasnov)
- **URL**: https://blog.cloudflare.com/improving-picohttpparser-further-with-avx2/
- **Key findings**: Bitmask approach processing 128 bytes at once. 1.68-1.79x over SSE4.2.

### "HPACK: The Silent Killer Feature of HTTP/2" (Cloudflare)
- **URL**: https://blog.cloudflare.com/hpack-the-silent-killer-feature-of-http-2/
- **Key findings**: Production compression ratios (76% request, 69% response). CRIME resistance design. 99% compression on repeated cookies.

### "HTTP Desync Attacks: Request Smuggling Reborn" (James Kettle, PortSwigger)
- **URL**: https://portswigger.net/research/http-desync-attacks-request-smuggling-reborn
- **Key findings**: Systematic framework for finding request smuggling. CL.TE, TE.CL, TE.TE variants.

### "HTTP/1.1 Must Die: The Desync Endgame" (James Kettle, 2025)
- **URL**: https://portswigger.net/research/http1-must-die
- **Key findings**: New 0.CL and Expect-based desync classes. 24 million websites exposed via Cloudflare. $200K+ bounties. Argues HTTP/1.1 is fundamentally unfixable.

### "HTTP/2 Flow Control Deadlock" (nitely, 2024)
- **URL**: https://nitely.github.io/2024/08/23/http-2-flow-control-dead-lock.html
- **Key findings**: Failure to promptly process WINDOW_UPDATE frames causes permanent deadlock. Must process all frames asynchronously.

### RFC 7541: HPACK Header Compression for HTTP/2
- **URL**: https://httpwg.org/specs/rfc7541.html

### RFC 9113: HTTP/2
- **URL**: https://datatracker.ietf.org/doc/html/rfc9113

### RFC 9218: Extensible Prioritization Scheme for HTTP
- **URL**: https://www.rfc-editor.org/rfc/rfc9218.html

### RFC 9112: HTTP/1.1
- **URL**: https://datatracker.ietf.org/doc/html/rfc9112

---

## Benchmark References

### TechEmpower Framework Benchmarks Round 23 (Feb 2025)

- **URL**: https://www.techempower.com/benchmarks/
- **Blog**: https://www.techempower.com/blog/2025/03/17/framework-benchmarks-round-23/
- New hardware: 3-4x performance improvements across the board.
- Top rankings (composite): C#/ASP.NET (36.3x), Go/Fiber (20.1x), Rust/Actix (19.1x), Java/Spring (14.5x).

### Zig Web Framework Benchmarks

- **URL**: https://ziggit.dev/t/benchmarking-zig-web-frameworks/12683
- zzz > zap > http.zig in throughput, zzz using dramatically less memory.

### Key Benchmark Numbers Summary

| Implementation | Language | req/s | Notes |
|---|---|---|---|
| hyper | Rust | ~787,000 | 310us avg latency |
| H2O (HTTPS) | C | ~338,000 | c3.8xlarge, AES128-GCM |
| llhttp | C (generated) | ~3,584,000 | Parser only, not full server |
| picohttpparser (AVX2) | C | ~7,000,000 | Parser only, bench.c |
| fasthttp | Go | ~200,000 | Production (VertaMedia) |
| http.zig | Zig | ~140,000 | Apple M2, basic request |
| Zap | Zig | ~118,000 | Apple M1 Pro |

Note: These numbers are not directly comparable -- different hardware, workloads, and measurement methodologies. Parser-only benchmarks (llhttp, picohttpparser) measure different things than full server benchmarks.


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-ab929bbec1b8569cd.jsonl`
