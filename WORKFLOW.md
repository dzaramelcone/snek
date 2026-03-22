# WORKFLOW.md — Implementation Verification Workflow

**Every phase follows this exact sequence. No skipping steps.**

---

## Step 1: Read the Plan

- Read IMPLEMENTATION.md for the current phase
- Read the stub files to understand the interface contract
- Read the cited REFERENCES.md / INSIGHTS.md for design inspiration
- Confirm dependencies from prior phases are passing

## Step 2: Write Tests First

- Fill in the empty test blocks in each stub file
- Tests must cover:
  - Happy path (basic functionality)
  - Edge cases (empty, full, boundary, overflow)
  - Error paths (what should fail and how)
  - Concurrency (if applicable — use std.Thread)
- All tests use `std.testing.allocator` for leak detection
- Run tests — they must **fail** (red). If they pass, the tests are wrong.

## Step 2.5: Define Falsifiability Criteria

Before implementing, answer for each non-trivial design choice:

**"How would we know this is the wrong choice?"**

For every data structure, algorithm, or pattern drawn from a reference project, write down:

1. **The claim**: What do we believe this gives us? (e.g., "O(1) acquire via bitset intrinsic")
2. **The alternative**: What's the simplest thing that could work instead? (e.g., "free list with head pointer")
3. **The threshold**: At what measurement would we switch? (e.g., "if free list is within 2x latency, switch — simpler code wins")
4. **The benchmark**: How do we measure it? (e.g., "10K acquire/release cycles, single-threaded, report median ns/op")
5. **The context**: Does our actual usage pattern even hit the advantage? (e.g., "if pools are per-worker with no contention, atomic bitset ops are wasted")

Write these as comments in the source file or as entries in a `DECISIONS.md` log.

**The point**: Every clever choice must be falsifiable. If we can't articulate a scenario where the alternative wins, we don't understand the trade-off well enough. If the benchmark shows the simpler alternative is competitive, we take the simpler one — always. Complexity must earn its keep with measurable evidence.

**Not every choice needs this** — only ones where we're choosing a non-obvious approach over a simpler alternative. Wrapping an ArenaAllocator doesn't need falsifiability criteria. A custom bitset pool over a free list does.

## Step 3: Write Minimum Viable Implementation

- Fill in the stub bodies with the absolute minimum code that passes the tests
- No premature optimization
- No clever tricks
- Cite the source in a comment if drawing from a reference implementation
- Follow the simplicity criterion: if removing code produces equal results, remove it

## Step 4: Run Tests (Green)

```sh
zig test src/<domain>/<file>.zig
```

- All tests must pass
- Zero leaks reported by `testing.allocator`
- Zero compiler warnings

## Step 5: Memory Verification

```sh
# Run under valgrind (Linux / Docker)
docker run --rm -v $(pwd):/src -w /src ubuntu:latest bash -c \
  "apt-get update && apt-get install -y valgrind zig && valgrind --leak-check=full zig test src/core/<file>.zig"

# Or use Zig's built-in leak detection (already in Step 4 via testing.allocator)
```

- Zero leaks
- Zero invalid reads/writes
- Zero use-after-free

For concurrent code (deque, pool, scheduler):
```sh
# ASan via Zig's safety checks in Debug mode
zig test -ODebug src/core/<file>.zig
```

## Step 6: TLA+ / Formal Modeling (where applicable)

Only for concurrent subsystems:
- Chase-Lev deque (Phase 1)
- Connection pool (Phase 11)
- Scheduler (Phase 5)
- Graceful shutdown (Phase 5)

Properties to verify:
- **Safety**: no data races, no double-free, no lost items
- **Liveness**: no deadlocks, no starvation (under fairness)
- **Linearizability**: concurrent operations are equivalent to some sequential order

Write TLA+ specs in `specs/<name>.tla`. Run with TLC model checker.
Record: number of states explored, any violations found.

## Step 7: Benchmarks (where applicable)

Run against comparison targets cited in REFERENCES.md:

