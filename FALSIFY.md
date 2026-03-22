# FALSIFY.md — Unbenchmarked Optimization Claims

Every entry here is a design choice taken from a reference project that claims
a performance advantage. None have been benchmarked in snek's context yet.
Each must be verified before we rely on it.

## Status Legend
- **FALSIFIED**: Benchmarked and the claim didn't hold. Replaced with simpler alternative.
- **VERIFIED**: Benchmarked and the claim held. Keeping.
- **PENDING**: Not yet implemented. Benchmark when we implement.

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
