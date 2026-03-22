# JSON Parsing & Serialization: State of the Art

Exhaustive survey of high-performance JSON implementations across systems languages.
Last updated: 2026-03-21.

---

## Table of Contents

1. [Research Papers](#research-papers)
2. [C/C++ Implementations](#cc-implementations)
   - [simdjson](#simdjson-c)
   - [yyjson](#yyjson-c)
   - [RapidJSON](#rapidjson-c)
3. [Rust Implementations](#rust-implementations)
   - [sonic-rs](#sonic-rs-rust)
   - [simd-json](#simd-json-rust)
   - [serde_json](#serde_json-rust)
   - [orjson](#orjson-pythonrust)
4. [Go Implementations](#go-implementations)
   - [sonic](#sonic-go)
   - [jsoniter](#jsoniter-go)
   - [go-json](#go-json-go)
   - [fastjson](#fastjson-go)
   - [simdjson-go](#simdjson-go)
   - [segmentio/encoding](#segmentioencoding-go)
   - [OjG](#ojg-go)
5. [Zig](#zig)
   - [std.json](#stdjson-zig)
6. [Odin](#odin)
   - [core/encoding/json](#coreencodingjson-odin)
7. [Other Notable Projects](#other-notable-projects)
   - [Wuffs](#wuffs)
   - [UltraJSON](#ultrajson-python)
   - [FlatBuffers](#flatbuffers)
8. [Cross-Cutting Techniques](#cross-cutting-techniques)
   - [SIMD Structural Classification](#simd-structural-classification)
   - [Tape-Based Representation](#tape-based-representation)
   - [Zero-Copy Parsing](#zero-copy-parsing)
   - [Schema-Aware / On-Demand Parsing](#schema-aware--on-demand-parsing)
   - [Direct-to-Wire Serialization](#direct-to-wire-serialization)
   - [SIMD UTF-8 Validation](#simd-utf-8-validation)
   - [Arena Allocation](#arena-allocation)
   - [JIT Compilation for JSON](#jit-compilation-for-json)
   - [Streaming / Incremental Parsing](#streaming--incremental-parsing)
9. [Lessons Learned & Post-Mortems](#lessons-learned--post-mortems)
10. [Benchmark Context & Methodology Notes](#benchmark-context--methodology-notes)

---

## Research Papers

### "Parsing Gigabytes of JSON per Second"
- **Authors:** Geoff Langdale, Daniel Lemire
- **Published:** VLDB Journal 28(6), 2019. arXiv:1902.08318
- **URL:** https://arxiv.org/abs/1902.08318
- **Key contributions:**
  - First standard-compliant JSON parser to process gigabytes/sec on a single core
  - Uses 1/4 or fewer instructions than RapidJSON
  - Two-stage architecture: SIMD-intensive structural detection (Stage 1) followed by branchy validation/tree construction (Stage 2)
  - Introduced tape-based representation for parsed JSON
  - PCLMULQDQ (carry-less multiplication) for quote-pair detection
  - VPSHUFB-based character classification via lookup tables

### "On-Demand JSON: A Better Way to Parse Documents?"
- **Authors:** Daniel Lemire et al.
- **Published:** Software: Practice and Experience 54(6), 2024
- **Key contributions:**
  - Lazy parsing: run Stage 1 (SIMD index generation) upfront, then parse values on access
  - Iterator-based API that walks original JSON text
  - Can skip unwanted fields without parsing them
  - Competitive with or faster than full DOM parsing for selective access patterns

### "Validating UTF-8 In Less Than One Instruction Per Byte"
- **Authors:** John Keiser, Daniel Lemire
- **Published:** Software: Practice & Experience 51(5), 2021. arXiv:2010.03090
- **Key contributions:**
  - "Lookup algorithm" using SIMD shuffle instructions for UTF-8 state machine
  - >10x faster than standard library UTF-8 validation routines
  - Works with AVX2, SSE4.2, NEON, and other SIMD ISAs
  - Integrated into simdjson's Stage 1 for zero-overhead validation during parsing

---

## C/C++ Implementations

### simdjson (C++)

- **URL:** https://github.com/simdjson/simdjson
- **Stars:** 23.5k | **License:** Apache-2.0 / MIT
- **Latest:** v4.4.2 (March 2026)

#### Architecture

Two-stage pipeline:

**Stage 1 (SIMD-intensive, nearly branch-free):**
1. UTF-8 validation across entire input
2. Backslash detection (odd-length escape sequences)
3. Quote pairing via PCLMULQDQ + parallel prefix XOR
4. Character classification via VPSHUFB table lookup (structural chars + whitespace)
5. Pseudo-structural character detection (exposes atoms: true/false/null, numbers)
6. Bitmask-to-index conversion

**Stage 2 (branchy, goto-based automaton):**
1. JSON structural validity checking
2. Atom and number validation
3. String validation
4. Tape construction

#### Tape Format

Sequential array of 64-bit values. Each element: `('c' << 56) + payload`.

| Type | Tag | Payload |
|------|-----|---------|
| null | `'n'` | 0 |
| true | `'t'` | 0 |
| false | `'f'` | 0 |
| signed int | `'l'` | next 64 bits = two's complement value |
| unsigned int | `'u'` | next 64 bits = unsigned value |
| float | `'d'` | next 64 bits = IEEE 754 double |
| string | `'"'` | pointer to string tape (32-bit length header + UTF-8 + null terminator) |
| array open | `'['` | (count << 32) + index of `]` + 1 |
| array close | `']'` | index of `[` |
| object open | `'{'` | (count << 32) + index of `}` + 1 |
| object close | `'}'` | index of `{` |
| root | `'r'` | index of final element |

This enables O(1) skipping of entire arrays/objects via direct index jumps.

#### On-Demand API (default since v1.0)

- Runs Stage 1 upfront to build structural index
- Stage 2 executes lazily as user iterates/accesses values
- Forward-only iterator over the JSON text
- Values consumed exactly once; no random access
- String views point into source buffer or parser-internal buffers
- Requires `SIMDJSON_PADDING` extra bytes at end of input

#### Performance

On Intel Skylake 3.4 GHz, GCC 10 (-O3):
- Parsing: multiple GB/s (varies by document)
- Minification: 6 GB/s
- UTF-8 validation: 13 GB/s
- NDJSON: 3.5 GB/s (multithreaded)
- 4x faster than RapidJSON, 25x faster than nlohmann/json
- 3/4 fewer instructions than RapidJSON

#### Supported Architectures (runtime detection)
- x86-64: SSE4.2, AVX2, AVX-512
- ARM64: NEON
- RISC-V (experimental)

#### Production Users
Node.js, ClickHouse, Meta Velox, Google Pax, Milvus, QuestDB, StarRocks, WatermelonDB, Apache Doris, Intel PCM, Ladybird Browser.

#### Key Trade-offs
- Requires padding on input buffers
- On-Demand API: forward-only, single-consumption constraint
- Tape format is immutable -- no in-place modification
- Document + parser must remain in scope during iteration

---

### yyjson (C)

- **URL:** https://github.com/ibireme/yyjson
- **Language:** ANSI C (C89)
- **License:** MIT

#### Design Decisions
- **No explicit SIMD instructions** -- achieves high performance through careful scalar code that modern CPUs auto-vectorize and execute with high ILP
- Strict RFC 8259 compliance with full UTF-8 validation
- Arrays/objects use **linked-list** structures (not hash tables) -- trades O(1) key lookup for simpler memory management
- Immutable parsed documents by default; mutable copies for modification
- Single `.h` + `.c` file integration
- Functions gracefully handle NULL inputs (return NULL on error, no exceptions)
- Implements RFC 6901 (JSON Pointer), RFC 6902 (JSON Patch), RFC 7386 (JSON Merge Patch)

#### Performance

**AWS EC2 (AMD EPYC 7R32, gcc 9.3):**

| Library | Parse GB/s | Stringify GB/s |
|---------|-----------|----------------|
| yyjson (in-situ) | 1.80 | 1.42 |
| yyjson (standard) | 1.72 | 1.42 |
| simdjson | 1.52 | 0.61 |
| RapidJSON (UTF-8) | 0.26 | 0.39 |

**iPhone (Apple A14, clang 12):**

| Library | Parse GB/s | Stringify GB/s |
|---------|-----------|----------------|
| yyjson (in-situ) | 3.51 | 2.41 |
| yyjson (standard) | 2.39 | 2.01 |
| simdjson | 2.19 | 0.80 |

Key insight: yyjson's stringify is 2-3x faster than simdjson's. The advantage comes from careful scalar code that plays well with branch prediction on modern OoO cores, particularly Apple Silicon.

#### Production Users
DuckDB, fastfetch, orjson (as parse backend), Zrythm. Bindings in Python, R, Swift, C++, Julia.

#### Key Trade-offs
- Linked-list objects: no O(1) key lookup (must iterate)
- Duplicate keys permitted (order preserved)
- Immutable documents require copy for modification

---

### RapidJSON (C++)

- **URL:** https://github.com/Tencent/rapidjson
- **Stars:** 15k+ | **License:** MIT
- **Maintained by:** Tencent

#### Design Decisions
- Dual API: **SAX** (event-driven streaming) + **DOM** (in-memory tree)
- SAX parser is ~500 lines of code
- **In-situ parsing**: modifies input buffer during parse to avoid string allocation
- Comprehensive Unicode: UTF-8, UTF-16, UTF-32 (LE & BE) with transcoding
- Header-only, no dependencies (not even STL)
- Each JSON Value = exactly **16 bytes** on 32/64-bit machines (excluding string content)
- Optional SSE2/SSE4.2 acceleration
- Fast custom memory allocator with compact allocation during parsing

#### Performance
- Parsing speed "comparable to strlen()"
- Historically the benchmark baseline against which simdjson measures (simdjson is ~4x faster)

#### Key Trade-offs
- Less actively maintained (many open issues)
- 16-byte Value overhead per node
- No SIMD by default (optional)
- The benchmark simdjson and yyjson consistently beat

---

## Rust Implementations

### sonic-rs (Rust)

- **URL:** https://github.com/cloudwego/sonic-rs
- **Maintained by:** CloudWego (ByteDance)

#### Design Decisions
- **Targeted SIMD** (not two-stage tape): applies SIMD selectively to:
  1. Parsing/serializing long JSON strings
  2. Floating-point fraction parsing
  3. Specific field extraction (skipping)
  4. Whitespace skipping
- **Arena allocator** for document values -- fewer allocations, better cache locality
- Objects stored as **arrays** (not HashMaps) -- avoids HashMap construction overhead
- **LazyValue**: wrapper around raw valid JSON slice for deferred parsing
- **RawNumber**: numeric handling without immediate conversion
- Both safe and `unchecked` APIs (unchecked assumes valid input, enables aggressive SIMD skipping)
- Integrates with Serde traits

#### Performance vs serde_json and simd-json

**Typed struct deserialization:**

| Dataset | sonic-rs (unchecked) | serde_json | Speedup |
|---------|---------------------|------------|---------|
| twitter.json | 694 us | 2,270 us | 3.3x |
| citm_catalog.json | 1,200 us | 2,900 us | 2.4x |
| canada.json | 3,800 us | 9,200 us | 2.4x |

**Untyped Value deserialization:**

| Dataset | sonic-rs | serde_json | Speedup |
|---------|----------|------------|---------|
| twitter.json | 550 us | 3,760 us | 6.8x |
| citm_catalog.json | 1,670 us | 8,160 us | 4.9x |
| canada.json | 4,900 us | 16,700 us | 3.4x |

sonic-rs outperforms simd-json by 20-50% on typed deserialization because it avoids intermediate tape structures.

**Serialization (untyped):**

| Dataset | sonic-rs | serde_json | Speedup |
|---------|----------|------------|---------|
| twitter.json | 381 us | 789 us | 2.1x |
| citm_catalog.json | 806 us | 1,830 us | 2.3x |

#### Key Trade-offs
- Requires x86_64 or aarch64 for SIMD (fallback on other platforms)
- Recommend `-C target-cpu=native` compiler flag
- Sanitizer support incurs ~30% serialization penalty
- Unchecked API is unsafe if input is invalid

---

### simd-json (Rust)

- **URL:** https://github.com/simd-lite/simd-json
- **Stars:** 1.4k | **License:** Apache-2.0 / MIT

#### Design Decisions
- Rust port of simdjson C++, adapted for Rust ecosystem ("ergonomics over performance" in some areas)
- Three API levels:
  1. **Values API**: borrowed and owned DOM representations
  2. **Serde Compatible API**: drop-in with serde_json::Value
  3. **Tape API**: low-level sequential traversal with minimal allocations
- Runtime CPU detection (AVX2, SSE4.2, NEON, WASM simd128, fallback)
- Recommends specialized allocators (snmalloc, mimalloc, jemalloc) over system default

#### Feature Flags
- `runtime-detection`: portable binaries with runtime ISA selection
- `known-key`: trades DOS-resistant hashing (ahash) for memoization (fxhash)
- `value-no-dup-keys`: deterministic duplicate key handling
- `big-int-as-float`: prevents parse failure on integers > u64

#### Performance
- Tracks simdjson 0.2.x C++ performance
- No specific benchmark numbers published in README
- Generally 20-50% slower than sonic-rs on typed deserialization (due to tape intermediate step)

#### Key Trade-offs
- Tape intermediate step adds overhead for typed deserialization
- Heavy unsafe code (necessary for SIMD intrinsics)
- Smaller ecosystem adoption vs serde_json

---

### serde_json (Rust)

- **URL:** https://github.com/serde-rs/json
- **The standard** Rust JSON library

#### Design Decisions
- DOM via `serde_json::Value` (recursive enum: Null/Bool/Number/String/Array/Object)
- Zero-copy deserialization with borrowed data (`&str` fields can reference input)
- `RawValue` type for deferred parsing of subtrees
- Two serialization paths: `json!` macro (untyped) and derive-based (strongly-typed)
- Multiple entry points: `from_str`, `from_slice`, `from_reader`

#### Performance
- Deserialization: 500-1000 MB/s
- Serialization: 600-900 MB/s
- Claims competitive with fastest C/C++ libraries, "or even 30% faster for many use cases"
- Benchmark suite: https://github.com/serde-rs/json-benchmark

#### Key Trade-offs
- The baseline everyone beats with SIMD approaches
- HashMap-based objects (allocation + hashing overhead)
- No SIMD acceleration
- Excellent ergonomics and ecosystem integration

---

### orjson (Python/Rust)

- **URL:** https://github.com/ijl/orjson
- **License:** Apache-2.0 / MIT / MPL-2.0

#### Design Decisions
- Implemented in Rust, uses **yyjson** C library for parsing backend
- Returns `bytes` not `str` from `dumps()` (optimizes for network/file I/O)
- Native support for dataclasses, datetime, UUID, numpy arrays
- AVX-512 utilized at runtime when available (wheels ship x86-64-v1 baseline)
- Circular reference detection (raises `JSONEncodeError` instead of hanging)
- Strict UTF-8 enforcement (no `ensure_ascii`)
- 64-bit integer support (optional 53-bit for JS compat via `OPT_STRICT_INTEGER`)

#### Performance vs Python alternatives

**Compact serialization (small 52 KiB fixture):**

| Library | Time |
|---------|------|
| orjson | 0.01 ms |
| json (stdlib) | 0.13 ms |

**Pretty-printing (large 489 KiB fixture):**

| Library | Time |
|---------|------|
| orjson | 0.45 ms |
| json (stdlib) | 24.42 ms |

That's 54x faster for pretty-printing large documents.

`orjson.loads()` is ~2x faster than `json.loads()`.

**vs ujson (calls/sec on 256 doubles):**

| Library | Encode | Decode |
|---------|--------|--------|
| orjson | 79,569 | 93,283 |
| ujson | 18,282 | 28,765 |
| json (stdlib) | 5,935 | 13,367 |

#### Production Status
- Supports CPython 3.10-3.15
- Multi-arch wheels: amd64, aarch64, arm7, ppc64le, s390x
- No open issue tracker (intentional signal/noise management)
- Widely used as the fastest Python JSON option

---

## Go Implementations

### sonic (Go)

- **URL:** https://github.com/bytedance/sonic
- **Stars:** 9.3k | **Maintained by:** ByteDance

#### Design Decisions

**JIT compilation** -- generates schema-specific opcodes at runtime:
- Integrated codec functions reduce function-call overhead
- Avoids "schema dependency and convenience losses" of static code generation
- Caches compiled functions in off-heap memory using open-addressing hash tables with RCU synchronization

**Adaptive SIMD:**
- Threshold-based: excludes strings under 16 bytes from SIMD path
- Combined with scalar instructions through conditional branch prediction
- Core computational functions compiled via Clang/LLVM, translated to plan9 assembly for Go runtime (asm2asm tool)

**Lazy-loading AST:**
- Inspired by gjson's single-key lookup efficiency
- Defers parsing until values are accessed
- Balances skipping benefits with full-parsing performance

**Register-based calling convention:**
- Reimplemented Go's stack-based convention with register-based parameter passing
- Global function table with static offsets

#### Performance (13 KB, 300+ keys, 6 layers)

| Operation | sonic | encoding/json | jsoniter |
|-----------|-------|---------------|---------|
| Generic Encode | 402 MB/s | 123 MB/s | 309 MB/s |
| Binding Encode | 2,079 MB/s | 793 MB/s | 650 MB/s |
| Generic Decode | 195 MB/s | 105 MB/s | 143 MB/s |
| Binding Decode | 400 MB/s | 117 MB/s | 371 MB/s |

Binding encode is 2.6x faster than encoding/json and 3.2x faster than jsoniter.

#### Production Usage
Deployed internally at ByteDance. JSON operations consumed up to 40% CPU in some services before sonic.

#### Key Trade-offs
- JIT adds startup latency for first use of each type
- C/Clang dependency for core functions
- Platform-specific (AMD64, ARM64)

---

### jsoniter (Go)

- **URL:** https://github.com/json-iterator/go
- **Stars:** 13.9k | **Status:** Archived (Dec 2025)

#### Design Decisions
- Drop-in replacement for encoding/json ("100% compatible")
- Single-pass scanning directly from byte stream
- Schema-based active parsing (uses known structure instead of passive tokenization)
- Buffer reuse to minimize allocation
- Fast-path string handling (bypasses escape processing when possible)

#### Performance

**Small payload:**

| Parser | ns/op | allocs/op |
|--------|-------|-----------|
| encoding/json | 3,151 | 6 |
| jsoniter (bind) | 844 | 4 |
| jsoniter (iterator) | 619 | 2 |

**Medium payload:**

| Parser | ns/op | allocs/op |
|--------|-------|-----------|
| encoding/json | 30,531 | 18 |
| jsoniter (bind) | 5,640 | 14 |
| jsoniter (iterator) | 4,966 | 4 |

**Large payload (counting array elements):**
- jsoniter: 48,737 ns/op, 0 B/op, 0 allocs/op
- encoding/json: 567,880 ns/op, 79,177 B/op, 4,918 allocs/op

#### Key Trade-offs
- Archived / no longer maintained
- Used by 406k dependents (massive inertia)
- Iterator API is lower-level but dramatically faster

---

### go-json (Go)

- **URL:** https://github.com/goccy/go-json

#### Design Decisions
- **Opcode VM**: creates instruction sequences per type on first encounter, caches them
  - Merges sequential opcodes (5 ops -> 3 ops) reducing switch branches
  - Recursion uses JMP not CALL (saves stack frames)
- **Type pointer dispatch**: extracts type addresses from interface{} values, caches optimized paths
- **NUL terminator trick**: appends NUL to input, enables checking termination + character in single comparison
- **Boundary check elimination**: pointer arithmetic instead of slice indexing
- **Slice-based type dispatch**: pre-allocated slice indexing when memory fits 2 MiB, fallback to atomic map

#### Performance
- Encoding: consistently faster than encoding/json and json-iterator
- Single allocation for encoding (the result []byte)
- sync.Pool buffer reuse

---

### fastjson (Go)

- **URL:** https://github.com/valyala/fastjson

#### Design Decisions
- Schemaless: parses arbitrary JSON without reflection or code generation
- **Zero-allocation**: benchmark shows 0 B/op, 0 allocs/op for basic parsing
- **Arena-based memory**: objects must be released before next Parse call
- Single-pass parse, then field extraction from parsed structure
- Dot-notation field access
- In-place modification (Set/Del operations)

#### Performance

| Dataset | fastjson | encoding/json (map) |
|---------|----------|---------------------|
| Small (190 B) | 548 MB/s | 26 MB/s |
| Large (28 KB) | 799 MB/s | 46 MB/s |
| Canada (2.2 MB) | 538 MB/s | 33 MB/s |
| Validation only (CITM) | 1,025 MB/s | -- |

#### Key Trade-offs
- References must not persist beyond next Parse call
- No io.Reader support
- No concurrent access without external synchronization
- Designed for RTB / JSON-RPC hot paths

---

### simdjson-go

- **URL:** https://github.com/minio/simdjson-go
- **Maintained by:** MinIO

#### Design Decisions
- Go port of simdjson C++ two-stage architecture
- Pure Go implementation (no CGo)
- Requires AVX2 + CLMUL (Intel Haswell 2013+ / AMD Ryzen+)
- Tape-based representation
- `WithCopyStrings(false)` for zero-copy string access (user must keep input buffer alive)
- Supports NDJSON parsing
- No 4 GB object limit

#### Performance

| Benchmark | encoding/json | simdjson-go | Speedup |
|-----------|--------------|-------------|---------|
| Apache_builds | 104 MB/s | 890 MB/s | 8.5x |
| Citm_catalog | 101 MB/s | 1,270 MB/s | 12.5x |
| Gsoc_2018 | 160 MB/s | 2,643 MB/s | 16.5x |
| Twitter | 95 MB/s | 1,073 MB/s | 11.3x |

Allocation reduction: 99.77% fewer allocations.
Achieves ~40-60% of C++ simdjson speed.

#### Key Trade-offs
- **Hard requirement** on AVX2 + CLMUL (no fallback for parsing)
- Serialized binary data can be deserialized on unsupported CPUs

---

### segmentio/encoding (Go)

- **URL:** https://github.com/segmentio/encoding

#### Design Decisions
- Drop-in replacement for encoding/json
- Emerged from production needs at Segment (data pipeline company)
- Zero-allocation focus: reduces heap from 1.80 MB to 0.02 MB (99.14% reduction)
- Allocation count: 76,600 -> ~100 (99.92% reduction)

#### Performance

| Metric | encoding/json | segmentio | Improvement |
|--------|--------------|-----------|-------------|
| Unmarshal time | 28.1 ms | 5.6 ms | 5x |
| Unmarshal speed | 69.2 MB/s | 349.6 MB/s | 5x |
| Marshal time | 6.40 ms | 3.82 ms | 1.7x |
| Marshal speed | 303 MB/s | 507 MB/s | 1.7x |

Also includes fast ISO 8601 date validation (no heap allocations), yielding ~5% CPU reduction in date-heavy workloads.

---

### OjG (Go)

- **URL:** https://github.com/ohler55/ojg

#### Design Decisions
- Optimized for huge, semi-structured data sets
- JSONPath implementation
- Generic type system with type-safe element handling
- SEN (Simple Encoding Notation) for streamlined JSON writing
- Reusable parser instances

#### Performance

| Operation | OjG | encoding/json | Speedup |
|-----------|-----|---------------|---------|
| String parse (reuse) | 17,881 ns/op | 55,949 ns/op | 3.1x |
| Reader parse | 13,610 ns/op | 63,015 ns/op | 4.6x |
| JSON format | 7,662 ns/op (0 allocs) | 78,762 ns/op | 10.3x |

---

## Zig

### std.json (Zig)

- **URL:** https://github.com/ziglang/zig (lib/std/json.zig)

#### Design Decisions

**Layered API:**
1. **Scanner** (low-level): tokenizes JSON input, returns slices directly from input buffer (zero-copy for unescaped strings/numbers)
2. **Reader** (mid-level): connects readers to scanners for streaming
3. **parseFromSlice / parseFromTokenSource** (high-level): deserializes directly into Zig struct types with compile-time type checking
4. **Value** (dynamic): runtime inspection of arbitrary JSON

**Memory management:**
- All parsing functions accept an explicit `allocator` parameter
- `parseFromSliceLeaky` variant for alternative lifetime management
- Caller controls memory source

**Zero-copy:**
- Scanner returns slices from input (Token.string, Token.number) -- no allocation when input buffer remains valid
- Strings with escape sequences require allocation for decoded form

**Stringify:**
- RFC 8259 conformant output via writers
- Formatting options (e.g., `whitespace: .indent_2`)

#### Key Trade-offs
- No SIMD acceleration
- Comptime type reflection enables schema-aware parsing without code generation
- Allocator-first design gives full control but requires manual management
- Standard library quality -- stable, well-tested, but not performance-focused

---

## Odin

### core/encoding/json (Odin)

- **URL:** https://github.com/odin-lang/Odin/tree/master/core/encoding/json

#### Architecture
Six-file module: marshal.odin, unmarshal.odin, parser.odin, tokenizer.odin, types.odin, validator.odin.

#### Design Decisions
- **Recursive descent parser** with single-token lookahead
- **Explicit allocator** parameter on all allocation-accepting procedures (defaults to `context.allocator`)
- Multi-spec support: JSON, JSON5, SJSON, MJSON via `#partial switch`
- **Fast-path string unquoting**: if no escape sequences found, clones unquoted slice without processing
- UTF-16 surrogate pair decoding for `\uXXXX` escapes
- Error handling via `(Value, Error)` tuples with `or_return` for early exit
- `defer` blocks for cleanup on error paths

#### Key Trade-offs
- No SIMD acceleration
- Manual memory management (Odin's explicit allocator model)
- Multi-spec support adds some branching overhead for strict JSON
- Clean, simple implementation prioritizing correctness

---

## Other Notable Projects

### Wuffs

- **URL:** https://github.com/google/wuffs
- **Language:** Wuffs (transpiles to C)

#### Design
- Memory-safe language with **compile-time** safety proofs (no runtime checks)
- **Hermetic**: cannot make system calls, allocate, or free memory
- JSON decoder uses O(1) memory with 3 x 32 KiB static buffers
- Token-based streaming: each token is a 64-bit value (16-bit length + continued bit + 46-bit type/value)
- Applies JSON Pointer filtering **during** parsing (not after)
- Can run in SECCOMP_MODE_STRICT sandbox

#### Performance (jsonptr tool)
- 13.9-18.3x faster than jq
- For targeted queries (`/features/10`): 488x faster than simdjson, 4069x faster than serde_json
  - Because Wuffs can stop after finding the target; DOM parsers must parse everything first
- Memory: 1,096 KB max RSS vs jq's 18,900 KB (17.2x reduction)

#### Key Insight
Numbers remain as strings (no StringToDouble/DoubleToString round-trip). This is a deliberate trade-off: if you don't need the numeric value, don't pay for the conversion.

#### Production
GIF decoder shipped in Google Chrome since June 2021 (M93).

---

### UltraJSON (Python)

- **URL:** https://github.com/ultrajson/ultrajson
- **Status:** Maintenance-only (security fixes + new Python versions)

The maintainers explicitly state: "UltraJSON's architecture is fundamentally ill-suited to making changes without risk of introducing new security vulnerabilities." They recommend migrating to orjson.

#### Performance (CPython 3.11.3, calls/sec)

| Scenario | ujson | orjson | stdlib |
|----------|-------|--------|--------|
| 256 doubles (encode) | 18,282 | 79,569 | 5,935 |
| 256 strings (encode) | 44,769 | 125,920 | 23,565 |
| Complex nested dict | 55 | 282 | 26 |

orjson is 4-5x faster than ujson across the board.

---

### FlatBuffers

- **URL:** https://github.com/google/flatbuffers
- **By:** Google

Not a JSON library per se, but relevant as the end state of "skip intermediate representation":
- **Zero-copy**: read values directly from serialized buffer without unpacking
- Schema-based (.fbs files) with code generation for 16+ languages
- No parsing step -- data accessed in-place from wire format
- Forwards/backwards compatible
- Represents what JSON parsers aspire to: direct access without deserialization

---

## Cross-Cutting Techniques

### SIMD Structural Classification

**Technique:** Process 64 bytes at a time to classify characters into structural (`{`, `}`, `[`, `]`, `:`, `,`), whitespace, quotes, and backslashes.

**How it works (simdjson):**
1. Load 64 bytes into SIMD registers
2. Use VPSHUFB (packed shuffle bytes) as a lookup table: split each byte's high/low nibble, look up in two 16-entry tables, AND the results
3. Produces 64-bit bitmask where each bit indicates whether corresponding byte is structural/whitespace/etc.
4. Use PCLMULQDQ to compute prefix XOR for quote pairing (determines which characters are inside strings)

**Who uses it:** simdjson, simd-json, simdjson-go, sonic (selectively), sonic-rs (selectively)

---

### Tape-Based Representation

**Concept:** Instead of a tree of heap-allocated nodes, store parsed JSON as a flat array of tagged 64-bit words.

**Advantages:**
- Cache-friendly sequential access
- No pointer chasing
- Constant-size per element (8 or 16 bytes)
- O(1) skip of containers via stored offsets

**Disadvantages:**
- Immutable (modifications require rebuild)
- Forward-only access patterns
- Must parse entire document upfront (unless combined with On-Demand)

**Who uses it:** simdjson, simd-json (tape API), simdjson-go

---

### Zero-Copy Parsing

**Concept:** Return string views/slices that point into the original input buffer rather than allocating new strings.

**Variants:**
- **Full zero-copy** (simdjson On-Demand, fastjson Go): all strings reference input
- **Selective zero-copy** (serde_json borrowed, Zig std.json): unescaped strings reference input, escaped strings require allocation
- **Copy-on-write** (sonic-rs LazyValue): defer parsing of subtrees, return raw JSON slices
- **In-situ parsing** (yyjson, RapidJSON): modify input buffer in place (overwrite escape sequences with decoded chars + null terminators)

**Key constraint:** input buffer must remain alive and unmodified for the lifetime of all references.

---

### Schema-Aware / On-Demand Parsing

**Concept:** Use compile-time or runtime knowledge of the expected schema to skip fields that aren't needed.

**Implementations:**
- **simdjson On-Demand:** Stage 1 indexes structure, Stage 2 runs lazily per-access
- **sonic-rs get/get_unchecked:** SIMD-accelerated field extraction with path-based queries
- **sonic Go lazy-loading:** parse on access, skip on skip
- **Wuffs jsonptr:** apply JSON Pointer filter during tokenization (never parse skipped subtrees)
- **jsoniter schema-based:** uses known struct layout to drive parsing (active vs passive)
- **Zig std.json parseFromSlice:** compile-time struct type drives which fields to extract

**Performance impact:** Can be orders of magnitude faster when extracting a few fields from large documents. Wuffs demonstrates 488x speedup over simdjson for single-field extraction because simdjson (DOM mode) must still parse everything.

---

### Direct-to-Wire Serialization

**Concept:** Write JSON output directly to a writer/buffer without constructing intermediate Value/DOM objects.

**Implementations:**
- **serde_json Serializer trait:** Rust structs serialize directly to writer via generated code
- **orjson:** Rust directly serializes Python objects to bytes (no intermediate JSON Value)
- **sonic Go binding encode:** JIT-generated code writes struct fields directly to output buffer at 2,079 MB/s
- **OjG:** JSON formatting with 0 allocations (7,662 ns/op)
- **go-json opcode VM:** executes type-specific opcode sequences that write directly to pooled buffers

**Key insight:** The fastest serialization path is `struct -> bytes` with no intermediate `Value` object. Every implementation that achieves top serialization speeds does this.

---

### SIMD UTF-8 Validation

**The Keiser-Lemire Algorithm** (arXiv:2010.03090):
- Uses SIMD shuffle instructions as lookup tables for UTF-8 state machine transitions
- Validates 32/64 bytes per iteration
- >10x faster than scalar validation in standard libraries
- Works on AVX2, SSE4.2, NEON
- Integrated into simdjson Stage 1 (validation is "free" -- happens during structural detection)
- simdjson achieves 13 GB/s for pure UTF-8 validation

**Key insight:** UTF-8 validation can be decomposed into independent per-byte checks that map naturally to SIMD parallel lookup operations.

---

### Arena Allocation

**Concept:** Allocate all parsed values from a contiguous memory arena instead of individual heap allocations.

**Benefits:**
- Single allocation for entire document
- Excellent cache locality
- O(1) deallocation (free the arena)
- Reduced allocator pressure / GC pressure

**Implementations:**
- **sonic-rs:** arena for Document values, arrays instead of HashMaps for objects
- **fastjson (Go):** arena-based, objects released on next Parse call
- **yyjson:** contiguous memory pools for immutable documents
- **simdjson:** tape is effectively an arena (single allocation for all tape elements + string tape)

---

### JIT Compilation for JSON

**Concept:** Generate optimized machine code at runtime based on the specific struct types being serialized/deserialized.

**Only major implementation:** sonic (Go) by ByteDance.

**How it works:**
1. First encounter with a type triggers JIT compilation of schema-specific opcodes
2. Core computational functions compiled via Clang/LLVM
3. Assembly translated to plan9 format for Go runtime (asm2asm tool)
4. Cached in off-heap memory with RCU synchronization
5. Register-based parameter passing (bypasses Go's stack-based convention)

**Result:** 2,079 MB/s binding encode vs encoding/json's 793 MB/s.

**Trade-off:** Startup latency on first use of each type; C/Clang build dependency.

---

### Streaming / Incremental Parsing

**Concept:** Process JSON without loading entire document into memory.

**Approaches:**
1. **SAX-style events** (RapidJSON): callback on each element
2. **Token stream** (Wuffs, Zig std.json Scanner): yield tokens from chunks
3. **Iterator-based** (simdjson On-Demand, jsoniter): forward-only traversal
4. **NDJSON** (simdjson, simdjson-go): parse newline-delimited JSON documents independently

**Wuffs' CSP model:** Four connected routines operating on buffers (stdin -> byte buffer -> token buffer -> output), yielding when buffers drain/fill. O(1) memory regardless of input size.

**Key trade-off:** Streaming parsers sacrifice random access and typically can't validate the full document upfront. simdjson On-Demand is a hybrid: Stage 1 validates structure of full document, then Stage 2 streams lazily.

---

## Lessons Learned & Post-Mortems

### From simdjson
- **Branch-free Stage 1 is critical**: mispredicted branches destroy SIMD throughput. Stage 1 processes 64 bytes per iteration with zero branches.
- **Stage 2 is the bottleneck**: as Stage 1 became near-optimal, the branchy validation/construction pass became dominant. Future work targets Stage 2 optimization.
- **PCLMULQDQ for quote pairing** was a novel invention by Langdale. Demonstrates that uncommon instructions can unlock entirely new algorithmic approaches.
- **Tape format enables skipping** but is immutable. Acceptable trade-off for read-heavy workloads (which is most JSON consumption).

### From sonic (ByteDance)
- JSON operations consumed **up to 40% CPU** in some production services before sonic.
- JIT eliminates the choose-two triangle of {fast, generic, no-codegen}. You can have all three at the cost of startup latency.
- **SIMD is not always faster**: for strings under 16 bytes, the overhead of SIMD loads exceeds scalar processing. Threshold-based dispatch is essential.
- Go's stack-based calling convention is a significant bottleneck for hot codec paths. Reimplementing with registers yielded measurable gains.

### From yyjson
- **You don't need explicit SIMD instructions** to be fast. Careful scalar code with high ILP and good branch prediction can match or beat SIMD on modern OoO cores (especially Apple Silicon).
- Stringify performance is often neglected. yyjson's stringify is 2-3x faster than simdjson's.

### From orjson
- Returning `bytes` instead of `str` from dumps() eliminates a copy on every serialization in the common case (writing to network/file).
- Using yyjson's C parser from Rust gives best-of-both-worlds: C parsing speed with Rust memory safety for the serialization layer.

### From Wuffs
- **If you don't need the DOM, don't build it.** Token-based streaming with O(1) memory is viable and can be orders of magnitude faster for targeted queries.
- Numbers as strings (no float conversion) is a legitimate strategy when downstream consumers don't need numeric values.
- Compile-time safety proofs can eliminate all runtime safety overhead. "As safe as Rust, as fast as C."

### From ujson
- C-based JSON libraries without memory safety are a liability. ujson's maintainers concluded their architecture was "fundamentally ill-suited to making changes without risk of introducing new security vulnerabilities." They recommend orjson.

### From segmentio/encoding
- At scale, JSON marshaling is a top CPU consumer. segmentio saw 99.14% heap reduction and 5x unmarshal speedup from careful allocation elimination.
- ISO 8601 date parsing in JSON payloads was a hidden 5% CPU tax due to time.Parse() error handling allocations.

### From jsoniter
- Despite 406k dependents and 13.9k stars, the project was archived in Dec 2025. Maintenance burden of "100% compatible" drop-in replacements is unsustainable long-term.
- Single-pass scanning + schema-based active parsing remains the best general approach for strongly-typed deserialization.

---

## Benchmark Context & Methodology Notes

**Caveat emptor.** All benchmark numbers in this document should be treated as directional, not absolute. Performance varies dramatically with:

1. **Document characteristics**: string-heavy vs numeric-heavy, nesting depth, key count, document size
2. **Hardware**: Intel vs AMD vs Apple Silicon; cache sizes; SIMD ISA availability
3. **Compiler and flags**: GCC vs Clang, -O2 vs -O3, -march=native
4. **Access pattern**: full DOM parse vs selective field extraction vs validation-only
5. **Allocation strategy**: system malloc vs jemalloc vs mimalloc vs arena
6. **Workload**: single large document vs many small documents vs NDJSON stream

**Common benchmark datasets:**
- `twitter.json` (~630 KB): string-heavy, moderate nesting, real-world API response
- `citm_catalog.json` (~1.7 MB): mixed types, deep nesting
- `canada.json` (~2.2 MB): numeric-heavy (GeoJSON coordinates)
- `gsoc-2018.json`: string-heavy

**The simdjson paper's methodology** is the gold standard: reports GB/s on specified hardware with specified compiler flags, measures instruction count (not just wall time), and tests across multiple document types to show where advantages hold and where they don't.

**Rule of thumb from jsoniter:** "Always benchmark with your own workload. The result depends heavily on the data input."

---

## Summary: Performance Tiers (Approximate, Parse Throughput)

| Tier | Throughput | Representatives |
|------|-----------|-----------------|
| Tier 0: SIMD-accelerated | 1-3+ GB/s | simdjson, yyjson, simdjson-go, sonic-rs |
| Tier 1: Optimized native | 400-900 MB/s | serde_json, sonic (Go), fastjson (Go) |
| Tier 2: Fast replacements | 100-400 MB/s | jsoniter, go-json, segmentio, RapidJSON |
| Tier 3: Standard libraries | 30-100 MB/s | encoding/json (Go), std.json (Zig), json (Python) |

These tiers are rough guides. A Tier 2 library with schema-aware parsing on a targeted query can outperform a Tier 0 library doing full DOM parse.


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-a89bc79192369b25c.jsonl`
