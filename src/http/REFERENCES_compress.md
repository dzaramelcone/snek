# HTTP Response Compression: State-of-the-Art Reference

Exhaustive survey of compression implementations across high-performance systems languages,
with focus on HTTP response compression for web servers.

Last updated: 2026-03-21

---

## Table of Contents

1. [DEFLATE / gzip / zlib Implementations](#1-deflate--gzip--zlib-implementations)
2. [Brotli Implementations](#2-brotli-implementations)
3. [Zstandard (zstd) Implementations](#3-zstandard-zstd-implementations)
4. [SIMD-Accelerated Compression](#4-simd-accelerated-compression)
5. [Zig Compression Libraries](#5-zig-compression-libraries)
6. [Rust Compression Libraries](#6-rust-compression-libraries)
7. [Go Compression Libraries](#7-go-compression-libraries)
8. [Streaming Compression for HTTP](#8-streaming-compression-for-http)
9. [Compression Level vs Speed Trade-offs](#9-compression-level-vs-speed-trade-offs)
10. [Dictionary-Based Compression](#10-dictionary-based-compression)
11. [Pre-Compression Strategies](#11-pre-compression-strategies)
12. [Adaptive Compression](#12-adaptive-compression)
13. [Memory Usage in High-Concurrency Servers](#13-memory-usage-in-high-concurrency-servers)
14. [Research Papers and RFCs](#14-research-papers-and-rfcs)

---

## 1. DEFLATE / gzip / zlib Implementations

### 1.1 zlib (original)

- **URL**: https://github.com/madler/zlib
- **Language**: C
- **Design**: Streaming deflate with 32 KB sliding window. The foundational implementation from 1995.
- **Trade-offs**: Universal compatibility but slow by modern standards. No SIMD. Legacy code with workarounds for ancient compilers.
- **Benchmark**: Baseline. Other implementations report 2-5x speedups over zlib.
- **Production**: Ubiquitous. Used by virtually every HTTP server, browser, and OS.
- **Papers**: RFC 1950 (zlib format), RFC 1951 (DEFLATE), RFC 1952 (gzip format).

### 1.2 zlib-ng

- **URL**: https://github.com/zlib-ng/zlib-ng
- **Language**: C
- **Design**: Modernized fork of zlib. Removes dead code and legacy workarounds. Maintains API compatibility via `ZLIB_COMPAT` build flag, plus a modernized native API. Dual-linking support allows coexistence with stock zlib.
- **Key SIMD optimizations** (the most comprehensive of any zlib fork):
  - **Adler32**: SSE2, SSSE3, SSE4.2, AVX2, AVX512, AVX512-VNNI, NEON, VMX, VSX, LSX, LASX, RVV
  - **CRC32**: PCLMULQDQ, VPCLMULQDQ, ACLE, IBM Z CRC32-VX
  - **Slide hash**: SSE2, AVX2, ARMv6, NEON, VMX, VSX
  - **Compare256**: SSE2, AVX2, NEON, POWER9, RVV
  - **Inflate chunk copy**: SSE2, SSSE3, AVX, NEON, VSX
  - **Hardware deflate**: IBM Z DFLTCC
- **Architectures**: x86/x86-64, ARM/AArch64, POWER/PPC64, s390x, LoongArch, RISC-V, SPARC64
- **Benchmark**: ~4x faster than stock zlib on x86-64.
- **Production**: Fedora system-wide transition to zlib-ng as the default zlib. Used in major Linux distributions.

### 1.3 libdeflate

- **URL**: https://github.com/ebiggers/libdeflate
- **Language**: C
- **License**: MIT
- **Design**: Whole-buffer (non-streaming) compression/decompression. Trades streaming capability for maximum optimization on modern processors. Extends to compression level 12 with optimal parsing (minimum-cost-path algorithm). No allocator needed; caller manages buffers.
- **Key decisions**:
  - Non-streaming API: requires knowing input size upfront. Ideal for chunks < 1 MB.
  - Incompatible API with zlib (not a drop-in replacement).
  - Runtime CPU feature detection: all SIMD variants compiled in, selected at runtime.
  - Adler-32 vectorized with SSE2, AVX2, NEON (AVX2 version: ~3.9 bytes/cycle on Skylake, 5x faster than scalar).
  - CRC-32 with PCLMUL (carryless multiplication).
- **Benchmark**: ~2x faster than zlib at level 6 on x86-64. Better compression ratios at every level. For EXR image data: 1.4x faster at level 4, 2.6x faster at level 6 vs zlib.
- **Production**: Used in HTSlib (bioinformatics), game engines, image processing pipelines.

### 1.4 Cloudflare zlib fork

- **URL**: https://github.com/nicowilliams/cloudflare-zlib (historical fork)
- **Language**: C
- **Design**: Performance-focused fork of zlib with SIMD optimizations for Cloudflare's edge network.
- **Production**: Previously deployed across Cloudflare's CDN. Cloudflare has since moved to supporting Brotli (up to level 11 end-to-end) and Zstandard.

### 1.5 Chromium zlib

- **URL**: https://chromium.googlesource.com/chromium/src/+/refs/heads/main/third_party/zlib/
- **Language**: C
- **Design**: Google's optimized zlib used in Chrome. Contains SIMD optimizations for CRC32 and Adler32, plus inflate optimizations. Recently outperformed by zlib-rs on decompression benchmarks.

---

## 2. Brotli Implementations

### 2.1 Google Brotli (reference)

- **URL**: https://github.com/google/brotli
- **Language**: C (reference), plus Java, Go, Python, JS, C#, TypeScript implementations
- **Stars**: 14.6k, 103k+ dependents
- **Design**: Combines modern LZ77 variant + Huffman coding + second-order context modeling. Stream format with no metadata/checksums (integrity verification is external). Uses a pre-defined static dictionary of common web content patterns (HTML tags, CSS properties, JS keywords) -- this is a unique advantage for web content.
- **Compression levels**: 0-11.
- **Window size**: Up to 16 MiB (configurable, `--lgwin=0..24`, actual = 2^NUM - 16).
- **Benchmark data** (Cloudflare testing):
  - Brotli 4: 51.0 MB/s, 27.7% ratio (comparable to zlib 8)
  - Brotli 5: 30.3 MB/s, 26.1% ratio
  - Brotli 10: 0.5 MB/s, 23.3% ratio
  - Brotli max: 1.19x smaller than zlib max overall; 1.38x smaller for files < 1 KB
- **Dynamic content finding**: Brotli 4 is 1.48x *slower* than zlib 8 for files < 64 KB. Meaningful speedup only at quality 5+ for files > 64 KB.
- **Production**: All modern browsers (since 2017). All major CDNs. Cloudflare uses Brotli 4 for dynamic, up to 11 for static pre-compressed assets.

### 2.2 brotlic (Rust)

- **URL**: https://crates.io/crates/brotlic
- **Language**: Rust (bindings to C reference)
- **Design**: Safe Rust wrapper around the reference C implementation.
- **Benchmark**: Among the top performers for maximum compression ratio in Rust benchmarks.

### 2.3 brotli (Rust, pure)

- **URL**: https://crates.io/crates/brotli
- **Language**: Pure Rust
- **Design**: Complete Rust reimplementation, no C dependency.
- **Trade-off**: Slightly slower than C reference but avoids FFI overhead and unsafe C code.

---

## 3. Zstandard (zstd) Implementations

### 3.1 Facebook/Meta zstd (reference)

- **URL**: https://github.com/facebook/zstd
- **Language**: C
- **License**: BSD or GPLv2
- **Design**: Uses Huff0 + FSE (Finite State Entropy) for the entropy coding stage. Designed for real-time compression with zlib-level ratios but much faster speed.
- **Compression levels**: -7 (fastest) to 22 (slowest/best ratio). Negative levels via `--fast=#`.
- **Benchmark** (Core i7-9700K, zstd 1.5.7, Silesia corpus):
  - Default level: 2.896 ratio, 510 MB/s compress, 1550 MB/s decompress
  - `--fast=4`: 2.146 ratio, 665 MB/s compress, 2050 MB/s decompress
  - Key property: **decompression speed is roughly constant across all levels** (~1500-2050 MB/s)
- **Dictionary compression**: Training mode generates dictionaries from sample data. Dramatically improves ratios on small data (most effective in first few KB). Training: `zstd --train samples/* -o dict`.
- **Streaming API**: Full streaming support with configurable window sizes and block sizes.
- **HTTP standard**: RFC 8878 (Zstandard format), RFC 9659 (window sizing for HTTP Content-Encoding).
- **Browser support**: Chrome 123+ (March 2024), Firefox 126+ (May 2024), all Chromium-based. Safari: not yet.
- **Production**: Meta infrastructure, Netflix, Chrome, major CDNs.

### 3.2 zstd crate (Rust)

- **URL**: https://crates.io/crates/zstd
- **Language**: Rust (bindings to C reference via zstd-sys)
- **Benchmark**: ~100 MB/s compression, ~1 GB/s decompression, 70-75% size reduction (Silesia corpus).
- **Production**: Widely used in the Rust ecosystem.

### 3.3 klauspost/compress zstd (Go)

- **URL**: https://github.com/klauspost/compress (zstd subpackage)
- **Language**: Pure Go
- **Design**: Complete reimplementation in Go, not CGo bindings. Includes AMD64 assembly optimizations for match length operations.
- **Benchmark**: 219.21 MB/s for 2 KB payloads (vs gzip at 137.22 MB/s = 1.6x faster).

---

## 4. SIMD-Accelerated Compression

### 4.1 Intel ISA-L (igzip)

- **URL**: https://github.com/intel/isa-l
- **Language**: C (61.6%) + Assembly (35.5%)
- **Design**: SIMD-first implementation using hand-written assembly for critical paths. Uses registers instead of stack for temporaries, minimizing memory traffic. Optimized for storage-intensive workloads.
- **Architectures**: x86-64, AArch64, RISC-V 64.
- **Compression levels**: 0-3 (fewer levels than zlib, focused on the fast end).
- **Benchmark**: ~5x faster than zlib. Fastest ISA-L compression is 2x faster than level 1 zlib-ng/libdeflate, though with worse compression ratios.
- **Trade-off**: Excellent speed at the cost of compression ratio. Best for scenarios where CPU is the bottleneck and bandwidth is cheap.
- **Output compatibility**: Fully gzip-compatible output.
- **Production**: Used in storage systems, Intel QAT acceleration.
- **Papers**: CERN paper on accelerating ROOT compression with ISA-L.

### 4.2 SIMD in other implementations

Most modern implementations now include SIMD paths:
- **zlib-ng**: Most comprehensive SIMD coverage (see section 1.2).
- **libdeflate**: AVX2, SSE2, NEON, PCLMUL for checksums.
- **zlib-rs**: SIMD for CRC32, Adler32, longest match.
- **zstd**: SIMD for entropy decoding on some platforms.

---

## 5. Zig Compression Libraries

### 5.1 std.compress (Zig standard library)

- **URL**: https://github.com/ziglang/zig (lib/std/compress/)
- **Language**: Zig
- **Supported formats**: deflate, gzip, zlib, zstd, lzma, lzma2, xz.
- **Design origins**: The deflate implementation is based on ianic/flate (merged into std in Zig 0.12.0). Written from first principles, not a port.
- **Key design decisions**:
  - Static allocations for all structures -- **no allocator required** for deflate/gzip.
  - Consistent API across formats: `compress(reader, writer, options)`, `compressor(writer, options)`, `decompress(reader, writer)`, `decompressor(reader)`.
  - Deflate memory: 395 KB (vs 779 KB in older std). Inflate: 74.5 KB (uses 64K history vs 32K).
- **Benchmark** (AArch64 Linux, Apple M1, 177 MB tar):
  - Store: 1.24x faster than old std
  - Huffman-only: 1.33x faster
  - Level 6 (default): 1.13x faster
  - Level 9: 1.23x faster
  - Decompression: 1.2-1.4x faster than old std consistently
- **Benchmark** (x86-64, Intel i7-3520M):
  - Decompression: 1.21-1.45x faster than old std
- **zstd status**: Decompressor exists but still requires an allocator (unlike deflate). Active work on O(1) memory decompression. Performance benchmarking against C reference implementation is ongoing.

### 5.2 ianic/flate (archived, merged into std)

- **URL**: https://github.com/ianic/flate
- **Language**: Zig
- **Status**: Archived. Code merged into Zig standard library.
- **Design**: Started from first principles rather than porting existing code. Influenced by Go's compress/flate, zlib C source, RFCs 1951/1952, and articles on faster DEFLATE decompression and zero-refill-latency bit reading.

---

## 6. Rust Compression Libraries

### 6.1 flate2

- **URL**: https://github.com/rust-lang/flate2-rs
- **Language**: Rust
- **Design**: Unified API for DEFLATE/gzip/zlib with swappable backends:
  - `miniz_oxide` (default): Pure Rust port of miniz.c. Safe, no FFI.
  - `zlib`: Binds to system zlib.
  - `zlib-ng`: Binds to zlib-ng for maximum performance.
  - `zlib-rs`: Pure Rust rewrite of zlib. **Fastest backend overall** per maintainer claims.
- **Streaming**: Full streaming Read/Write support.

### 6.2 zlib-rs

- **URL**: https://github.com/trifectatechfoundation/zlib-rs
- **Language**: Rust (with some unsafe for SIMD)
- **Design**: Complete Rust rewrite of zlib with API compatibility. Can be used as a C dynamic library drop-in replacement. Part of ISRG/Prossimo memory safety initiative. Audited.
- **Benchmark** (vs zlib-ng):
  - Level 1 compression: +20.2% slower than zlib-ng
  - Level 6 compression: +5.7% slower
  - Level 9 compression: +2.8% slower (essentially on-par)
  - Decompression: **Fastest API-compatible implementation**, beating both zlib-ng and Chromium zlib. 10%+ faster for 1 KB inputs, 6%+ faster for 64 KB inputs.
- **WASM**: Fastest WASM zlib implementation.
- **Production**: Growing adoption as memory-safe zlib replacement.

### 6.3 Rust compression crate comparison (Silesia corpus, AMD Ryzen 7 2700X)

| Crate | Compress Speed | Decompress Speed | Size Reduction | Notes |
|-------|---------------|-------------------|----------------|-------|
| zstd | ~100 MB/s | ~1 GB/s | 70-75% | Best overall balance |
| lz4_flex | ~350 MB/s | 2+ GB/s | 50-55% | Pure Rust, fastest decompression |
| brotlic | Varies by level | Fast | 70-80% | Best max compression |
| flate2 (miniz_oxide) | Moderate | Moderate | 65-70% | Safe, pure Rust |
| yazi | Lower | Lower | 70-75% | Pure Rust alternative |

Source: https://git.sr.ht/~quf/rust-compression-comparison

---

## 7. Go Compression Libraries

### 7.1 klauspost/compress

- **URL**: https://github.com/klauspost/compress
- **Language**: Go (with AMD64 assembly for hot paths)
- **Packages**:
  - `zstd`: Pure Go Zstandard, streaming and single-shot
  - `gzip/flate`: Optimized drop-in replacements for stdlib
  - `s2`: High-performance Snappy replacement
  - `huff0`, `fse`: Raw entropy encoders
  - `gzhttp`: HTTP middleware for gzip + zstd
  - `pgzip`: Parallel gzip (multi-threaded)
- **gzhttp middleware features**:
  - Content negotiation (prefers zstd when equal quality)
  - BREACH mitigation
  - ETag handling (SuffixETag, DropETag)
  - Request body decompression
  - ResponseWriter unwrapping
- **Build tags**: `nounsafe` (disable unsafe), `noasm` (disable assembly)

### 7.2 CAFxX/httpcompression

- **URL**: https://github.com/CAFxX/httpcompression
- **Language**: Go
- **Design**: HTTP middleware supporting zstd, brotli, gzip, deflate, xz/lzma2, lz4. Default preference order: zstd > brotli > gzip (conditional on client Accept-Encoding).

---

## 8. Streaming Compression for HTTP

### Design considerations for HTTP response streaming

**Chunked transfer + streaming compression** is the standard pattern:
1. Receive uncompressed response data from application.
2. Compress into internal buffer.
3. Flush compressed buffer as HTTP chunk.
4. Recycle buffer for next chunk (avoids allocation per chunk).

**Key design decisions**:
- **Flush strategy**: Flush after each logical chunk vs. accumulate for better ratio. For HTTP, latency-sensitive applications need frequent flushing (sync flush after each write), sacrificing some compression ratio.
- **Buffer sizing**: Larger buffers = better compression but higher latency and memory. Typical: 8-32 KB output buffers.
- **Context reuse**: Reusing compression contexts across requests on the same connection avoids re-initialization cost. zstd and zlib both support context reset without reallocation.

**zstd streaming specifics**:
- Streaming compressor allocates: `Window_Size + 2 * Block_Maximum_Size`
- Streaming decompressor allocates: `Window_Size + 3 * Block_Maximum_Size`
- `ZSTD_c_stableInBuffer` / `ZSTD_c_stableOutBuffer`: eliminate copy buffers when caller guarantees buffer persistence.

**libdeflate exception**: Does NOT support streaming. Whole-buffer only. Not suitable for HTTP chunked streaming directly. Must buffer entire response first, or use a different library for streaming.

---

## 9. Compression Level vs Speed Trade-offs

### Algorithm comparison for HTTP serving

#### Dynamic content (compress on every request)

| Algorithm | Level | Compress Speed | Ratio vs gzip-6 | Recommendation |
|-----------|-------|---------------|------------------|----------------|
| gzip | 1 | Fast | Worse | nginx default; fast but poor ratio |
| gzip | 4-6 | Moderate | Baseline | Best general gzip trade-off |
| gzip | 9 | Slow | Slightly better | Rarely worth CPU cost |
| brotli | 4 | ~51 MB/s | Similar to gzip-8 | Break-even with gzip on small files |
| brotli | 5 | ~30 MB/s | 8.85% smaller | Worthwhile for files > 64 KB |
| zstd | 3 | ~510 MB/s | ~11% smaller | Best speed/ratio for dynamic content |
| zstd | 1 | ~665 MB/s | Slightly smaller | When CPU is critical |

#### Static content (compress once, serve many times)

| Algorithm | Level | Ratio Improvement vs gzip-6 | Notes |
|-----------|-------|-----------------------------|-------|
| brotli | 11 | 19.18% smaller | Best ratio; 4x slower to compress than zstd-19 |
| zstd | 19 | 14.11% smaller | Good ratio; 4x faster than brotli-11 |
| gzip | 9 | Baseline | Still widely needed as fallback |
| libdeflate | 12 | Better than gzip-9 | Optimal parsing algorithm |

**Key insight**: zstd is 695x faster than brotli at comparable compression levels in some benchmarks. For dynamic content, zstd level 3 offers the best trade-off. For static/cached content, brotli 11 is king.

**nginx defaults**: gzip_comp_level 1 (speed over ratio). Production recommendation: level 4-6.

---

## 10. Dictionary-Based Compression

### 10.1 RFC 9842: Compression Dictionary Transport (September 2025)

- **URL**: https://www.rfc-editor.org/rfc/rfc9842.html
- **Supported algorithms**: Dictionary-Compressed Brotli (`dcb`), Dictionary-Compressed Zstandard (`dcz`)
- **Mechanism**:
  - Server sends `Use-As-Dictionary` header on responses, specifying URL pattern match rules.
  - Client stores response as dictionary, sends `Available-Dictionary` header (SHA-256 hash) on subsequent requests.
  - Server compresses using client's dictionary, responds with `Content-Encoding: dcb` or `dcz`.
  - Client decompresses using stored dictionary.
- **Security**: HTTPS only. Same-origin enforcement. SHA-256 validation. Partitioned like cookies.
- **dcb header**: 36 bytes (4-byte magic + 32-byte SHA-256). Max 16 MB compression window.
- **dcz header**: 40 bytes (8-byte magic + 32-byte SHA-256). Window: max(8 MB, 1.25 * dict_size), max 128 MB.
- **Browser support**: Chrome 130+, Edge, Brave (~70% of clients). Safari and Firefox have implementation plans.

### 10.2 Real-world dictionary compression results

| Use case | Without dict | With dict | Improvement |
|----------|-------------|-----------|-------------|
| YouTube JS bundle (delta, 2 months) | 1.8 MB (Brotli) | 384 KB | 78% smaller |
| YouTube JS bundle (delta, 1 week) | 1.8 MB (Brotli) | 172 KB | 90% smaller |
| Google Search HTML | Best-practice compressed | ~50% smaller | ~50% improvement |
| Amazon product pages | 84 KB (Brotli) | 10 KB | 88% smaller |
| Figma WASM | Compressed | Much smaller | Up to 95% improvement |

### 10.3 zstd dictionary training

```
zstd --train samples/* -o dictionary_file
```

Most effective in the first few KB of data. Simultaneously improves both compression ratio and speed. Ideal for repeated small responses (API endpoints, similar HTML pages).

### 10.4 Brotli static dictionary

Brotli has a built-in 120 KB static dictionary of common web strings (HTML tags, CSS properties, JS keywords, common English words). This gives it an inherent advantage on web content, especially small responses where the dictionary comprises a significant fraction of the content.

---

## 11. Pre-Compression Strategies

### Build-time compression workflow

1. Build/deploy pipeline compresses all static assets at maximum levels.
2. Generate `.br` (Brotli 11) and `.gz` (gzip 9 or libdeflate 12) sidecar files.
3. Web server serves pre-compressed files when available.

### Server configuration

**nginx**:
```
gzip_static on;        # Serves .gz files if present
brotli_static on;      # Serves .br files if present (ngx_brotli module)
```
Resolution order: `.br` -> `.gz` -> raw file.

**Caddy**:
```
file_server {
    precompressed br gzip
}
```

### Build tool integration

- Vite/Rollup: `rollup-plugin-brotli`, `rollup-plugin-gzip`
- Webpack: `compression-webpack-plugin`
- CLI: `find . -name "*.js" -o -name "*.css" -o -name "*.html" | xargs -P4 -I{} brotli -q 11 -o {}.br {}`

### Benefits

- CPU impact only at deploy time, not per-request.
- Can use maximum compression levels (brotli 11, zstd 19) without latency penalty.
- Deterministic: same output every time, cache-friendly.

### Considerations

- Storage cost: ~2x static asset storage (original + .br + .gz).
- Must regenerate on every deploy.
- Dynamic content (API responses, SSR HTML) still needs runtime compression.

---

## 12. Adaptive Compression

### Content-type based selection

Standard practice in production servers:

- **Compressible types**: text/html, text/css, text/javascript, application/json, application/xml, image/svg+xml, application/wasm, font/ttf, font/woff.
- **Skip compression**: Already-compressed formats (image/png, image/jpeg, video/*, application/zip, font/woff2).
- **Minimum size threshold**: Cloudflare uses a minimum size for Brotli, falling back to gzip for small files. Typical: skip compression for responses < 256 bytes.

### Algorithm negotiation

HTTP `Accept-Encoding` header drives selection:
```
Accept-Encoding: zstd, br, gzip, deflate
```

Server preference order (recommended for 2025+):
1. **zstd** -- fastest for dynamic content, best speed/ratio
2. **br** (Brotli) -- best ratio, especially for small web content
3. **gzip** -- universal fallback
4. **deflate** -- legacy, avoid (ambiguous spec)

### Size-based adaptation

| Response size | Recommended algorithm | Level |
|---------------|----------------------|-------|
| < 256 bytes | None (overhead exceeds savings) | - |
| 256 B - 1 KB | Brotli (static dictionary advantage) | 4-5 |
| 1 KB - 64 KB | zstd (fast, good ratio) | 3 |
| 64 KB - 1 MB | zstd or brotli | 3 / 5 |
| > 1 MB | zstd (speed matters more at scale) | 1-3 |

---

## 13. Memory Usage in High-Concurrency Servers

### Per-connection compression memory

This is critical for servers handling thousands of concurrent connections.

#### gzip/deflate (zlib API)

Formula: `(1 << (windowBits + 2)) + (1 << (memLevel + 9))`

| windowBits | memLevel | Memory per stream |
|------------|----------|-------------------|
| 15 (default) | 8 (default) | ~256 KB |
| 12 | 5 | ~18 KB |
| 9 (minimum) | 1 (minimum) | ~3 KB |

#### zstd streaming

Compression: `Window_Size + 2 * Block_Maximum_Size + hash_tables`

| Configuration | Memory per stream | Notes |
|--------------|-------------------|-------|
| Default (level 3, 128 KB window) | Several MB | Too much for high concurrency |
| Tuned (windowLog=18, blockSize=2KB, level 3) | ~260 KB | Good for replication/streaming |
| Minimal (windowLog=14, level 1) | ~20 KB | Tight memory, lower ratio |

Key parameters:
- `ZSTD_c_windowLog`: Directly controls history buffer size.
- `ZSTD_c_maxBlockSize`: Controls compressed block buffer (compressor allocates 2x this).
- `ZSTD_c_stableInBuffer` / `ZSTD_c_stableOutBuffer`: Eliminate copy buffers entirely if caller guarantees persistence.
- Stick to levels <= 3 for L2 cache-friendly hash tables.

#### Brotli

Window configurable from 1 KB to 16 MB (lgwin 0-24). Decoder needs up to window size in memory.

| lgwin | Window Size | Approx decoder memory |
|-------|------------|----------------------|
| 24 (default) | 16 MB | ~16 MB |
| 18 | 256 KB | ~256 KB |
| 12 | 4 KB | ~4 KB |

Compression memory scales with both level and window size.

#### Zig std.compress.deflate

- Compress context: 395 KB (fixed, no allocator needed)
- Decompress context: 74.5 KB (fixed, no allocator needed)
- This is a significant advantage for embedded/constrained servers.

### Strategies for high concurrency

1. **Context pooling**: Pre-allocate a pool of compression contexts, check out per-request, return after response. Bounds total memory regardless of connection count.
2. **Reduced window sizes**: Lower `windowBits`/`lgwin`/`windowLog` for concurrent streams.
3. **Skip small responses**: Don't compress responses below a threshold.
4. **Pre-compression**: Eliminates runtime memory entirely for static content.
5. **libdeflate for known-size responses**: No streaming overhead, minimal memory, but requires knowing response size upfront.

---

## 14. Research Papers and RFCs

### RFCs

| RFC | Title | Relevance |
|-----|-------|-----------|
| RFC 1950 | ZLIB Compressed Data Format | zlib wrapper format |
| RFC 1951 | DEFLATE Compressed Data Format | Core DEFLATE algorithm |
| RFC 1952 | GZIP File Format | gzip wrapper format |
| RFC 7932 | Brotli Compressed Data Format | Brotli algorithm spec |
| RFC 8878 | Zstandard Compression and application/zstd | Zstandard format spec |
| RFC 9110 | HTTP Semantics | Content-Encoding, Accept-Encoding |
| RFC 9659 | Window Sizing for Zstandard Content Encoding | Limits zstd window to 8 MB for HTTP |
| RFC 9842 | Compression Dictionary Transport | Shared dictionaries for HTTP (Sept 2025) |

### Key blog posts and benchmarks

- Cloudflare: "Results of experimenting with Brotli for dynamic web content" -- https://blog.cloudflare.com/results-experimenting-brotli/
- Paul Calvano: "Choosing between gzip, Brotli, and Zstandard" -- https://paulcalvano.com/2024-03-19-choosing-between-gzip-brotli-and-zstandard-compression/
- HTTP Toolkit: "Dictionary compression is ridiculously good" -- https://httptoolkit.com/blog/dictionary-compression-performance-zstd-brotli/
- SpeedVitals: "ZSTD vs Brotli vs GZip" -- https://speedvitals.com/blog/zstd-vs-brotli-vs-gzip/
- Trifecta Tech: "Current zlib-rs performance" -- https://trifectatech.org/blog/current-zlib-rs-performance/
- AWS: "Improving zlib-cloudflare and comparing performance" -- https://aws.amazon.com/blogs/opensource/improving-zlib-cloudflare-and-comparing-performance-with-other-zlib-forks/
- Intel: "Data Compression Tuning Guide on Xeon Systems" -- https://www.intel.com/content/www/us/en/developer/articles/guide/data-compression-tuning-guide-on-xeon-systems.html
- Aras Pranckevičius: "EXR: libdeflate is great" -- https://aras-p.info/blog/2021/08/09/EXR-libdeflate-is-great/
- ARM/Linaro: "Optimizing Zlib on ARM: The Power of NEON" -- https://events19.linuxfoundation.org/wp-content/uploads/2017/11/Optimizing-Zlib-on-ARM-The-Power-of-NEON-Adenilson-Cavalcanti-ARM.pdf
- CERN: "Accelerating ROOT compression with Intel ISA-L" -- https://indico.cern.ch/event/1106990/papers/4991333/files/13093-Accelerating%20ROOT%20compression%20with%20Intel%20ISA-L%20library.pdf
- Rust compression comparison: https://git.sr.ht/~quf/rust-compression-comparison
- HTSlib zlib benchmarks: http://www.htslib.org/benchmarks/zlib.html
- lzturbo web compression benchmark: https://sites.google.com/site/powturbo/home/web-compression

---

## Summary: Recommended Stack for a High-Performance HTTP Server (2025+)

| Concern | Recommendation |
|---------|---------------|
| **Static assets** | Pre-compress with Brotli 11 + gzip 9 at build time |
| **Dynamic content (default)** | zstd level 3 (fastest good ratio) |
| **Dynamic fallback** | gzip level 4-6 via zlib-ng or zlib-rs |
| **Small responses < 1 KB** | Brotli (static dictionary advantage) or skip |
| **Deflate library (C)** | zlib-ng (streaming) or libdeflate (whole-buffer) |
| **Deflate library (Rust)** | flate2 with zlib-rs backend |
| **Deflate library (Zig)** | std.compress (no allocator, 395 KB fixed) |
| **Deflate library (Go)** | klauspost/compress |
| **Memory-constrained** | Reduce window sizes, pool contexts, skip tiny responses |
| **Future** | RFC 9842 dictionary compression for delta updates |


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-a39cfcd8b0272fcc0.jsonl`
