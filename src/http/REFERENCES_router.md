# HTTP Router Implementation References

State-of-the-art survey of high-performance HTTP routing across systems languages.
Last updated: 2026-03-21.

---

## Table of Contents

1. [The Dominant Pattern: Radix Trees](#the-dominant-pattern-radix-trees)
2. [Implementation Survey](#implementation-survey)
   - [matchit (Rust)](#matchit-rust)
   - [httprouter (Go)](#httprouter-go)
   - [find-my-way (Node.js)](#find-my-way-nodejs)
   - [path-tree (Rust)](#path-tree-rust)
   - [wayfind (Rust)](#wayfind-rust)
   - [R3 (C)](#r3-c)
   - [http.zig (Zig)](#httpzig-zig)
   - [routez (Zig)](#routez-zig)
   - [odin-http (Odin)](#odin-http-odin)
   - [Go 1.22 ServeMux](#go-122-servemux)
   - [actix-router (Rust)](#actix-router-rust)
   - [Kong atc-router (Rust/Lua)](#kong-atc-router-rustlua)
3. [Design Decisions & Trade-offs](#design-decisions--trade-offs)
   - [Method Dispatch: Separate Trees vs Single Tree](#method-dispatch-separate-trees-vs-single-tree)
   - [Static vs Dynamic Segment Priority](#static-vs-dynamic-segment-priority)
   - [Route Conflict Detection](#route-conflict-detection)
   - [Path Parameter Extraction](#path-parameter-extraction)
   - [Wildcard & Catch-all Patterns](#wildcard--catch-all-patterns)
   - [Compile-time Route Compilation](#compile-time-route-compilation)
4. [Cache-Friendly Data Structures](#cache-friendly-data-structures)
   - [Adaptive Radix Tree (ART)](#adaptive-radix-tree-art)
   - [HAT-trie](#hat-trie)
   - [Poptrie](#poptrie)
   - [Masstree](#masstree)
5. [SIMD-Accelerated Matching](#simd-accelerated-matching)
6. [Benchmark Summary](#benchmark-summary)
7. [Applicable Research Papers](#applicable-research-papers)
8. [Design Recommendations](#design-recommendations)

---

## The Dominant Pattern: Radix Trees

Nearly every high-performance HTTP router uses a **compressed radix tree** (also called compact prefix tree or Patricia trie). The core insight: URL paths are hierarchical strings that share prefixes (`/api/users`, `/api/posts`). A radix tree exploits this by storing shared prefixes once, reducing the search space from O(n) routes to O(m) where m is the length of the path being matched.

Key properties:
- Nodes store compressed path segments, not individual characters
- Branching occurs only at points where registered routes diverge
- Lookup cost is proportional to path length, not route count
- Child nodes are typically priority-ordered by number of descendants with handlers

---

## Implementation Survey

### matchit (Rust)

- **URL**: https://github.com/ibraheemdev/matchit
- **Language**: Rust
- **Used by**: axum (tokio-rs), Pavex
- **Production exposure**: Very high (axum is one of the most popular Rust web frameworks)

**Design decisions**:
- Zero-copy: operates on borrowed `&str` slices, no allocations during matching
- Direct port of httprouter's algorithmic approach, adapted for Rust's ownership model
- Single radix trie per Router instance (method dispatch handled externally by frameworks)
- Child nodes at each level ordered by **priority** = count of registered values in subtree
- Priority ordering maximizes chance of correct branch on first attempt

**Route syntax**:
- Named parameters: `/{id}` -- matches until next `/` or end of path
- Catch-all: `/{*rest}` -- matches remaining path, must be terminal
- Prefix/suffix on params: `/{x}suffix`, `/prefix{x}` allowed
- Escape braces: `{{` and `}}`

**Conflict resolution**:
- Static segments have highest priority
- One parameterized group (with prefix/suffix) per segment
- One dynamic segment (standalone param or catch-all) per segment
- Ambiguous combinations trigger `InsertError` at registration time
- Catch-all conflicts with suffixed params

**Benchmarks** (130 registered routes):
| Router           | Time      |
|-----------------|-----------|
| **matchit**     | **2.45 us** |
| gonzales        | 4.26 us   |
| path-tree       | 4.87 us   |
| wayfind         | 4.94 us   |
| route-recognizer| 49.2 us   |
| regex-based     | 421.76 us |

matchit is ~170x faster than regex-based routing.

**API**:
```rust
let mut router = Router::new();
router.insert("/users/{id}", handler)?;
let matched = router.at("/users/42")?;
assert_eq!(matched.params.get("id"), Some("42"));
```

---

### httprouter (Go)

- **URL**: https://github.com/julienschmidt/httprouter
- **Language**: Go
- **Used by**: Gin, countless Go projects
- **Production exposure**: Extremely high (Gin is the most popular Go web framework)

**Design decisions**:
- Compressing dynamic trie (radix tree) with separate trees per HTTP method
- **Explicit matching**: a request matches exactly one or zero routes (no ambiguity)
- **Zero garbage**: matching and dispatching generate zero bytes of garbage
- Heap allocations only when building param key-value slices
- Using 3-arg API with param-free paths: zero heap allocations per request
- Child nodes ordered by priority (count of handlers in descendants)
- Nodes traversed top-to-bottom, left-to-right within priority ordering

**Route syntax**:
- Named params: `/:name` -- matches exactly one path segment
- Catch-all: `/*filepath` -- must terminate the pattern, matches all remaining segments

**Conflict resolution**:
- Cannot register both `/user/new` (static) and `/user/:user` (param) for same method
- Strict path segment separation enforced
- Panics on conflicting routes

**Performance**: Referenced external benchmarks at https://github.com/julienschmidt/go-http-routing-benchmark

**Benchmark data** (from go-router-benchmark, ns/op for static routes):
| Router      | Root path | Deep path (10 segments) |
|------------|-----------|------------------------|
| httprouter | 8.3       | 10.6                   |
| echo       | 18.5      | 50.6                   |
| gin        | 27.7      | 29.6                   |
| chi        | 160       | 183.6                  |

---

### find-my-way (Node.js)

- **URL**: https://github.com/delvedor/find-my-way
- **Language**: JavaScript (Node.js)
- **Used by**: Fastify, Restify
- **Production exposure**: Very high (Fastify is a top Node.js framework)

**Design decisions**:
- Highly performant radix tree (compact prefix tree)
- Separate tree per HTTP method
- Static routes always inserted before parametric and wildcard (three-tier priority)
- Supports versioned routing via `Accept-Version` header (semver-based, with perf cost)
- Custom constraint system for routing beyond path matching

**Route syntax**:
- Static: `/example`
- Parametric: `/example/:userId`
- Multi-param with separators: `/near/:lat-:lng/radius/:r`
- Wildcard: `/example/*`
- Regex constraints: `/example/:file(^\\d+).png`
- Optional params: `:id?`

**Configuration options**:
- `ignoreTrailingSlash`: map `/foo/` and `/foo` identically
- `ignoreDuplicateSlashes`: normalize `//foo` to `/foo`
- `maxParamLength`: default 100 chars, exceeding invokes default route
- `caseSensitive`: default true
- `allowUnsafeRegex`: bypass safe-regex2 detection

**Key features**:
- Route removal via `off(methods, path, [constraints])`
- `prettyPrint()` for tree visualization/debugging
- `findRoute()` / `hasRoute()` introspection
- Custom query string parser (defaults to `fast-querystring`)

**Performance**: Handles ~2x more load than Express due to radix tree vs linear matching.

---

### path-tree (Rust)

- **URL**: https://github.com/viz-rs/path-tree
- **Language**: Rust
- **Production exposure**: Used by Viz framework

**Design decisions**:
- Synthesizes ideas from 6 projects: rax, httprouter, echo, path-to-regexp, gofiber, trekjs
- Six parameter kinds:
  - `Normal` (`:name`) -- matches single segment
  - `Optional` (`:name?`) -- optional segment
  - `OptionalSegment` (`:name?/`) -- optional with boundary
  - `OneOrMore` (`+` or `:name+`) -- greedy, includes `/`
  - `ZeroOrMore` (`*` or `:name*`) -- optional greedy
  - `ZeroOrMoreSegment` (`/*/`) -- multi-segment wildcard
- Supports parameter delimiters: hyphens, periods, tildes, underscores
  - e.g., `:day-:month-:year`, `:filename.:ext`
- Escape sequences for literal special chars: `:a\:`
- Auto-numbering for anonymous params: `*.*` creates `*1` and `*2`

**Benchmark**: ~4.87 us for 130 routes (see matchit comparison table above)

---

### wayfind (Rust)

- **URL**: https://crates.io/crates/wayfind
- **Language**: Rust
- **Production exposure**: Newer crate, less production use

**Design decisions**:
- Compressed radix trie (same backbone as most Rust routers)
- **Hybrid search strategy**: most routers use "first match wins" or "best match wins" (backtracking). wayfind uses a hybrid where backtracking cost is only paid when inline parameters are used, and only for that segment
- Inspired by matchit (performance) and path-tree (testing/display)
- Goal: remain competitive with fastest libraries while offering advanced features

**Benchmark**: ~4.94 us for 130 routes

---

### R3 (C)

- **URL**: https://github.com/c9s/r3
- **Language**: C
- **Production exposure**: Moderate (various C/C++ web projects)

**Design decisions**:
- Compiles route paths into prefix trie at startup (immutable after compilation)
- Two-phase: `r3_tree_insert()` then `r3_tree_compile()` before matching
- PCRE2 for complex regex patterns
- **Opcode compilation**: simple patterns (`[a-z]+`, `\d+`, `\w+`, `[^/]+`, `.*`) converted to specialized scanners, bypassing PCRE2 overhead
- Route syntax: `"/blog/post/{id}"`, `"/user/{userId:\\d+}"` (inline regex)
- Explicit memory lifecycle: `r3_tree_create(capacity)`, `r3_tree_free()`
- Thread-safe concurrent reads after compilation
- Graphviz visualization of compiled route trees

**Benchmarks**:
- **11.46 million matches/second** (336 routes, 5M iterations)
- vs Rails router: ~10,462 iter/sec (~1000x faster)
- vs Router Journey: ~9,933 iter/sec

---

### http.zig (Zig)

- **URL**: https://github.com/karlseguin/http.zig
- **Language**: Zig
- **Production exposure**: Growing Zig ecosystem adoption

**Design decisions**:
- Written without `std.http.Server` (deemed too slow, assumes well-behaved clients)
- Route syntax: colon-prefixed params (`/api/user/:id`)
- Parameter extraction via `req.param("id")` returning optional string
- Route-associated data via configuration
- Arena allocators for request/response memory (freed after each request)
- Supports all standard HTTP verbs plus `all()` catch-all

**Benchmarks**: 140K requests/second on M2 (basic request)

---

### routez (Zig)

- **URL**: https://github.com/Vexu/routez
- **Language**: Zig
- **Status**: Archived (read-only since Feb 2023)

**Design decisions**:
- Route patterns with named params: `/post/{post_num}/?` (optional trailing slash)
- Tuple-based route definitions mapping paths to handlers
- Evented I/O concurrency model (`io_mode = .evented`)
- Thread-safe state via `std.atomic`

---

### odin-http (Odin)

- **URL**: https://github.com/laytan/odin-http
- **Language**: Odin
- **Status**: Beta, heavily in development

**Design decisions**:
- Uses **Lua pattern matching** for route definitions (simpler than regex, Odin has no regex impl)
- Routes evaluated **sequentially in registration order** (linear scan)
- Pattern examples: `/users/(%w+)/comments/(%d+)`, `(.*)` for catch-all
- Parameters accessed via `req.url_params[]` array indexing
- Priorities: Linux performance (production target)

**Note**: Linear route matching makes this unsuitable as a reference for high-performance routing. The Lua pattern approach is pragmatic for Odin's ecosystem but not competitive at scale.

---

### Go 1.22 ServeMux

- **URL**: https://go.dev/blog/routing-enhancements
- **Language**: Go (stdlib)
- **Production exposure**: Universal (Go standard library)

**Design decisions**:
- **"Most specific wins"** precedence: pattern matching strict subset of requests wins
- Method matching in pattern: `GET /posts/{id}`
- Single-segment wildcards: `{id}`, multi-segment: `{pathname...}`
- Exact path anchor: `{$}` matches only trailing slash
- **Specificity hierarchy**:
  1. Literal segments beat wildcards
  2. Method-specific beats method-agnostic
  3. Host-specific beats host-agnostic
  4. More literal segments = more specific

**Conflict detection**:
- Two patterns conflict if they overlap but neither is more specific
- Conflict detection at registration time (panics, not runtime)
- Uses an index to avoid O(n^2) pairwise checking
- Segment-by-segment comparison algorithm

**Parameter extraction**: `req.PathValue("id")`, `req.SetPathValue("key", "value")`

---

### actix-router (Rust)

- **URL**: https://crates.io/crates/actix-router
- **Language**: Rust
- **Used by**: actix-web, ntex
- **Production exposure**: Very high

**Design decisions**:
- Pattern syntax compiled to regex, with common cases on a **fast path** avoiding regex engine
- Segment-based matching: `/user/` is NOT a prefix of `/user/123/456`
- Max 16 dynamic segments per resource definition
- Routes matched in registration order
- `ResourceDef` compiles patterns; `Router` stores and dispatches

---

### Kong atc-router (Rust/Lua)

- **URL**: https://github.com/Kong/atc-router
- **Language**: Rust (with LuaJIT FFI bindings)
- **Used by**: Kong Gateway 3.0+
- **Production exposure**: Very high (Kong is a major API gateway)

**Design decisions**:
- Custom DSL for routing expressions parsed by Rust `pest` library (~40 lines grammar)
- Expression-based matching: `lower(http.path) == "/foo/bar"`, `http.path ~ r#"/foo/\d+"#`
- Operators: exact (`==`), prefix (`^=`), suffix (`=^`), regex (`~`), CIDR ranges
- Priority-based evaluation (descending order)
- Condition-triggered partial reconstruction (avoids full rebuild)
- Shared frontend/backend via WASM (`wasm-bindgen`)

**Benchmarks**:
- Route construction: 75% reduction (20s to 5s for 10K rules)
- P99 reconstruction: 1.5s to 0.1s

---

## Design Decisions & Trade-offs

### Method Dispatch: Separate Trees vs Single Tree

**Separate tree per method** (httprouter, find-my-way, most high-perf routers):
- Reduces search space before tree traversal begins
- More space-efficient than method->handler maps at every node
- Independent routing per method enables better priority ordering

**Single tree with method maps** (some simpler routers):
- Single data structure to manage
- Shared structure for paths registered across multiple methods
- Simpler code at the cost of larger nodes

**Verdict**: Separate trees per method is the dominant approach in high-performance routers. The search space reduction before traversal outweighs the minor memory duplication.

### Static vs Dynamic Segment Priority

All surveyed routers agree: **static segments always take priority over dynamic/parametric segments**, which take priority over wildcards/catch-alls.

Priority ordering: `static > parametric > wildcard/catch-all`

This is enforced both at insertion time (find-my-way inserts static before parametric) and at match time (static children checked first).

### Route Conflict Detection

Three approaches observed:

1. **Panic/error at registration** (httprouter, matchit, Go 1.22 ServeMux): strictest. Prevents ambiguous routes from being registered. Go 1.22 uses segment-by-segment specificity comparison with indexed conflict checking to avoid O(n^2).

2. **First match wins** (actix-router, odin-http): routes matched in registration order. Simple but order-dependent, fragile.

3. **Most specific wins** (Go 1.22 ServeMux): mathematically rigorous. Pattern P1 beats P2 if P1 matches a strict subset of P2's requests. If neither is more specific, they conflict and panic.

### Path Parameter Extraction

**Zero-copy / zero-allocation strategies**:
- **matchit**: Returns borrowed `&str` slices into the original path. No copies, no allocation for the parameter values themselves.
- **httprouter**: Pre-allocated `Params` slice. Zero garbage during matching with 3-arg API.
- **R3**: `match_entry` struct populated during matching, caller manages lifecycle.

**Common pattern**: Parameters stored as `(key, start_offset, end_offset)` tuples referencing the original path string, avoiding allocation of new strings.

### Wildcard & Catch-all Patterns

| Router        | Named param   | Catch-all         | Optional | Regex constraint |
|--------------|---------------|-------------------|----------|-----------------|
| matchit      | `{id}`        | `{*rest}`         | No       | No              |
| httprouter   | `:name`       | `*filepath`       | No       | No              |
| find-my-way  | `:name`       | `*`               | `:id?`   | `(:file(\\d+))` |
| path-tree    | `:name`       | `*` / `:name*`    | `:name?` | No              |
| R3           | `{name}`      | via regex         | No       | `{id:\\d+}`     |
| Go 1.22      | `{name}`      | `{name...}`       | No       | No              |

### Compile-time Route Compilation

**Phoenix (Elixir/BEAM)**: The gold standard. Routes defined via macros expand to pattern-matching clauses at compile time. The BEAM VM's pattern matching engine then handles dispatch with near-zero overhead. `~p` sigil provides compile-time verification that referenced paths exist in the router.

**R3 (C)**: Two-phase approach. Routes inserted, then `r3_tree_compile()` optimizes the trie, compiles regex to bytecode, and produces an immutable read-only structure for concurrent matching. Simple regex patterns compiled to opcodes bypassing PCRE2.

**General principle**: Build the tree at startup, optimize/compile it, then treat it as immutable during request handling. This is what most high-perf routers do implicitly -- the tree is fully built before the first request.

---

## Cache-Friendly Data Structures

### Adaptive Radix Tree (ART)

- **Paper**: Leis et al., "The Adaptive Radix Tree: ARTful Indexing for Main-Memory Databases" (ICDE 2013)
- **URL**: https://db.in.tum.de/~leis/papers/ART.pdf

**Core idea**: Adapt node size to actual fanout using 4 node types:

| Type    | Children | Size    | Lookup strategy |
|---------|----------|---------|----------------|
| Node4   | 1-4      | 36B     | Linear scan (fits one cache line) |
| Node16  | 5-16     | ~160B   | **SIMD parallel comparison** (SSE) |
| Node48  | 17-48    | 640B    | 256-byte index array -> 48 pointers |
| Node256 | 49-256   | 2KB     | Direct array indexing `child_ptrs[c]` |

**SIMD in Node16**: Set vector of repeated search byte, `_mm_cmpeq_epi8` for parallel comparison of all 16 keys, mask invalid entries, `ctz` (count trailing zeros) to find match index. No branches except null check.

**Compression techniques**:
- **Lazy expansion**: Collapse single-child chains ending in leaves into one node storing key suffix
- **Path compression**: Compress single-child chains not ending in leaves, store prefix in final multi-child node

**Performance**: Competitive with hash tables on point lookups. ~50% faster than chained hash tables with skewed access (cache locality). Less than half the space of hash+tree hybrids for TPC-C workloads.

**Applicability to HTTP routing**: ART's adaptive node sizing is directly applicable. Most URL path segments have low fanout (2-10 children), making Node4/Node16 dominant. The SIMD search in Node16 is particularly relevant -- most router nodes would fall in this range.

### HAT-trie

- **Paper**: Askitis & Sinha, "HAT-Trie: A Cache-Conscious Trie-Based Data Structure For Strings" (2007)
- **URL**: https://github.com/Tessil/hat-trie (C++ implementation)

**Core idea**: Burst-trie where leaf nodes use cache-conscious array hash tables instead of linked lists.

- Strings stored contiguously in arrays with length prefixes
- Single pointer indirection (vs multiple for linked lists)
- Burst heuristic: when container exceeds threshold, split into trie nodes
- Two node types: Pure (single parent) and Hybrid (multiple parents)

**Performance**: Up to 80% faster than burst-trie, 70% less memory.

**Applicability**: Less directly applicable to HTTP routing than ART. Better suited for full string dictionaries. The cache-conscious array storage principle is valuable though.

### Poptrie

- **Paper**: Asai & Ohara, "Poptrie: A Compressed Trie with Population Count" (SIGCOMM 2015)
- **URL**: https://conferences.sigcomm.org/sigcomm/2015/pdf/papers/p57.pdf

**Core idea**: Multiway trie using `POPCNT` instruction on bit-vector indices for descendant nodes, compressing the structure to fit in CPU cache.

- Direct pointing to skip sparse subtrees
- Leaf bit-vector compression reduces memory to <1/3
- Route aggregation for common prefixes

**Performance**: 174-240+ million lookups/second (single core, 500K-800K routes). 4-578% faster than Tree BitMap, DXR, SAIL.

**Applicability**: Designed for IP routing (fixed-length binary keys), but the POPCNT-based indexing technique could inspire HTTP router optimizations for nodes with many children.

### Masstree

- **Paper**: Mao et al., "Cache Craftiness for Fast Multicore Key-Value Storage" (EuroSys 2012)

**Core idea**: Trie-like concatenation of B+-trees. Each trie node is a B+-tree. Combines trie's prefix handling with B+-tree's cache-friendly range representation.

**Applicability**: Over-engineered for HTTP routing. Relevant for understanding hybrid trie/tree approaches.

---

## SIMD-Accelerated Matching

### In ART (Node16)

The most directly applicable SIMD technique for routing. Using SSE2/AVX2:

1. Broadcast search byte to all SIMD lanes
2. Parallel comparison with `_mm_cmpeq_epi8` against stored keys
3. Mask out invalid entries (entries beyond current child count)
4. `ctz` on result bitmask to find matching index

This searches 16 children in a single instruction cycle vs 16 comparisons.

### SIMD-Matcher (ACM 2022)

- **Paper**: "SIMD-Matcher: A SIMD-based Arbitrary Matching Framework" (ACM TACO 2022)
- **URL**: https://dl.acm.org/doi/fullHtml/10.1145/3514246

Fixed high-fanout trie nodes with varying span, layout optimized for SIMD. Achieves 2.7x average speedup over GenMatcher, 6.17x memory reduction. Primarily for packet classification but techniques apply to path matching.

### Practical SIMD for HTTP Routing

Most HTTP routers do NOT use SIMD today. The opportunity exists in:
- **Segment comparison**: Compare path segments against node labels using SIMD string comparison
- **Child node search**: ART-style parallel key lookup in nodes with 5-16 children
- **Slash detection**: Find `/` separators in paths using SIMD byte scanning (similar to how SIMD JSON parsers find structural characters)

The main barrier: most router hot paths are already fast enough (~2-10 us for 130 routes) that SIMD gains would be marginal. SIMD becomes more valuable at scale (1000+ routes, very deep paths).

---

## Benchmark Summary

### Rust Routers (130 registered routes, full match cycle)

| Router            | Time (us) | Notes |
|-------------------|-----------|-------|
| matchit           | 2.45      | Zero-copy, used by axum |
| gonzales          | 4.26      | |
| path-tree         | 4.87      | Used by Viz |
| wayfind           | 4.94      | Hybrid search strategy |
| route-recognizer  | 49.2      | NFA-based |
| routefinder       | 70.6      | |
| regex-based       | 421.76    | naive regex |

### Go Routers (ns/op, static root path)

| Router      | ns/op |
|------------|-------|
| httprouter | 8.3   |
| denco      | 9.0   |
| echo       | 18.5  |
| gin        | 27.7  |
| bunrouter  | 20.3  |
| chi        | 160   |
| gorilla    | 374.9 |

### C Router

| Router | Matches/sec   | Notes |
|--------|--------------|-------|
| R3     | 11.46 million | 336 routes, compiled trie |

### Cross-Language Throughput (approximate, not directly comparable)

| Implementation | Requests/sec | Language | Notes |
|---------------|-------------|----------|-------|
| http.zig      | 140K        | Zig      | M2, basic request |
| Kong 3.0      | N/A         | Rust/Lua | 75% faster route construction |

---

## Applicable Research Papers

1. **"The Adaptive Radix Tree: ARTful Indexing for Main-Memory Databases"**
   Leis, Kemper, Neumann (ICDE 2013)
   https://db.in.tum.de/~leis/papers/ART.pdf
   Key contribution: Adaptive node sizing (4/16/48/256), SIMD in Node16, lazy expansion, path compression.

2. **"Poptrie: A Compressed Trie with Population Count for Fast and Scalable Software IP Routing Table Lookup"**
   Asai, Ohara (SIGCOMM 2015)
   https://conferences.sigcomm.org/sigcomm/2015/pdf/papers/p57.pdf
   Key contribution: POPCNT-based indexing for cache-efficient trie traversal. 174-240M lookups/sec.

3. **"HAT-Trie: A Cache-Conscious Trie-Based Data Structure For Strings"**
   Askitis, Sinha (2007)
   https://www.researchgate.net/publication/262410440
   Key contribution: Cache-conscious leaf containers using array hash tables. 80% faster than burst-trie.

4. **"Cache Craftiness for Fast Multicore Key-Value Storage"** (Masstree)
   Mao et al. (EuroSys 2012)
   Key contribution: B+-tree nodes within trie structure for cache-friendly hierarchical lookup.

5. **"SIMD-Matcher: A SIMD-based Arbitrary Matching Framework"**
   ACM TACO 2022
   https://dl.acm.org/doi/fullHtml/10.1145/3514246
   Key contribution: SIMD-optimized trie nodes with fixed high fanout and varying span.

6. **"Comparison of Efficient Routing Table Data Structures"**
   Schoffmann (TU Munich 2017)
   https://www.net.in.tum.de/fileadmin/TUM/NET/NET-2017-05-1/NET-2017-05-1_03.pdf
   Key contribution: Comparative analysis of trie variants for routing.

7. **"Implementing a Generic Radix Trie in Rust"**
   Sproul
   https://michaelsproul.github.io/rust_radix_paper/rust-radix-sproul.pdf
   Key contribution: Rust-specific ownership considerations for radix trie implementation.

---

## Design Recommendations

Based on the survey, the optimal HTTP router design for a new systems-language implementation:

### Core Architecture
1. **Compressed radix tree** as the backbone (universal consensus)
2. **Separate tree per HTTP method** (reduces search space before traversal)
3. **Priority-ordered children** by handler count in subtree (httprouter/matchit pattern)
4. **Immutable after construction** -- build tree at startup, compile/optimize, then read-only

### Node Design (inspired by ART)
- For nodes with 1-4 children: linear scan (fits cache line)
- For nodes with 5-16 children: consider SIMD parallel comparison
- For nodes with 17+ children: index array (rare for HTTP routes)
- Most HTTP route trees will have nodes with 2-8 children, making compact linear-scan nodes ideal

### Parameter Extraction
- Zero-copy: store `(key, start, end)` referencing original path string
- Pre-allocate parameter storage (httprouter pattern)
- Avoid string allocation during matching

### Conflict Detection
- Detect at insertion time, not match time
- Enforce: static > parametric > wildcard priority
- Use segment-by-segment specificity comparison (Go 1.22 approach)

### Match Algorithm
- Walk tree segment by segment (split on `/`)
- At each node, check static children first, then parametric, then wildcard
- For backtracking (when needed): wayfind's hybrid approach -- only backtrack for segments with inline parameters

### What NOT to do
- Don't use regex for simple path matching (170x slower than radix tree)
- Don't use linear route scanning (O(n) in route count)
- Don't allocate during matching (kills throughput under load)
- Don't store method->handler maps at every node (wastes space, use separate trees)


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-aaf0c1c67d65d11ba.jsonl`
