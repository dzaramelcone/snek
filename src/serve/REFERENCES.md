# File Serving, Streaming, and Multipart: State of the Art

Exhaustive reference on high-performance file serving, streaming responses, and multipart
handling across systems languages (C, Rust, Go, Zig) and production infrastructure (nginx, H2O).

Last updated: 2026-03-21

---

## Table of Contents

1. [Zero-Copy File Serving](#1-zero-copy-file-serving)
2. [io_uring Integration](#2-io_uring-integration)
3. [Multipart Form Parsing](#3-multipart-form-parsing)
4. [Streaming Response Patterns](#4-streaming-response-patterns)
5. [Range Requests (HTTP 206)](#5-range-requests-http-206)
6. [Large File Upload Handling](#6-large-file-upload-handling)
7. [Memory-Mapped File Serving](#7-memory-mapped-file-serving)
8. [Back-Pressure in Streaming](#8-back-pressure-in-streaming)
9. [Content-Type Detection](#9-content-type-detection)
10. [ETag Generation Strategies](#10-etag-generation-strategies)
11. [HTTP Parsers (SIMD-Accelerated)](#11-http-parsers-simd-accelerated)
12. [Zig File I/O and Sendfile](#12-zig-file-io-and-sendfile)
13. [Production Servers: Architecture Deep Dives](#13-production-servers-architecture-deep-dives)
14. [Kernel-Bypass and Advanced Networking](#14-kernel-bypass-and-advanced-networking)
15. [Research Papers](#15-research-papers)

---

## 1. Zero-Copy File Serving

### Syscall Evolution

| Mechanism | Copies | Syscalls | Notes |
|-----------|--------|----------|-------|
| `read()` + `write()` | 4 | 2 | Data: disk -> page cache -> user buf -> socket buf -> NIC |
| `mmap()` + `write()` | 3 | 2 | Eliminates one user-space copy; TLB overhead |
| `sendfile()` | 2 | 1 | Page cache -> socket buf -> NIC; no user-space touch |
| `splice()` | 2 | 1 | Uses pipe as intermediary; works between arbitrary FDs |
| `MSG_ZEROCOPY` | 1 | 1 | DMA directly from page cache; requires scatter-gather NIC |
| io_uring `SEND_ZC` | 1 | 0* | Async zero-copy; *amortized via SQ/CQ rings |

### sendfile(2)

- **Linux**: `sendfile(out_fd, in_fd, offset, count)` -- copies between FDs in-kernel
- **Constraint**: source must be mmappable (regular file), destination must be a socket
- **Go max chunk**: 4,194,304 bytes per call (hardcoded `maxSendfileSize`)
- **Nginx default chunk**: configurable via `sendfile_max_chunk`, prevents single large
  transfer from starving other connections
- Man page: https://man7.org/linux/man-pages/man2/sendfile.2.html

### splice(2)

- Moves data between an FD and a pipe without user-space copies
- `sendfile()` was originally re-implemented as a wrapper around `splice()` (Jens Axboe)
- Pipe buffer size: default 64KB (16 pages), expandable via `F_SETPIPE_SZ` up to
  `/proc/sys/fs/pipe-max-size` (default 1MB)
- Man page: https://man7.org/linux/man-pages/man2/splice.2.html

### MSG_ZEROCOPY (TCP send-side)

- Introduced August 2017; specify `MSG_ZEROCOPY` flag with `sendmsg()`
- Kernel builds `skb` referencing user-space data buffers directly
- TCP headers placed in separate kernel-memory buffer
- **Requires**: scatter-gather DMA support on NIC; falls back to copying otherwise
- **Completion**: async notifications via socket error queue (`recvmsg()` + `MSG_ERRQUEUE`)
- **Benchmark**: 30-40% throughput improvement for single flow on single CPU
- Blog (2026): https://blog.tohojo.dk/2026/02/the-inner-workings-of-tcp-zero-copy.html

### Go Standard Library (Automatic Zero-Copy)

- **URL**: https://go.dev/src/os/zero_copy_linux.go
- **Call chain**: `http.FileServer` -> `serveContent` -> `io.CopyN` -> `io.Copy` -> `sendFile`
- **Detection**: `io.Copy` checks if destination implements `ReaderFrom` interface
- **Fallback chain**: `splice()` first (Linux) -> `sendFile()` -> generic `read`/`write`
- **Key insight**: developers get zero-copy automatically without explicit opt-in
- Reference: https://www.sobyte.net/post/2022-07/go-zerocopy/
- Issue tracking splice for TCPConn: https://github.com/golang/go/issues/10948

### Rust Ecosystem

- **tower-http `ServeDir`**: reads files in 64KB chunks into user-space; no sendfile
  integration. https://docs.rs/tower-http/latest/tower_http/services/struct.ServeDir.html
- **tk-sendfile**: thread pool wrapper for sendfile with tokio.
  https://github.com/tailhook/tk-sendfile
- **actix-files `NamedFile`**: supports ETag, Last-Modified, Content-Disposition;
  reads via async file I/O (not sendfile). https://docs.rs/actix-files/latest/actix_files/
- **tarweb** (io_uring + kTLS + Rust): see io_uring section below

---

## 2. io_uring Integration

### Architecture

- Two ring buffers shared between user-space and kernel: Submission Queue (SQ) and
  Completion Queue (CQ)
- Operations submitted as SQEs, results returned as CQEs
- Single `io_uring_enter()` call can submit/reap many operations (batching)
- Eliminates per-operation syscall overhead when batching is effective

### Relevant Operations for File Serving

| Operation | Purpose |
|-----------|---------|
| `IORING_OP_SPLICE` | splice between FDs via pipe (sendfile emulation) |
| `IORING_OP_SEND_ZC` | Zero-copy send to socket |
| `IORING_OP_RECV` | Receive from socket |
| `IORING_OP_READ_FIXED` | Read into registered buffer |
| `IORING_OP_OPENAT` | Open file |
| `IORING_OP_STATX` | Stat file (for mtime, size) |
| `IORING_OP_CLOSE` | Close FD |

### Sendfile via io_uring (Splice Pattern)

The canonical pattern chains three operations with `IOSQE_IO_LINK`:
1. `SPLICE` file -> pipe write end
2. `SPLICE` pipe read end -> socket
3. Submit all in single `io_uring_enter()`

**Critical limitation**: `pipe2()` syscall still required to create the pipe; this is
the one syscall that cannot be done via io_uring (as of 2025).

**Performance gap**: splice-based approach underperforms epoll+sendfile by 10-25% due
to pipe buffer overhead. For 1MB files: epoll ~7.2k RPS vs io_uring ~6k RPS.
Reference: https://github.com/axboe/liburing/issues/536

### Registered Buffers and Fixed Files

- `io_uring_register_buffers()`: pre-register memory for DMA; eliminates per-I/O
  page mapping/unmapping overhead
- `io_uring_register_files()`: pre-register FDs; eliminates atomic refcount on each
  operation (significant for high IOPS)
- **Huge page support** (kernel 6.12+): registered huge pages used as larger DMA
  segments, reducing iteration overhead
- **Incremental consumption** (kernel 6.12+): large buffers partially consumed per
  receive, reducing buffer churn

### Linux 6.15: Zero-Copy Receive

- Network zero-copy receive via io_uring (Pavel Begunkov, David Wei)
- Configures page pool providing user pages to hardware RX queues
- Data DMA'd directly into user-space memory; kernel sends notification only
- **Benchmark**: single CPU core saturates 200Gbps link; 188 Gbit/s measured at
  netdev conference (single core, no HT, excluding soft-IRQ)
- Reference: https://www.phoronix.com/news/Linux-6.15-IO_uring

### io_uring vs epoll: Benchmark Summary

| Metric | epoll | io_uring | Notes |
|--------|-------|----------|-------|
| Echo 64B buf | 1,565K QPS | 506K QPS | io_uring 3x slower (single op) |
| Echo 16KB buf | 224K QPS | 183K QPS | Gap narrows with larger buffers |
| File serve 1MB | ~7.2k RPS | ~6k RPS | splice pipe overhead |
| Batched ops | slower | faster | io_uring wins when batching many ops |

Environment: Intel Xeon 8369B, 96 cores, 40Gb NIC, kernel 6.0.7.
Source: https://github.com/axboe/liburing/issues/536

### tarweb: Zero-Syscall HTTPS Server (Rust + io_uring + kTLS)

- **URL**: https://blog.habets.se/2025/04/io-uring-ktls-and-rust-for-zero-syscall-https-server.html
- **Language**: Rust
- **Architecture**: one thread per CPU core, NUMA-aware, no shared read-write state
- **kTLS**: kernel handles TLS after handshake; enables sendfile over TLS
- **Memory**: pre-allocated fixed chunks per connection; no runtime allocation
- **Descriptorless files**: uses `register_files` to avoid FD overhead
- **Safety concern**: buffers must outlive operations without borrow-checker protection
- **Benchmarks**: not yet published
- **Contributions**: PR #320 to tokio-rs/io-uring (setsockopt), PR #54 to rustls kTLS crate

### io_uring for DBMSs (Research Paper, Dec 2024)

- **URL**: https://arxiv.org/pdf/2512.04859
- **Key finding**: io_uring benefits are workload-dependent; requires fixed buffers to
  realize gains. Without fixed buffer registration, overhead can negate benefits.
- **Recommendation**: benchmark with actual workload before committing; gradual adoption
  over wholesale replacement

---

## 3. Multipart Form Parsing

### C

#### multipart-parser-c
- **URL**: https://github.com/iafonov/multipart-parser-c
- **Design**: callback-driven streaming parser
- **API**: `multipart_parser_init(boundary, &callbacks)` -> `multipart_parser_execute(buf, len)` -> `multipart_parser_free()`
- **Callbacks**: `on_header_field`, `on_header_value`, `on_part_data_begin`, `on_part_data`, `on_part_data_end`
- **Memory**: internal buffer never exceeds boundary size (~60-70 bytes)
- **Trade-off**: minimal allocation, works with arbitrary chunk sizes, C89 compatible
- **Inspiration**: node-formidable's parser, http-parser callback style
- **Production**: used as basis for many higher-level implementations

### Rust

#### multer (rwf2/multer)
- **URL**: https://github.com/rwf2/multer
- **Crate**: https://crates.io/crates/multer (v3.1.0 latest)
- **Design**: async streaming parser; accepts `Stream<Item = Result<Bytes>>` input
- **API**: `Multipart::new(stream, boundary)` -> `next_field().await` iteration
- **Integration**: framework-agnostic; used by Rocket, Axum via extractors
- **Security**: configurable field size limits to prevent DoS/memory exhaustion
- **Trade-off**: async-native but requires tokio runtime

#### mime-multipart
- **URL**: https://github.com/mikedilger/mime-multipart
- **Design**: streaming parser that writes file parts directly to disk
- **Trade-off**: avoids memory bloat for large files; disk I/O becomes bottleneck

#### multipart-stream-rs
- **URL**: https://github.com/scottlamb/multipart-stream-rs
- **Design**: bidirectional -- parses `multipart/x-mixed-replace` streams and serializes
- **Use case**: MJPEG streams, SSE-like patterns

### Go

#### mime/multipart (stdlib)
- **URL**: https://pkg.go.dev/mime/multipart
- **Design**: iterator-based `Reader` with `NextPart()` returning `Part` objects
- **Internal**: uses `bufio.Reader`; boundary matching via byte-slice comparison
- **Security limits** (hardened):
  - Max 10,000 headers per part
  - Max 10,000 total FileHeaders
  - Max 1,000 parts per form
  - Configurable via `GODEBUG=multipartmaxheaders=N` / `multipartmaxparts=N`
- **Trade-off**: robust security defaults; not the fastest parser but production-hardened

### Node.js (Reference Implementations)

#### busboy (@fastify/busboy)
- **URL**: https://github.com/fastify/busboy
- **Design**: event-based streaming; no temp files, no memory bloat
- **Performance**: @fastify/busboy 1.20ms for 1 large file; original busboy 3.01ms
- **Trade-off**: raw speed, low-level API

#### formidable
- **URL**: https://github.com/node-formidable/formidable
- **Performance**: ~900-2500 MB/s parsing throughput
- **Design**: higher-level API with temp file management
- **Production**: "the most used" multipart parser for Node.js

---

## 4. Streaming Response Patterns

### Chunked Transfer Encoding (HTTP/1.1)

- Each chunk: `<hex-size>\r\n<data>\r\n`; terminal chunk: `0\r\n\r\n`
- Used when `Content-Length` unknown at response start
- Trailers allowed after final chunk (for checksums, signatures)
- **Key advantage**: progressive rendering; client processes data as it arrives

### Server-Sent Events (SSE)

- MIME type: `text/event-stream`
- Format: `data: <payload>\n\n` (double newline terminates event)
- Named events: `event: <name>\ndata: <payload>\n\n`
- Reconnection: `retry: <ms>\n` sets client reconnect interval
- Last-Event-ID: client sends on reconnect for resumption
- **Limitation**: intermediary proxies may buffer the stream, breaking real-time delivery
- **HTTP/2 advantage**: multiplexed streams eliminate head-of-line blocking
- Reference: https://hpbn.co/server-sent-events-sse/

### Streaming JSON Patterns

- **NDJSON** (Newline Delimited JSON): one JSON object per line; `application/x-ndjson`
- **JSON Streaming**: concatenated JSON objects (no delimiter); parser must track depth
- **JSON Lines**: identical to NDJSON; `.jsonl` extension
- Used by: Elasticsearch bulk API, OpenAI streaming API, LLM token streaming

### HTTP/2 Flow Control

- Per-stream and per-connection flow control via `WINDOW_UPDATE` frames
- Default window: 65,535 bytes (configurable)
- Independent of TCP flow control (which operates at connection level)
- Critical for multiplexed streams: prevents one stream from starving others

---

## 5. Range Requests (HTTP 206)

### Protocol (RFC 7233)

- **Request**: `Range: bytes=0-999` (first 1000 bytes)
- **Response**: `206 Partial Content` with `Content-Range: bytes 0-999/8000`
- **Multiple ranges**: response `Content-Type: multipart/byteranges; boundary=...`
- **Invalid range**: `416 Range Not Satisfiable`
- **Conditional**: combine with `If-Range: <etag-or-date>` for safe resumption

### Single Range Response Headers

```
HTTP/1.1 206 Partial Content
Content-Range: bytes 0-999/8000
Content-Length: 1000
Content-Type: application/octet-stream
```

### Multi-Range Response Format

```
Content-Type: multipart/byteranges; boundary=THIS_STRING_SEPARATES

--THIS_STRING_SEPARATES
Content-Type: application/octet-stream
Content-Range: bytes 0-499/8000

[first range data]
--THIS_STRING_SEPARATES
Content-Type: application/octet-stream
Content-Range: bytes 1000-1499/8000

[second range data]
--THIS_STRING_SEPARATES--
```

### Implementation: nginx Range Filter

- **Source**: https://github.com/nginx/nginx/blob/master/src/http/modules/ngx_http_range_filter_module.c
- **Header filter** (`ngx_http_range_header_filter`): validates Range header, checks
  HTTP version, response status, content length; parses `bytes=` format
- **Body filter** (`ngx_http_range_body_filter`): adjusts buffer pointers for single-part
  ranges; generates MIME multipart boundary for multi-range
- **Design**: operates as output filter in nginx's filter chain; does not re-read file

### Implementation: actix-files (Rust)

- `HttpRange` struct parses `Range` header
- **Known issues**: missing `Content-Length` on 206 responses (regression); incorrect
  `Content-Encoding: identity` header
- Source: https://docs.rs/actix-files/latest/actix_files/struct.HttpRange.html

---

## 6. Large File Upload Handling

### TUS Protocol (Resumable Uploads)

- **URL**: https://tus.io/protocols/resumable-upload
- **Status**: de facto standard; IETF draft in progress (`draft-tus-httpbis-resumable-uploads-protocol`)
- **Core**: `HEAD` to check offset -> `PATCH` to resume from that offset
- **Extensions**: Creation, Expiration, Checksum, Termination, Concatenation
- **Adoption**: Cloudflare, Supabase, Vimeo, Transloadit

#### Reference Implementation: tusd (Go)
- **URL**: https://github.com/tus/tusd
- **Language**: Go
- **Storage backends**: local filesystem, S3, GCS, Azure Blob
- **Chunk sizes**: Cloudflare minimum 5MB, recommended 50MB for reliable connections

### Alternative: Direct Multipart Upload

- Split file client-side into chunks
- Upload each chunk as separate multipart request with sequence number
- Server reassembles; supports parallel upload of chunks
- **Trade-off**: simpler protocol but no standardized resumption

### Strategies for Server-Side Handling

1. **Stream to disk**: write chunks directly to temp file; rename on completion
2. **Stream to object store**: proxy chunks directly to S3/GCS (avoids local disk)
3. **Memory-mapped temp file**: mmap growing temp file for random-access assembly
4. **Pipe to processing**: for transcoding/compression, pipe upload stream directly
   to processor without intermediate storage

---

## 7. Memory-Mapped File Serving

### mmap vs sendfile Trade-offs

| Aspect | mmap | sendfile |
|--------|------|----------|
| Copies | 3 (first access); 2 (cached) | 2 |
| Setup cost | High (VMA creation, TLB flush) | Low (single syscall) |
| Random access | Yes | No (sequential only) |
| Page faults | Yes (can block) | No |
| Scalability | Limited (page fault cores cap) | Good |
| NVMe SSDs | Overhead visible | Overhead hidden |
| Hot files | Competitive (page cache) | Slightly better |
| Large files | TLB pressure | No TLB impact |

### When mmap Wins

- Repeated random access to the same file regions
- Files that fit comfortably in page cache and are accessed frequently
- When you need to process file content (not just forward it)

### When sendfile Wins

- Sequential file-to-socket transfer (the common case for HTTP serving)
- Large files that exceed available RAM
- High-concurrency scenarios (no TLB contention)

### Production Guidance

- **nginx**: uses sendfile by default; mmap not used for file serving
- **H2O**: uses pread/sendfile; offers async pre-read to avoid blocking on cache miss
- **Myth**: "mmap is always faster" -- false for file serving workloads.
  See: https://news.ycombinator.com/item?id=19806804
- **Benchmark requirement**: always benchmark for your specific access pattern

---

## 8. Back-Pressure in Streaming

### The Problem

Async frameworks accept unlimited connections by default. Without explicit limits,
10,000 concurrent connections competing for a 50-connection database pool causes
catastrophic queuing.

Reference: https://lucumr.pocoo.org/2020/1/1/async-pressure/

### TCP Flow Control (Built-in)

- Receiver advertises window size via ACKs
- When receive buffer full, receiver sends zero-window (`win 0`) ACK
- Sender pauses until window opens
- **Hidden from application layer** by socket APIs

### HTTP/2 Flow Control

- `WINDOW_UPDATE` frames control per-stream and per-connection flow
- Default window: 65,535 bytes
- Independent of TCP flow control
- Required because HTTP/2 multiplexes streams over single TCP connection

### Language-Specific Patterns

#### Rust
- **tower Service trait**: `poll_ready()` checks capacity before accepting request
- **Bounded channels**: tokio mpsc with capacity limit provides natural back-pressure
- **hyper**: respects TCP back-pressure through `poll_write`; body streams are lazy

#### Go
- **Goroutine per connection**: natural back-pressure via blocking writes
- **`io.Copy`**: blocks on slow reader automatically
- **Concern**: unbounded goroutine creation can exhaust memory

### nginx as Back-Pressure Proxy

nginx acts as a buffer between slow clients and fast upstreams:
- Reads upstream response quickly (fast connection)
- Buffers in memory/disk
- Drains to slow client at client's pace
- Frees upstream connection early
- Cost of holding nginx connection << cost of holding upstream process

### Design Patterns

1. **Semaphore-based**: acquire token before processing; return 503 with `Retry-After`
   when exhausted
2. **Readiness checks**: query service capacity before committing (tower pattern)
3. **Bounded queues**: fixed-size channel between producer/consumer stages
4. **Write polling**: only produce data when downstream is ready to consume

---

## 9. Content-Type Detection

### Approaches

| Method | Speed | Accuracy | Portability |
|--------|-------|----------|-------------|
| File extension | ~0ns | Low | Universal |
| Magic bytes (first N bytes) | ~1us | High | Universal |
| Full content hash | Slow | Perfect | Universal |
| `libmagic` / `file(1)` | ~10us | Very high | Unix |

### Magic Bytes: How It Works

Files have characteristic byte signatures in their headers:
- JPEG: `FF D8 FF E0` (first 4 bytes)
- PNG: `89 50 4E 47 0D 0A 1A 0A` (8 bytes)
- PDF: `25 50 44 46` (`%PDF`)
- ZIP: `50 4B 03 04` (`PK..`)
- GIF: `47 49 46 38` (`GIF8`)

WHATWG MIME Sniffing Standard requires >= 1445 bytes for deterministic detection
in most cases. Spec: https://mimesniff.spec.whatwg.org/

### Implementations

#### Go: mimetype
- **URL**: https://github.com/gabriel-vasile/mimetype
- **Approach**: hierarchical magic number tree (e.g., detect ZIP first, then check
  for Office signatures within ZIP)
- **Header limit**: configurable via `SetLimit()`; reads only file header
- **Goroutine-safe**: yes
- **No C deps**: pure Go
- **Validation**: tested against libmagic across ~50,000 files
- **Dependents**: 180,000+ projects

#### Rust: infer
- **URL**: https://github.com/bojand/infer
- **Crate**: https://crates.io/crates/infer
- **Approach**: magic number signature matching
- **Features**: supports `no_std` and `no_alloc`
- **Origin**: port of Go's filetype package

#### Rust: tree_magic_mini
- **URL**: https://lib.rs/crates/tree_magic_mini
- **Approach**: tree-based subclass traversal (mirrors freedesktop shared-mime-info)
- **Performance**: ~150ns per type check; 5-100us for full detection
- **Design**: traverses MIME inheritance tree, pruning impossible branches

### Best Practice for HTTP Servers

1. Use file extension as primary hint (fast, usually correct)
2. Fall back to magic bytes for unknown extensions or verification
3. Set `X-Content-Type-Options: nosniff` to prevent browser MIME sniffing
4. Never trust client-supplied `Content-Type` for uploads

---

## 10. ETag Generation Strategies

### Comparison

| Strategy | Speed | Accuracy | Multi-server | Example |
|----------|-------|----------|--------------|---------|
| inode + mtime + size | ~0ns | Medium | Broken | Apache default |
| mtime + size | ~0ns | Medium | Works | nginx |
| Content hash (MD5/SHA) | Slow | Perfect | Works | Custom |
| Content hash (xxHash) | Fast | Perfect | Works | Custom |
| Revision/version number | ~0ns | Perfect | Works | Application-level |

### nginx Algorithm

Format: `"<hex(mtime_seconds)>-<hex(content_length)>"`

Source code (from `ngx_http_core_module.c`):
```c
ngx_sprintf(etag->value.data, "\"%xT-%xO\"",
    r->headers_out.last_modified_time,
    r->headers_out.content_length_n);
```

Example: `"5f7e1b2a-1c8f"` (mtime `0x5f7e1b2a` = 1602034474, size `0x1c8f` = 7311)

**Pros**: zero computation cost; consistent across load-balanced servers
**Cons**: fails if build tools normalize timestamps (e.g., Nix sets all to epoch)

### Apache Algorithm

Format: `"<hex(inode)>-<hex(mtime)>-<hex(size)>"`

**Critical flaw**: inode numbers differ across servers. Two servers with identical
files produce different ETags, breaking caching behind load balancers.

**Fix**: `FileETag MTime Size` in Apache config

### Recommended Strategy for New Servers

1. **Static files**: `hex(mtime_seconds)-hex(size)` (nginx style) -- zero cost,
   works in multi-server deployments
2. **Generated content**: weak ETag `W/"<hash>"` using fast hash (xxHash3 or similar)
3. **API responses**: version number or revision counter when available
4. **Validation**: always support `If-None-Match` (ETag) and `If-Modified-Since`
   (Last-Modified); prefer ETag when both present (per RFC 7232)

---

## 11. HTTP Parsers (SIMD-Accelerated)

### picohttpparser (C)

- **URL**: https://github.com/h2o/picohttpparser
- **Author**: Kazuho Oku (H2O author)
- **Language**: C
- **Design**: stateless, zero-allocation, tiny (~800 LOC)
- **SIMD**: SSE4.2 via `PCMPESTRI` for delimiter scanning
- **Performance (SSE4.2)**: 1.45 bytes/cycle (limited by 11-cycle PCMPESTRI latency)
- **Production**: used by H2O, Perl HTTP::Parser::XS, many other projects

### picohttpparser + AVX2 (Cloudflare)

- **URL**: https://blog.cloudflare.com/improving-picohttpparser-further-with-avx2/
- **Approach**: replaced SSE4.2 `PCMPESTRI` with AVX2 bitmap operations
- **Key insight**: create bitmap of all tokens across 128 bytes simultaneously,
  then scan bitmap with `TZCNT` (3-cycle latency)
- **Processing**: 32 bytes per AVX2 instruction at 0.5 cycles/instruction
- **Benchmarks** (Haswell i5, GCC 4.9.2):
  - bench.c: SSE4.2 3.9M -> AVX2 6.96M ops/s (**1.79x**)
  - fukamachi.c: SSE4.2 4.8M -> AVX2 8.06M ops/s (**1.68x**)

### hparse (Zig)

- **URL**: https://github.com/nikneym/hparse
- **Language**: Zig
- **Design**: streaming, zero-allocation, zero-copy; SIMD via Zig's `@Vector`
- **Cross-platform**: Zig vectors compile to native SIMD on any arch
- **Benchmarks vs picohttpparser**:
  - Wall time: 1.27s vs 1.45s (**12.5% faster**)
  - Peak RSS: 184KB vs 1.20MB (**84.6% less memory**)
  - Instructions: 8.01G vs 34.7G (**76.9% fewer**)
  - CPU cycles: 5.38G vs 6.16G (**12.6% fewer**)
- **Trade-off**: Zig dependency; cross-platform SIMD simpler than handwritten intrinsics

### llhttp (C/TypeScript)

- **URL**: https://llhttp.org/
- **Design**: generated from TypeScript specification (~1400 LOC TS + ~450 LOC C)
- **Used by**: Node.js (replaced http_parser)
- **Trade-off**: maintainability (generated from high-level spec) vs raw speed

---

## 12. Zig File I/O and Sendfile

### std.os.sendfile

- Wraps Linux `sendfile(2)` syscall
- Integrated into Writer interface via vtable dispatch
- Parameters: socket handle, file handle, offset, iovecs for headers/trailers
- **Known issue**: returns `usize` (unsigned) but Linux sendfile returns signed
  (`ssize_t`); `std.c.linux.sendfile64` has correct type
- Reference: https://github.com/ziglang/zig/issues/19481

### Zig HTTP Server Implementations

#### zhp
- **URL**: https://github.com/frmdstryr/zhp
- **Design**: zero-copy HTTP parser
- **Throughput**: ~1000 MB/s
- **Status**: work-in-progress

#### http.zig (karlseguin)
- **URL**: https://github.com/karlseguin/http.zig
- **Design**: production-oriented HTTP/1.1 server
- **Motivation**: `std.http.Server` is slow and assumes well-behaved clients
- **Tracks**: latest stable Zig (0.15.1)

#### Subzed (io_uring static server)
- **URL**: https://ziggit.dev/t/subzed-high-performance-linux-static-http-1-1-server/3066
- **Design**: compile-time pre-generates all HTTP responses; embeds compressed files
  in binary via `ComptimeStringMap` for O(1) retrieval
- **Architecture**: main thread accepts connections -> mutex FIFO -> worker threads
  with independent io_uring rings
- **Performance**: 175,000 req/s serving 9.8KB index.html
- **Limitation**: static content only; large files need different approach
- **io_uring features used**: `accept_multishot`; lacks `recv_multishot` in Zig std

#### zig-aio
- **URL**: https://github.com/Cloudef/zig-aio
- **Design**: io_uring-like async API with coroutine-powered I/O

### Zig vs C: HTTP Server Comparison

Reference: https://richiejp.com/zig-vs-c-mini-http-server

| Aspect | Zig | C |
|--------|-----|---|
| Error handling | `try`/`catch` propagation | Manual return code checks |
| Resource cleanup | `defer` keyword | `goto` or multiple exit points |
| MIME selection | `inline for` at comptime | Runtime `strcmp` chain |
| sendfile usage | `std.os.sendfile()` loop | `sendfile()` do-while loop |
| Memory | Zero heap allocation | Zero heap allocation |

---

## 13. Production Servers: Architecture Deep Dives

### nginx

- **Sendfile**: enabled by default; `sendfile on;` in config
- **tcp_nopush**: used with sendfile; sends headers + first data chunk in single packet
  (TCP_CORK on Linux)
- **tcp_nodelay**: disables Nagle's algorithm for keepalive connections
- **Interaction**: `sendfile` + `tcp_nopush` + `tcp_nodelay` work together:
  1. `tcp_nopush` accumulates headers + first chunk
  2. `sendfile` transfers file data
  3. `tcp_nodelay` flushes last small packet on keepalive
- **Static serving pipeline**: request -> access phase -> content handler
  (`ngx_http_static_module`) -> header filters (ETag, Range) -> body filters -> output
- **sendfile_max_chunk**: limits per-sendfile transfer to prevent connection starvation
- **Limitation**: sendfile assumes local storage; NFS can cause corruption/timeouts
- **Range handling**: implemented as output filter; adjusts buffer pointers (no re-read)
- **ETag**: auto-generated from mtime + size since v1.3.3
- Reference: https://www.getpagespeed.com/server-setup/nginx/nginx-sendfile-tcp-nopush-tcp-nodelay

### H2O

- **URL**: https://github.com/h2o/h2o
- **Language**: C
- **Author**: Kazuho Oku
- **Protocols**: HTTP/1.1, HTTP/2, HTTP/3 (QUIC)
- **File serving**: `pread(2)` or `sendfile(2)` by default; can block on page cache miss
- **Async option**: pre-reads file asynchronously to avoid worker thread blocking
- **Parser**: uses picohttpparser (same author)
- **Known issue**: 15x performance drop with 1MB data due to byte-by-byte parsing in
  libh2o -- the library vs standalone server have different code paths
- **libh2o**: embeddable library version for custom servers

### Envoy

- **URL**: https://github.com/envoyproxy/envoy
- **Static file serving**: NOT SUPPORTED natively
- **Design philosophy**: L7 proxy; does not access filesystem beyond config loading
- **Workaround**: third-party filter modules or separate static file server
- **Relevance**: demonstrates that not all proxies need file serving; focus is on
  dynamic routing, observability, and service mesh

---

## 14. Kernel-Bypass and Advanced Networking

### DPDK (Data Plane Development Kit)

- User-space packet processing; polls NICs directly
- Eliminates kernel networking stack entirely
- **Use case**: NFV, HFT, custom protocol stacks
- **Trade-off**: gives up kernel TCP/IP stack, security features, standard socket API

### AF_XDP

- Raw socket optimized for high-performance packet processing
- Zero-copy between kernel and applications for RX and TX
- eBPF program steers packets to AF_XDP sockets
- **Linux 6.14**: Intel IGB driver gets AF_XDP zero-copy support
- **UMEM**: shared memory region between kernel and user-space

### MAIO (Rethinking Zero-Copy Networking)

- **Paper**: https://netdevconf.info/0x15/papers/1/maio_netdev0x15.pdf
- **Design**: first zero-copy networking approach that preserves full kernel network stack
- **Approach**: memory segmentation using I/O pages
- **Advantage over AF_XDP**: no eBPF requirement; maintains kernel security model

### Pegasus (EuroSys '25)

- **Paper**: https://www.cs.purdue.edu/homes/pfonseca/papers/eurosys25-pegasus.pdf
- **Design**: transparent, unified kernel-bypass networking
- **Approach**: intercepts syscalls, delegates networking to DPDK fast path
- **Key property**: full Linux ABI compatibility (applications run unmodified)

### FLASH (Fast Linked AF_XDP Sockets, 2025)

- **Paper**: https://www.cse.iitb.ac.in/~mythili/research/papers/2025-flash.pdf
- **Design**: optimized chaining of AF_XDP network functions
- **Performance**: 2.5x higher throughput, 77% lower latency vs existing AF_XDP chaining
- **Zero-copy mode**: kernel-native; also offers single-copy compatibility mode

---

## 15. Research Papers

| Title | Venue/Year | Key Contribution | URL |
|-------|------------|------------------|-----|
| Efficient IO with io_uring | Kernel.dk (2019) | Original io_uring design document | https://kernel.dk/io_uring.pdf |
| io_uring for High-Performance DBMSs | arXiv (Dec 2024) | When and how to use io_uring; fixed buffer analysis | https://arxiv.org/pdf/2512.04859 |
| MAIO: Rethinking Zero-Copy | NetDev 0x15 | Zero-copy with full kernel stack | https://netdevconf.info/0x15/papers/1/maio_netdev0x15.pdf |
| Pegasus | EuroSys '25 | Transparent kernel-bypass with Linux ABI compat | https://www.cs.purdue.edu/homes/pfonseca/papers/eurosys25-pegasus.pdf |
| FLASH | IIT Bombay (2025) | Fast AF_XDP socket chaining | https://www.cse.iitb.ac.in/~mythili/research/papers/2025-flash.pdf |
| TCP Zero-Copy Internals | tohojo blog (Feb 2026) | MSG_ZEROCOPY kernel implementation details | https://blog.tohojo.dk/2026/02/the-inner-workings-of-tcp-zero-copy.html |
| A Wake-Up Call for Kernel-Bypass | DaMoN '25 | Modern hardware re-evaluation of bypass | https://www.cs.cit.tum.de/fileadmin/w00cfj/dis/papers/damon25_wake_up_call.pdf |
| TUS Resumable Uploads | IETF Draft | Standardized resumable upload protocol | https://tus.io/protocols/resumable-upload |
| Improving PicoHTTPParser with AVX2 | Cloudflare Blog | SIMD HTTP parsing, 1.79x speedup | https://blog.cloudflare.com/improving-picohttpparser-further-with-avx2/ |

---

## Summary: Key Design Decisions for a New File Server

### File Serving Path
1. Use `sendfile()` for file-to-socket transfer (simplest, proven)
2. Consider io_uring `SPLICE` only if already using io_uring for everything else
3. Avoid mmap for serving (sendfile is better for sequential transfer)
4. Set `TCP_CORK`/`TCP_NOPUSH` to coalesce headers with first data chunk

### ETag Strategy
- Use nginx-style `hex(mtime)-hex(size)` for zero-cost generation
- Avoid inode in ETag (breaks multi-server)
- Support `If-None-Match` and `If-Modified-Since`

### Range Requests
- Parse `Range: bytes=start-end` header
- Validate against file size; return 416 if invalid
- Single range: return 206 with `Content-Range`
- Multi-range: return `multipart/byteranges` (uncommon; can reject if complexity unwanted)

### Multipart Parsing
- Use callback-driven streaming parser (multer/multipart-parser-c pattern)
- Never buffer entire body in memory
- Enforce per-field and total size limits
- Stream file parts directly to destination (disk, object store, or processor)

### Content-Type
- Primary: extension-based lookup (hash map, O(1))
- Fallback: magic bytes (first 1-4KB) for unknown extensions
- Set `X-Content-Type-Options: nosniff`

### Back-Pressure
- Bound connection acceptance (semaphore or max-connections limit)
- Respect TCP back-pressure naturally (blocking/async write)
- For HTTP/2: implement per-stream flow control via WINDOW_UPDATE
- Return 503 + `Retry-After` when overloaded

### Large Uploads
- Support `Content-Length` for known-size uploads
- Support chunked transfer encoding for streaming uploads
- Consider TUS protocol for resumable uploads of very large files
- Stream to final destination; avoid intermediate buffering


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-a5593f9aa6d969c88.jsonl`
