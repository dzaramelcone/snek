# FALSIFY.md — Unbenchmarked Optimization Claims

Every entry here is a design choice taken from a reference project that claims
a performance advantage. None have been benchmarked in snek's context yet.
Each must be verified before we rely on it.

## Status Legend
- **FALSIFIED**: Benchmarked and the claim didn't hold. Replaced with simpler alternative.
- **VERIFIED**: Benchmarked and the claim held. Keeping.
- **PENDING**: Not yet implemented. Benchmark when we implement.

---

## Chase-Lev deque vs mutex-protected deque for work-stealing — VERIFIED

- **Claim**: Chase-Lev deque provides optimal work-stealing with LIFO for owner
  (cache-friendly) and FIFO for thieves (fairness).
- **Source**: Tokio, Crossbeam, Rayon (src/core/REFERENCES.md §1.2)
- **Alternatives benchmarked**: Mutex+Deque, SPSC queue
- **Results** (bench/deque_comparison.zig):
  - Single-threaded push/pop: Chase-Lev 3.5ns vs Mutex 4.3ns (1.2x)
  - Producer-consumer (1:1): Chase-Lev 8.1ns vs Mutex 33.2ns (4.1x)
  - Contended (1 push, 3 steal): Chase-Lev 8.8ns vs Mutex 90.6ns (10.3x)
  - Mixed (90% local, 10% steal): Chase-Lev 3.3ns vs Mutex 5.0ns (1.5x)
- **Verdict**: KEEP. 10x faster under contention, competitive single-threaded.
- **Still pending**: comparison with Zig stdlib's atomic linked list approach
  (requires scheduler integration at Phase 5 to test realistic dispatch).

---

## Timer: flat list vs timing wheel — PENDING

- **Claim**: Flat ArrayList scan on tick() is simpler and fast enough at <1000 timers.
- **Alternative**: Timing wheel with N slots for O(1) tick dispatch.
- **Threshold**: If tick() shows up in profiles or timer count exceeds 1000, switch to wheel.
- **Benchmark**: Schedule N timers, measure tick() latency at N=100, 1000, 10000.
- **Context**: snek will have request timeouts + keepalive timers. Hundreds, not millions.

---

## Phase 0

### HiveArray bitset pool (Bun pattern) — FALSIFIED
- **Claim**: O(1) acquire via CPU leading-zeros intrinsic, faster than free list.
- **Source**: Bun's HiveArray (refs/bun/INSIGHTS.md)
- **Reality**: 42x slower than free list at capacity=4096 due to cache pressure
  from 480KB struct. Bun uses it at capacity ≤ 2048 with a forked bitset;
  their IntegerBitSet(2048) uses a u2048 which still scans 32 words.
  The pattern only wins when the entire struct fits in L1 (capacity ≤ 64).
- **Action**: Replaced with index-based free list. See bench/pool_comparison.zig.

### Pre-allocated BufferPool vs arena allocators — FALSIFIED (conditionally)
- **Claim**: Pre-allocated buffer pool eliminates allocation in the hot path.
- **Alternative**: Arena allocators with retention.
- **Results** (bench/buffer_comparison.zig):
  - Sequential 4KB: Pool 9.3ns vs Arena 7.4ns (1.26x slower)
  - 10 outstanding 4KB: Pool 8.6ns vs Arena 4.4ns (1.95x slower)
  - Burst 100 4KB: Pool 27.1ns vs Arena 7.1ns (3.81x slower)
  - Sequential 16KB: Pool 4.1ns vs Arena 3.8ns (1.09x slower)
- **Verdict**: Arena wins in every scenario. Pool's O(n) linear scan for
  ref_count==0 gets punished under burst load. Arena's bump allocation is O(1).
- **Action**: Default to arena allocation for general I/O buffers. KEEP BufferPool
  only if we use io_uring IORING_REGISTER_BUFFERS (requires stable addresses).
  If registered buffers aren't used, delete BufferPool.

### Inline assert (Ghostty pattern) — PENDING VERIFICATION
- **Claim**: std.debug.assert has 15-20% overhead in hot loops in ReleaseFast
  because it's not always inlined. Inline variant eliminates this.
- **Source**: Ghostty (refs/ghostty/INSIGHTS.md)
- **Status**: UAT confirmed the function is eliminated in isolation (no text
  section in ReleaseFast .o file). But we haven't measured the actual overhead
  difference in a real hot loop in snek. The 15-20% claim is Ghostty's
  measurement in their rendering pipeline, not ours.
