---
name: feedback_no_percentages
description: Use total time comparisons in profiling, not percentages
type: feedback
---

Percentages are not helpful for profiling comparisons. Use total time comparisons instead.

**Why:** When comparing across servers with different throughput, percentages hide the absolute cost. 5% of snek's time vs 12% of Go's time tells you nothing about which is actually slower in absolute terms.

**How to apply:** Always present profiling data as total time (ns per request, total ms, absolute sample counts) rather than percentage of CPU time.
