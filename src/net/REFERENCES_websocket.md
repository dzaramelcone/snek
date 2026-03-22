# WebSocket Implementation Reference

State-of-the-art survey of WebSocket implementations across high-performance systems
languages. Last updated: 2026-03-21.

---

## Table of Contents

1. [Implementation Survey](#implementation-survey)
2. [Frame Parsing Optimization](#frame-parsing-optimization)
3. [Masking/Unmasking Optimization](#maskingunmasking-optimization)
4. [Per-Message Compression (RFC 7692)](#per-message-compression-rfc-7692)
5. [Backpressure Handling](#backpressure-handling)
6. [Connection Scaling](#connection-scaling)
7. [WebSocket over HTTP/2 (RFC 8441)](#websocket-over-http2-rfc-8441)
8. [Autobahn TestSuite](#autobahn-testsuite)
9. [Applicable Research & Papers](#applicable-research--papers)

---

## Implementation Survey

### 1. uWebSockets (C++)

- **URL**: https://github.com/uNetworking/uWebSockets
- **Language**: C++ (90%), C (7%), built on uSockets
- **License**: Apache-2.0

#### Architecture

uWebSockets is the acknowledged benchmark king. It is a layered system:

- **uSockets** (C): Provides eventing (epoll/kqueue/io_uring/libuv/ASIO/GCD),
  networking (TCP), and cryptography (OpenSSL/BoringSSL/WolfSSL) as three
  composable layers. Compile-time flags select backends.
- **uWebSockets** (C++): HTTP and WebSocket protocol on top of uSockets.
- **uWebSockets.js**: V8 native addon exposing the C++ core to Node.js. This is
  the core of Bun's HTTP/WebSocket server.

Threading model: one event loop per thread, shared listening port via
SO_REUSEPORT. Scales linearly with cores.

#### Key Design Decisions

- **Compile-time polymorphism**: Event loop backend, TLS provider, and transport
  all selected at compile time via template parameters. Zero runtime dispatch.
- **Imprecise unmasking**: The `unmaskImprecise8/4` functions intentionally write
  past buffer boundaries (within safe margins) to avoid branch overhead. This
  trades strict memory bounds for throughput.
- **Spill buffer**: A 14-byte stack-allocated `spill[]` array handles frame
  boundaries without heap allocation. Partial frames are stored across read
  cycles.
- **Template-based XOR unrolling**: `UnrolledXor<N>` enables compiler
  auto-vectorization without explicit SIMD intrinsics.
- **SIMD UTF-8 validation**: Optional `simdutf` integration; fallback claims 40%
  faster than simdutf with `g++ -mavx` through hand-tuned 16-byte chunk
  validation.
- **Cork batching**: `cork()` defers syscalls, batching multiple writes into a
  single send.
- **Direct socket write for large messages**: Messages >= 16KB that are
  uncompressed, non-SSL, and have no subscribers bypass the buffer and write
  directly to the socket.

#### Backpressure

Three-state `SendStatus` enum: `SUCCESS`, `BACKPRESSURE`, `DROPPED`.
Configurable `maxBackpressure` threshold. When exceeded:
- `closeOnBackpressureLimit` can shut down reads
- `droppedHandler` callback fires for dropped messages
- `getBufferedAmount()` exposes current backpressure level

#### Pub/Sub

Built-in topic tree with subscriber management. `publish()` excludes the
publishing socket. Subscriber message queues are drained via `topicTree->drain()`
before regular sends to maintain ordering.

#### Benchmark Claims

- Achieves ~98% of theoretical maximum for user-space Linux processes.
- 12x faster than Node.js (making Node.js unsuitable as a load tester).
- TLS 1.3 encrypted messaging faster than most alternatives' cleartext.
- ~60% performance retention with TLS enabled.
- 100k secure WebSocket connections from a fanless Raspberry Pi 4.
- 10x Socket.IO performance (100k secure WebSocket benchmark).

#### Production Exposure

Powers "many of the biggest crypto exchanges in the world, handling trade volumes
of multiple billions of USD every day." Core component of the Bun runtime.

#### Autobahn Compliance

Perfect Autobahn|Testsuite score maintained continuously since 2016.

#### Security

~95% daily fuzzing coverage via Google's OSS-Fuzz. LGTM A+ rating, zero CodeQL
alerts.

---

### 2. fastwebsockets (Rust)

- **URL**: https://github.com/denoland/fastwebsockets
- **Language**: Rust (85%), C (9.5%)
- **License**: MIT
- **Stars**: ~1.1k, ~595 dependents

#### Architecture

Deno's WebSocket implementation. Provides two abstraction levels:

1. **Raw frame parser**: Delivers individual frames without reassembly, giving
   full control to the caller.
2. **FragmentCollector**: Wraps the raw parser to transparently concatenate
   fragmented messages.

Built on hyper for HTTP upgrade handling. First-class axum integration via
optional features (`upgrade`, `with_axum`).

#### Key Design Decisions

- **Default raw frames**: Unlike tungstenite which auto-concatenates,
  fastwebsockets delivers raw frames by default. Reduces unnecessary copying
  when frame-level control is needed.
- **Payload ownership model**: `Payload` enum with four variants:
  `BorrowedMut(&mut [u8])`, `Borrowed(&[u8])`, `Owned(Vec<u8>)`,
  `Bytes(BytesMut)`. Lazy conversion from borrowed to owned only when mutation
  is required.
- **Vectored I/O**: `writev()` uses `write_vectored()` to send header + payload
  in a single syscall.
- **Stack-allocated headers**: `MAX_HEAD_SIZE = 16` bytes on the stack, no heap
  allocation for frame headers.
- **Optional SIMD UTF-8**: Via `simdutf8` feature flag.
- **Compiler auto-vectorization**: Explicit SSE2 SIMD masking code exists but is
  commented out. The developer notes "compiler does a good job at
  auto-vectorizing `unmask_fallback` with `-C target-cpu=native`."

#### Masking Implementation

Active code uses `unmask_fallback()`: aligns to u32 boundaries via
`align_to_mut::<u32>()`, XORs in 4-byte words, handles endianness via mask
rotation. Byte-by-byte fallback for prefix/suffix.

Disabled SSE2 code used `_mm_xor_si128` / `_mm_loadu_si128` with runtime feature
detection via `AtomicPtr`. No AVX2 or NEON implementations.

#### Autobahn Compliance

Passes the Autobahn|TestSuite. Continuous fuzzing with LLVM libfuzzer.

#### Compression

permessage-deflate is **not supported**.

#### Production Exposure

Core WebSocket implementation in Deno runtime.

---

### 3. tungstenite / tokio-tungstenite (Rust)

- **URL**: https://github.com/snapview/tungstenite-rs
- **URL**: https://github.com/tokio-rs/tokio-tungstenite (404 as of writing, possibly moved)
- **Language**: Rust
- **License**: MIT / Apache-2.0
- **Stars**: ~2.3k

#### Architecture

Synchronous, stream-based WebSocket library implementing RFC 6455. Designed as
"a barebone to build reliable modern networking applications." The async variant
(tokio-tungstenite) wraps it for the tokio ecosystem.

Used by axum via `WebSocketStream<TokioIo<hyper::upgrade::Upgraded>>`.

#### Key Design Decisions

- **Synchronous core**: Mirrors `TcpStream` API. Integrates with third-party
  event loops (MIO, etc.).
- **Automatic fragment concatenation**: Unlike fastwebsockets, tungstenite
  automatically reassembles fragmented messages.
- **Multiple TLS backends**: native-tls, native-tls-vendored,
  rustls-tls-native-roots, rustls-tls-webpki-roots. None enabled by default.

#### Masking Implementation

`apply_mask_fast32`: Aligns buffer to u32 boundaries via unsafe
`align_to_mut::<u32>()`. XORs in 4-byte words with endianness-aware mask
rotation. Fallback is byte-by-byte. No SIMD.

#### Autobahn Compliance

Passes the Autobahn Test Suite.

#### Compression

**No permessage-deflate support**. PRs welcome.

#### Axum Integration (via tokio-tungstenite)

Axum's `WebSocketUpgrade` extractor supports both HTTP/1.1 (101 Switching
Protocols) and HTTP/2+ (CONNECT with `:protocol = websocket`). Configuration
includes `read_buffer_size` (128 KiB default), `write_buffer_size` (128 KiB),
`max_write_buffer_size` (unlimited), `max_message_size` (64 MB),
`max_frame_size` (16 MB). Implements `Stream` + `Sink` traits.

---

### 4. gorilla/websocket (Go)

- **URL**: https://github.com/gorilla/websocket
- **Language**: Go
- **License**: BSD-3-Clause
- **Stars**: ~24.6k, ~192k dependents

#### Architecture

The standard Go WebSocket library. Single-package, pure Go implementation of
RFC 6455.

#### Key Design Decisions

- **Prepared messages**: `PreparedMessage` pre-computes WebSocket frames for
  broadcast scenarios, amortizing framing cost across recipients.
- **Configurable buffer sizes**: User-controlled read/write buffer allocation.
- **Compression**: Full permessage-deflate (RFC 7692) support via dedicated
  `compression.go`.

#### Masking Implementation

Three-phase word-size optimization:
1. Small buffers (< 2*wordSize): byte-by-byte.
2. Alignment phase: byte-by-byte until word-aligned.
3. Bulk phase: word-aligned `uintptr` XOR via unsafe pointer casting.
4. Remainder: byte-by-byte.

Uses `unsafe` package for pointer arithmetic. No SIMD. Build-excluded from App
Engine (`!appengine` build tag) where unsafe is unavailable.

#### Autobahn Compliance

Passes the Autobahn Test Suite server tests.

#### Production Exposure

~192k dependents. The de facto Go WebSocket library for years. Stable API.

---

### 5. coder/websocket (Go) (formerly nhooyr/websocket)

- **URL**: https://github.com/coder/websocket
- **Language**: Go
- **License**: ISC
- **Stars**: ~8k+

#### Architecture

Modern, minimal, idiomatic Go WebSocket library. Zero external dependencies.
Now maintained by Coder (the company behind code-server).

#### Key Design Decisions

- **First-class context.Context**: All operations are context-aware, unlike
  gorilla's callback-based approach.
- **Concurrent writes**: Safe without external synchronization.
- **Uses net/http.Client for dialing**: Enables future HTTP/2 support, avoids
  duplicating http.Client features.
- **Proper close handshake**: Addresses gorilla's incomplete close semantics.
- **Wasm support**: Compiles to WebAssembly via `ws_js.go`.
- **net.Conn wrapper**: For legacy code migration.

#### Masking Implementation

- Pure Go: 1.75x faster than gorilla/websocket.
- Assembly (amd64): SSE2-based SIMD implementation in `mask_amd64.s`:
  - Size-based branching at 15, 63, 128 byte thresholds.
  - Alignment loop with `ROLL $24, SI` for mask key rotation.
  - SSE2 loop: `PUNPCKLQDQ` to broadcast key, `PXOR` on 4x128-bit (64 bytes)
    per iteration.
  - No AVX2 (SSE2-only for broad compatibility).
  - Remainder handling at 32/16/8/4/2/1 byte granularity.
- arm64 assembly also exists (not yet complete per roadmap).

#### Compression

Full RFC 7692 permessage-deflate support, including context takeover
(gorilla only supports no-context-takeover mode).

#### Autobahn Compliance

Fully passes the Autobahn Test Suite.

#### Zero-alloc I/O

Advertises zero-allocation reads and writes with transparent message buffer
reuse.

---

### 6. gobwas/ws (Go)

- **URL**: https://github.com/gobwas/ws
- **Language**: Go
- **License**: MIT
- **Stars**: ~6.4k

#### Architecture

Low-level, zero-copy WebSocket library for Go. Designed for high-connection-count
servers where per-connection memory matters.

#### Key Design Decisions

- **Zero-copy upgrade**: HTTP header processing via registered callbacks whose
  arguments are valid only within the callback scope. No intermediate string
  allocations.
- **No prescribed I/O pattern**: Exposes `ReadHeader()`, `ReadFrame()`,
  `WriteFrame()` for full control. Users manage their own buffers and pools.
- **In-place unmasking**: `UnmaskFrameInPlace()` modifies data directly without
  allocation.
- **Separate packages**: `ws` (core framing), `wsutil` (high-level helpers),
  `wsflate` (compression).

#### Compression

`wsflate` package provides negotiable permessage-deflate (RFC 7692) via
`compress/flate`.

#### Autobahn Compliance

Passes the Autobahn TestSuite. ~78% code coverage.

#### Connection Scaling

Designed for the 1M-connections use case. The `eranyanay/1m-go-websockets`
project used gobwas/ws to achieve 1 million WebSocket connections with < 1 GB
RAM (~1 KB/connection) by:
- Using gobwas's zero-copy upgrade (no goroutine-per-connection for upgrades).
- External epoll integration to avoid goroutine-per-connection for reads.
- OS-level tuning of file descriptor limits.

---

### 7. websocket.zig (karlseguin)

- **URL**: https://github.com/karlseguin/websocket.zig
- **Language**: Zig (targets 0.15.1)
- **License**: MIT
- **Stars**: ~480

#### Architecture

Handler-based WebSocket server for Zig. Applications implement a struct with
`init()`, `clientMessage()`, `close()`, etc.

#### Key Design Decisions

- **O(1) framing**: Framing operations avoid looping through message data.
- **Compile-time pre-framed messages**: `websocket.frameText()` /
  `websocket.frameBin()` produce pre-framed payloads at comptime.
- **Thread-local allocator buffers**: Faster than general-purpose allocators.
- **Per-connection message serialization**: Only one message processed
  concurrently per connection, but concurrent writes on `*websocket.Conn` are
  safe.
- **Configurable thread pool**: Default 4 worker threads with backpressure
  (500 pending request limit).
- **Buffer pool hierarchy**: Small (2 KB default) and large buffer pools with
  dynamic allocation fallback.

#### Compression

permessage-deflate supported (disabled by default). Configurable write threshold
(512 B recommended).

#### Connection Scaling

Configurable max message size (64 KB default), handshake timeout (10 s default),
worker thread count (platform-dependent multi-worker on Linux/Mac/BSD).

#### Autobahn Compliance

Autobahn integration directory present in repository. Implements RFC 6455 with
proper close code/reason support.

#### Limitations

- No built-in UTF-8 validation for text messages.
- Response header total length capped at ~1024 characters.
- Windows: no Unix socket support.

---

### 8. ws (Node.js)

- **URL**: https://github.com/websockets/ws
- **Language**: JavaScript (Node.js)
- **License**: MIT
- **Stars**: ~22.7k

#### Architecture

The standard high-performance Node.js WebSocket library. Client + server.

#### Key Design Decisions

- **Optional native masking**: `bufferutil` npm package provides C++ bindings for
  XOR masking. 8 KB random pool (lazily initialized via `randomFillSync()`) for
  mask key generation.
- **Cork optimization**: `socket.cork()` / `uncork()` batches header + payload
  writes.
- **State machine sender**: Three states (DEFAULT, DEFLATING, GET_BLOB_DATA)
  with operation queuing during compression.

#### Compression

Full permessage-deflate (RFC 7692). **Disabled by default on servers** because
Node.js on Linux suffers "catastrophic memory fragmentation" under high-concurrency
compression. Configurable: `zlibDeflateOptions`, `zlibInflateOptions`,
`concurrencyLimit`, `threshold` (minimum size to compress), context takeover
toggles.

#### Backpressure

Tracks `_bufferedBytes`. Operations enqueued during DEFLATING state. Pending
callbacks receive errors on socket close.

#### Autobahn Compliance

Passes the Autobahn Test Suite for both clients and servers.

---

## Frame Parsing Optimization

### State Machine Design (uWebSockets pattern)

The canonical high-performance approach:

1. **Incremental parsing**: Maintain parser state across read callbacks. The
   uWebSockets `WebSocketState<isServer>` tracks `remainingBytes`,
   `spillLength`, `mask[4]`, and `opStack`.

2. **Spill buffer**: A small stack-allocated buffer (14 bytes in uWebSockets)
   stores partial frame headers across read boundaries. This avoids heap
   allocation for the common case of frame headers split across TCP segments.

3. **Three-tier length decoding**:
   - Compact: < 126 bytes, 2-byte header
   - Medium: 126-65535 bytes, 4-byte header
   - Extended: > 65535 bytes, 10-byte header

4. **Endianness handling**: `cond_byte_swap<T>()` for portable multi-byte integer
   extraction. Use `memcpy()` for unaligned access (not pointer casting) to avoid
   UB.

5. **Protocol validation**:
   - Opcode range: 0-2 (data), 8-10 (control), 3-7 reserved
   - Control frames: FIN must be 1, payload <= 125 bytes
   - Close codes: 1000-4999 valid, with reserved exclusions
   - RSV bits: only RSV1 allowed (for compression), RSV2/3 must be 0

### Zero-Copy Techniques

| Technique | Used By | Description |
|-----------|---------|-------------|
| Callback-based payload delivery | uWebSockets | Pass pointers to in-place unmasked data |
| Payload enum with borrowing | fastwebsockets | `BorrowedMut` / `Borrowed` / `Owned` / `Bytes` |
| In-place unmasking | All | XOR mask applied to received buffer directly |
| Pre-framed messages | websocket.zig, gorilla | Compute frame header at compile/init time |
| Zero-copy upgrade | gobwas/ws | Header callbacks with borrow-scoped arguments |
| Direct socket write | uWebSockets | Large uncompressed messages bypass buffer |
| Vectored I/O (writev) | fastwebsockets | Header + payload in single syscall |

---

## Masking/Unmasking Optimization

WebSocket clients must mask all frames (RFC 6455 Section 5.3). Servers must
unmask. The mask is a 4-byte XOR key applied cyclically.

### Optimization Tiers

#### Tier 0: Byte-by-byte (baseline)
```
for (i, byte) in buf.iter_mut().enumerate() {
    *byte ^= mask[i & 3];
}
```

#### Tier 1: Word-size XOR (32-bit or 64-bit)

Used by: gorilla/websocket, tungstenite, fastwebsockets, gobwas/ws.

1. Handle unaligned prefix bytes individually.
2. Construct word-sized mask (e.g., duplicate 4-byte mask into 8-byte for u64).
3. Rotate mask to account for prefix offset (endianness-aware).
4. XOR aligned words in a loop.
5. Handle remainder bytes individually.

Key detail: mask rotation direction depends on endianness.
- Little-endian: `rotate_right(8 * prefix_len)`
- Big-endian: `rotate_left(8 * prefix_len)`

#### Tier 2: Compiler auto-vectorization

Used by: fastwebsockets (primary strategy).

Write the word-size loop and compile with `-C target-cpu=native`. LLVM/GCC will
often auto-vectorize to SSE2/AVX2/NEON without explicit intrinsics.

#### Tier 3: Explicit SIMD

Used by: coder/websocket (amd64 assembly), uWebSockets (template unrolling).

**coder/websocket amd64 assembly**:
- SSE2: `PUNPCKLQDQ` broadcasts 64-bit key to 128-bit XMM register.
- Processes 64 bytes/iteration (4x `PXOR` on XMM registers).
- Size thresholds: < 15 bytes (scalar), < 63 (word), < 128 (partial SIMD),
  >= 128 (full SSE2 loop).
- No AVX2 (compatibility choice).

**uWebSockets template unrolling**:
- `UnrolledXor<N>` enables compile-time loop unrolling.
- Compiler generates vectorized code from the unrolled template.
- "Imprecise" variants intentionally overwrite past buffer end (within safe
  margins) for branch-free inner loops.

#### Tier 4: Unsafe tricks

**uWebSockets imprecise unmasking**: Out-of-bounds writes within pre-allocated
margins. Eliminates bounds-check branches in the hot loop. Requires careful
buffer allocation with padding.

### Performance Hierarchy (approximate)

1. uWebSockets imprecise + template unrolling (best throughput)
2. coder/websocket SSE2 assembly (3x gorilla claim)
3. coder/websocket pure Go (1.75x gorilla)
4. gorilla/websocket word-size unsafe (baseline for Go)
5. tungstenite u32 align_to_mut (baseline for Rust)
6. Byte-by-byte (worst)

---

## Per-Message Compression (RFC 7692)

### How It Works

1. Compress message payload with DEFLATE (RFC 1951).
2. Strip trailing 4 bytes (`0x00 0x00 0xff 0xff`).
3. Set RSV1 bit on first frame.
4. Receiver appends the 4 bytes back and decompresses.

### Negotiation Parameters

| Parameter | Values | Effect |
|-----------|--------|--------|
| `server_no_context_takeover` | (none) | Server resets LZ77 window each message |
| `client_no_context_takeover` | (none) | Client resets LZ77 window each message |
| `server_max_window_bits` | 8-15 | Server compression window = 2^N bytes |
| `client_max_window_bits` | 8-15 or absent | Client compression window = 2^N bytes |

### Context Takeover Trade-offs

| Mode | Compression Ratio | Memory | CPU |
|------|-------------------|--------|-----|
| With context takeover | Better (LZ77 history reused) | Higher (retain window per connection) | Lower (smaller output) |
| No context takeover | Worse | Lower (reset per message) | Higher (cold starts) |

Example: "Hello" compresses to 7 bytes. Same message again with context takeover:
5 bytes. Without: 7 bytes again.

### Implementation Status

| Library | permessage-deflate | Context Takeover |
|---------|-------------------|------------------|
| uWebSockets | Yes | Yes |
| gorilla/websocket | Yes | No-context-takeover only |
| coder/websocket | Yes | Full (both modes) |
| gobwas/ws (wsflate) | Yes | Yes |
| ws (Node.js) | Yes (disabled by default) | Configurable |
| websocket.zig | Yes (disabled by default) | Unknown |
| tungstenite | **No** | N/A |
| fastwebsockets | **No** | N/A |

### Memory Fragmentation Warning

Node.js `ws` documents that permessage-deflate causes "catastrophic memory
fragmentation" on Linux under high concurrency. This is a zlib/V8 interaction
issue. The recommendation is to benchmark with production workloads before
enabling.

### CRIME Attack

Compressing secrets over encrypted channels enables the CRIME side-channel
attack. Implementers must be aware when combining permessage-deflate with
TLS + user-controlled input.

---

## Backpressure Handling

### Patterns Across Implementations

#### uWebSockets: Explicit Three-State Return

```
enum SendStatus { BACKPRESSURE, SUCCESS, DROPPED };
```

- `getBufferedAmount()` exposes current backpressure.
- `maxBackpressure` configurable threshold.
- `droppedHandler` callback on message drop.
- `closeOnBackpressureLimit` option for automatic shutdown.
- Cork batching reduces syscall overhead.

#### ws (Node.js): State Machine + Queue

- Three sender states: DEFAULT, DEFLATING, GET_BLOB_DATA.
- Operations enqueued during non-DEFAULT states.
- `_bufferedBytes` tracks pending data.
- Pending callbacks error-invoked on close.

#### gorilla/websocket: Writer-Based

- `NextWriter()` returns an `io.WriteCloser` for a single message.
- Application responsible for checking write errors and implementing backpressure.
- `PreparedMessage` reduces per-send overhead for broadcasts.

#### coder/websocket: Concurrent Write Safety

- Concurrent writes safe without synchronization.
- Uses context.Context for deadline/cancellation propagation.

#### Axum/tokio-tungstenite: Sink Trait

- `max_write_buffer_size` configurable (unlimited by default).
- Implements `Sink<Message>` trait from futures crate.
- Write buffer accumulates; exceeding max triggers error.

#### General Principles

1. **Always expose buffered amount**: Callers need visibility into send queue.
2. **Configurable limits**: Drop vs. close vs. block are all valid strategies.
3. **Cork/batch writes**: Reduce syscalls by batching frame header + payload.
4. **Separate slow consumers**: Per-connection buffers prevent one slow consumer
   from blocking others.

---

## Connection Scaling

### The 1M Connection Challenge

Achieving 1 million concurrent WebSocket connections requires attention at
every layer:

#### OS Tuning

| Parameter | Default | Required |
|-----------|---------|----------|
| `ulimit -n` (file descriptors) | 256-1024 | 1,048,576+ |
| `net.core.somaxconn` | 128 | 65535 |
| `net.ipv4.ip_local_port_range` | 32768-60999 | 1024-65535 |
| `net.netfilter.nf_conntrack_max` | 65536 | 1048576+ |
| `fs.file-max` | varies | 2097152+ |

#### Memory Per Connection

| Library | Approximate Per-Connection | Technique |
|---------|---------------------------|-----------|
| gobwas/ws | ~1 KB | Zero-copy upgrade, no goroutine per conn |
| gorilla/websocket | ~4-8 KB | Configurable read/write buffers |
| uWebSockets | Sub-KB (claimed) | C++ with minimal overhead |
| ws (Node.js) | ~2-4 KB | V8 object overhead |

#### Ephemeral Port Exhaustion

The 4-tuple problem: (src_ip, src_port, dst_ip, dst_port). Load balancer to
backend connections share dst_ip:dst_port, so only 65,536 connections per
load balancer IP. Solutions:
- Multiple load balancer IPs
- Direct client-to-server connections
- SO_REUSEPORT

#### Architecture Patterns

1. **Goroutine-per-connection** (standard Go): Simple but expensive at scale.
   Each goroutine ~2-8 KB stack.
2. **epoll/kqueue multiplexing**: Used by gobwas/ws approach. Application-level
   event loop avoids goroutine overhead. Achieves 1M connections < 1 GB.
3. **Thread-per-core** (uWebSockets): One event loop per thread. SO_REUSEPORT
   for load distribution. Minimal per-connection state.
4. **io_uring** (Linux 5.1+): Completion-based I/O. uSockets supports it as
   a backend. Reduces syscall overhead but requires kernel buffer ownership
   (extra copy for caller-managed buffers).

#### Reconnection Storms

When a server restarts, all clients reconnect simultaneously. Mitigations:
- **Client**: Exponential backoff with jitter (1, 2, 4, 8, 16 seconds).
- **Server**: Rate limiting at TCP (load balancer) and application levels.
- **Auth**: JWT tokens avoid session backend load spikes.
- **Smart batching**: Collect reconnection requests into batches before
  forwarding to PUB/SUB broker.

#### Distributed Architecture

For true millions-of-connections scale, single-process is insufficient.
Pattern: WebSocket servers connect to a central PUB/SUB broker (Redis
recommended for simplicity). Clients subscribe to topics routed through
the broker. Messages delivered only to servers with interested subscribers.

---

## WebSocket over HTTP/2 (RFC 8441)

### How It Works

Instead of HTTP/1.1's `Upgrade` header mechanism (101 Switching Protocols),
RFC 8441 tunnels WebSocket connections through HTTP/2 streams using an extended
CONNECT method.

### Key Differences from HTTP/1.1

| Aspect | HTTP/1.1 | HTTP/2 |
|--------|----------|--------|
| Method | GET | CONNECT |
| Upgrade mechanism | `Upgrade: websocket` header | `:protocol = websocket` pseudo-header |
| Response | 101 Switching Protocols | 2XX status |
| Security headers | Sec-WebSocket-Key/Accept required | Not required |
| Connection sharing | Dedicated TCP connection | Multiplexed on shared connection |
| Flow control | TCP-level only | HTTP/2 stream-level + TCP |

### Benefits

- **Connection multiplexing**: Multiple WebSocket connections share one TCP
  connection alongside regular HTTP/2 traffic.
- **Stream priorities**: HTTP/2 native priority mechanisms apply.
- **Flow control**: Per-stream flow control via HTTP/2's WINDOW_UPDATE frames.
- **Clean shutdown**: RST_STREAM with CANCEL replaces abrupt TCP closes.

### Negotiation

Server advertises support via `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1`. Client
sends CONNECT request with `:protocol = websocket`, `:scheme`, `:path`,
`:authority`. Retained headers: Origin, Sec-WebSocket-Version,
Sec-WebSocket-Protocol, Sec-WebSocket-Extensions.

### Implementation Status

| Library | HTTP/2 WebSocket | Notes |
|---------|-----------------|-------|
| Axum (tokio-tungstenite) | Yes | Detects HTTP version, uses CONNECT for >= HTTP/2 |
| coder/websocket | Planned (roadmap item #4) | Architecture ready via http.Client |
| uWebSockets | No | HTTP/1.1 only |
| gorilla/websocket | No | |
| fastwebsockets | No | Built on hyper HTTP/1.1 upgrade |
| ws (Node.js) | No | HTTP/1.1 only |

---

## Autobahn TestSuite

### Overview

The Autobahn|TestSuite is the industry-standard WebSocket protocol compliance
validator, maintained by Crossbar.io. Contains **over 500 test cases** organized
by category.

### Test Categories

| Category | Tests |
|----------|-------|
| Framing | Frame construction, header parsing, opcode handling |
| Ping/Pong | Control frame mechanics, payload limits |
| Reserved bits | RSV1/2/3 handling, extension negotiation |
| Opcodes | Valid (0-2, 8-10) and reserved (3-7) opcode behavior |
| Fragmentation | Message splitting, interleaved control frames, continuation |
| UTF-8 | Text message encoding validation, incremental validation |
| Close handling | Close codes, reason strings, close handshake sequences |
| Limits | Maximum message/frame sizes, resource exhaustion |
| Performance | Throughput under various payload sizes |
| Compression | permessage-deflate (RFC 7692) extension |
| Opening handshake | (Under development) |

### Compliance Summary

| Library | Autobahn Status |
|---------|----------------|
| uWebSockets | Perfect score since 2016 |
| gorilla/websocket | Pass (server tests) |
| coder/websocket | Full pass |
| gobwas/ws | Pass |
| tungstenite | Pass |
| fastwebsockets | Pass |
| ws (Node.js) | Pass (client + server) |
| websocket.zig | Integration present, status unconfirmed |

### Running It

Two modes:
- **Fuzzing server**: Tests client implementations with edge cases.
- **Fuzzing client**: Tests server implementations by connecting with varied
  frame structures.

Reports can exclude specific test ranges (e.g., compression tests for
implementations without permessage-deflate).

---

## Applicable Research & Papers

### RFC Standards

| RFC | Title | Relevance |
|-----|-------|-----------|
| RFC 6455 | The WebSocket Protocol | Base specification |
| RFC 7692 | Compression Extensions for WebSocket | permessage-deflate |
| RFC 8441 | Bootstrapping WebSockets with HTTP/2 | WebSocket over HTTP/2 |
| RFC 1951 | DEFLATE Compressed Data Format | Underlying compression |
| RFC 1979 | PPP Deflate Protocol | Byte-boundary alignment used by permessage-deflate |

### Scaling & Architecture

- **C10K Problem** (Dan Kegel, 1999): Foundation for event-driven server design.
  epoll/kqueue as solutions to poll/select scaling limitations.
- **C10M Problem** (Robert Graham): Scaling to 10M connections. Kernel bypass
  (DPDK, netmap), user-space TCP stacks, zero-copy I/O.
- **eranyanay/1m-go-websockets** (GopherCon Israel 2019): Case study achieving
  1M Go WebSocket connections < 1 GB RAM using gobwas/ws + epoll.
- **Centrifugal blog** (Alexander Emelin): Comprehensive guide to scaling
  WebSocket infrastructure with Go, Redis PUB/SUB, and smart batching.

### SIMD & Data Processing

- **simdutf** library: SIMD-accelerated UTF-8 validation. Used optionally by
  uWebSockets and fastwebsockets.
- **Daniel Lemire's work**: Extensive research on SIMD-accelerated parsing and
  validation, foundational to simdutf.

### Security

- **CRIME attack** (Rizzo & Duong, 2012): Compression side-channel against
  TLS. Directly relevant to permessage-deflate over WSS.

### io_uring

- **io_uring** (Jens Axboe, Linux 5.1): Completion-based I/O for Linux.
  Reduces syscall overhead. Supported by uSockets as event loop backend.
  Key constraint: kernel owns the buffer during I/O, requiring copy for
  caller-managed buffers unless using provided-buffer mode.

---

## Summary: Design Decision Matrix

| Decision | Low-Latency Choice | High-Connection Choice | Simplicity Choice |
|----------|-------------------|----------------------|-------------------|
| Event loop | epoll/kqueue/io_uring | epoll + application multiplexing | libuv / Go runtime |
| Threading | Thread-per-core | Single thread + epoll | Goroutine-per-conn |
| Masking | SIMD / template unrolling | Word-size XOR (sufficient) | Byte-by-byte |
| Compression | Disable (latency cost) | No-context-takeover (memory) | Context takeover (ratio) |
| Buffering | Zero-copy + writev | Minimal per-conn buffers | Standard library |
| Backpressure | Drop + callback | Close slow consumers | Block (simple) |
| Upgrade | Zero-copy headers | Zero-copy headers | net/http integration |
| Frame parsing | Spill buffer + state machine | Same | Auto-fragment-collect |


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-aee454d1b7f1363f7.jsonl`