- **TODO**: When HTTP parser is implemented (Phase 7), benchmark a parsing
  loop with assert.check vs std.debug.assert. If difference is < 1%, the
  inline variant is unnecessary complexity.

---

## Phase 1

### Chase-Lev deque vs mutex-protected VecDeque — PENDING

- **Claim**: Lock-free Chase-Lev gives lower latency and higher throughput for
  work-stealing under contention (1 owner + N thieves) compared to a simple
  `Mutex(ArrayList(T))`.
- **Source**: Chase & Lev 2005, "Dynamic Circular Work-Stealing Deque".
- **Alternative**: `std.Thread.Mutex` + `std.ArrayList(T)` with push_back / pop_back
  for owner, pop_front for steal. ~20 lines of code vs ~80 for Chase-Lev.
- **Threshold**: If mutex version is within 2x throughput on the concurrent
  push+steal benchmark (1 owner, 3 thieves, 100K items), switch to mutex —
  simpler code wins. Chase-Lev's advantage is sub-microsecond steal under
  contention; if our workloads have low contention (per-worker queues with
  infrequent stealing), the lock-free complexity is wasted.
- **Benchmark**: 100K push + concurrent steal, measure total wall time and
  per-operation p99 latency. Compare Chase-Lev vs Mutex+ArrayList.
- **Context**: snek uses per-worker deques with occasional stealing. If stealing
  is rare (< 1% of operations), mutex contention is negligible and lock-free
  gains are unmeasurable.

---

## Phase 7+ (HTTP Parser — when implemented)

### SIMD structural scanning (simdjson/picohttpparser pattern) — PENDING
- **Claim**: SIMD scanning for structural characters ({, }, [, ], :, comma)
  is faster than byte-by-byte parsing.
- **Source**: simdjson (src/json/REFERENCES.md), picohttpparser (src/net/REFERENCES.md)
- **Threshold**: If byte-by-byte parsing is within 2x of SIMD for typical
  HTTP request sizes (< 8KB headers), keep byte-by-byte (simpler).
- **Note**: hparse (Zig) claims 12.5% faster than picohttpparser with 85%
  less memory — without explicit SIMD. Auto-vectorization may be enough.

### Integer-cast method matching (http.zig asUint pattern) — PENDING
- **Claim**: Casting "GET " to u32 and comparing integers is faster than
  string comparison for HTTP method matching.
- **Source**: http.zig (refs/http.zig/INSIGHTS.md)
- **Threshold**: If std.mem.eql is within 2x, keep string comparison (clearer).

---

## Phase 9+ (JSON — when implemented)

### SIMD JSON parsing (simdjson pattern) — PENDING
- **Claim**: SIMD structural scanning for JSON is significantly faster than
  scalar parsing.
- **Source**: simdjson (src/json/REFERENCES.md)
- **Threshold**: If std.json with zero-copy tokens is within 2x of SIMD
  approach for typical API payloads (< 10KB), keep std.json.
- **Note**: yyjson beats simdjson on serialization WITHOUT explicit SIMD.

---

## Phase 10+ (DB — when implemented)

### Binary format for Postgres types (asyncpg pattern) — PENDING
- **Claim**: Binary format is faster than text for numeric/timestamp/array types.
- **Source**: asyncpg benchmarks, src/db/REFERENCES.md
- **Threshold**: Measure decode time for 10K rows of mixed types. If text
  parsing is within 2x of binary decoding, text is simpler (human-readable
  in debug, fewer type-specific decoders to maintain).

### Cached decode pipeline (asyncpg pattern) — PENDING
- **Claim**: Caching the full decode pipeline per prepared statement yields
  1M rows/s.
- **Source**: asyncpg (src/db/REFERENCES.md)
- **Threshold**: Measure with and without caching. If non-cached is within
  2x, skip the cache (less memory, simpler invalidation).

---

## Phase 14+ (Production Features — when implemented)

### Pre-rendered CORS headers (TurboAPI pattern) — PENDING
- **Claim**: Pre-building CORS headers at startup = 0% per-request overhead
  vs 24% for Python middleware.
- **Source**: TurboAPI (src/http/REFERENCES_middleware.md)
- **Threshold**: This is Zig-side vs Python-side, so the comparison is
  inherently unfair. Verify the Zig-side overhead is < 100ns per request.

---

## Reminder

From WORKFLOW.md Step 2.5:
> Every clever choice must be falsifiable. If we can't articulate a scenario
> where the alternative wins, we don't understand the trade-off well enough.