```sh
# Build in ReleaseFast for benchmarks
zig build -Doptimize=ReleaseFast

# Use std.time.Timer or @import("std").time.nanoTimestamp for measurement
# Run 10K+ iterations, report median and p99
```

Record in the journal: operation, throughput, comparison target, ratio.

Not every phase needs benchmarks — only when IMPLEMENTATION.md specifies a target.

## Step 8: UAT — Manual Verification

This is the "trust but verify" step. For each implementation:

1. **Step-through debugging**: Set a breakpoint in the core function. Step through with lldb/gdb. Verify the logic matches your mental model.
   ```sh
   # Build test binary with debug info
   zig test --test-no-exec src/core/<file>.zig
   lldb ./zig-out/bin/test
   ```

2. **Binary inspection**: Check the compiled output makes sense.
   ```sh
   # Verify hot-path asserts are eliminated in ReleaseFast
   zig build-obj -OReleaseFast src/core/assert.zig
   objdump -d assert.o | grep -A5 "check"
   ```

3. **Stack trace sampling**: For runtime code, verify stack traces are clean and readable when things fail.

4. **Print debugging** (if needed): Temporarily add `std.debug.print` to trace execution flow. Remove before committing.

Not every file needs all 4 sub-steps. Use judgment — complex concurrent code (deque, scheduler) gets full treatment. Simple wrappers (arena) get a lighter pass.

## Step 9: Integration Check

After all files in a phase pass individually:

```sh
# Full build with all modules
zig build

# Run ALL tests (catches cross-module issues)
zig build test
```

Verify no regressions in previously-completed phases.

## Step 10: Journal & Commit

1. Update IMPLEMENTATION.md journal with one-liners for each file
2. Mark completion criteria checkboxes
3. Commit with descriptive message referencing the phase

```sh
git add src/<domain>/
git commit -m "Phase N: <summary>"
```

---

## Checklist Template

Copy this for each file in the phase:

```
### <filename>.zig
- [ ] Tests written and failing (red)
- [ ] Falsifiability criteria defined (if non-trivial design choice)
- [ ] Implementation written
- [ ] Tests passing (green)
- [ ] Zero leaks (testing.allocator)
- [ ] Memory verification (valgrind/ASan if concurrent)
- [ ] TLA+ model (if concurrent — skip otherwise)
- [ ] Benchmark vs alternative (if falsifiability criteria defined)
- [ ] UAT: step-through or binary inspection
- [ ] Sources cited in comments
```

---

## When to Stop and Ask

- If a test reveals the stub interface is wrong — **stop, update the stub, discuss**
- If benchmarks show we're 10x+ off target — **stop, investigate before proceeding**
- If TLA+ finds a safety violation — **stop, fix the algorithm, re-verify**
- If valgrind finds memory corruption — **stop, this is a blocker**
- If the implementation exceeds 2x the line count of the reference implementation — **stop, we're overcomplicating it**
- If a falsifiability benchmark shows the simpler alternative is within threshold — **stop, switch to the simpler one**
- If we can't articulate why the reference project needed this pattern — **stop, question whether we need it too**

---

## Phase-Specific Notes

### Phases 0-5 (Core Runtime)
- Heavy on TLA+ and concurrency testing
- Benchmark against Crossbeam, Tokio, TigerBeetle where noted
- Every data structure gets UAT step-through

### Phases 6-9 (HTTP Path)
- Conformance testing (h2spec, Autobahn) starts here
- Benchmark against http.zig, picohttpparser where noted
- Request smuggling tests are security-critical — full UAT

### Phases 10-11 (DB/Redis)
- Test against real Postgres and Redis (Docker)
- Pipeline mode benchmarks against pgx
- SCRAM-SHA-256 tested against real Postgres auth

### Phases 12-13 (Python Integration)
- Test with real CPython (not mocked)
- GIL timing measurements
- Coroutine driving tested with actual async def handlers

### Phases 14-16 (Production + Integration + E2E)
- Full conformance suites (Autobahn, h2spec, testssl.sh)
- Benchmark suite against uvicorn+FastAPI, BlackSheep
- End-to-end with example apps
