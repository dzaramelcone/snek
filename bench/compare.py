"""Compare benchmark results and output a markdown table.

Usage:
    python3 bench/compare.py results/baseline.json [results/current.json]

With one file: prints a summary table.
With two files: prints a comparison with regression detection.
"""

import json
import sys
from pathlib import Path

from pydantic import BaseModel


class BenchResult(BaseModel):
    scenario: str
    module: str
    rps: str
    latency_avg: str
    latency_p99: str
    duration: str
    threads: int
    connections: int


class BenchMeta(BaseModel):
    timestamp: str = ""
    platform: str = ""
    python: str = ""
    duration: str = ""
    threads: int = 0
    connections: int = 0


class BenchReport(BaseModel):
    meta: BenchMeta = BenchMeta()
    results: list[BenchResult] = []


def load_report(path: str) -> BenchReport:
    data = json.loads(Path(path).read_text())
    return BenchReport.model_validate(data)


def parse_rps(val: str) -> float:
    s = val.replace(",", "").strip()
    return float(s) if s else 0.0


def print_single(report: BenchReport) -> None:
    print(f"## Benchmark Results ({report.meta.timestamp})\n")
    print(f"Platform: {report.meta.platform}  ")
    print(f"Python: {report.meta.python}  ")
    print(f"Config: {report.meta.duration} / {report.meta.threads}t / {report.meta.connections}c\n")
    print("| Scenario | RPS | Avg Latency | P99 Latency |")
    print("|----------|-----|-------------|-------------|")
    for r in report.results:
        print(f"| {r.scenario} | {r.rps} | {r.latency_avg} | {r.latency_p99} |")


def print_comparison(baseline: BenchReport, current: BenchReport) -> None:
    print(f"## Benchmark Comparison\n")
    print(f"Baseline: {baseline.meta.timestamp}  ")
    print(f"Current:  {current.meta.timestamp}\n")
    print("| Scenario | Baseline RPS | Current RPS | Change | Status |")
    print("|----------|-------------|-------------|--------|--------|")

    baseline_map = {r.scenario: r for r in baseline.results}
    regressions = 0

    for r in current.results:
        b = baseline_map.get(r.scenario)
        if not b:
            print(f"| {r.scenario} | — | {r.rps} | new | — |")
            continue

        b_rps = parse_rps(b.rps)
        c_rps = parse_rps(r.rps)

        if b_rps > 0:
            change_pct = ((c_rps - b_rps) / b_rps) * 100
        else:
            change_pct = 0.0

        if change_pct < -5:
            status = "REGRESSION"
            regressions += 1
        elif change_pct > 5:
            status = "IMPROVED"
        else:
            status = "ok"

        print(f"| {r.scenario} | {b.rps} | {r.rps} | {change_pct:+.1f}% | {status} |")

    if regressions > 0:
        print(f"\n**{regressions} regression(s) detected (>5% RPS drop).**")
        sys.exit(1)
    else:
        print("\nNo regressions detected.")


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <results.json> [baseline.json]", file=sys.stderr)
        sys.exit(1)

    if len(sys.argv) == 2:
        report = load_report(sys.argv[1])
        print_single(report)
    else:
        baseline = load_report(sys.argv[1])
        current = load_report(sys.argv[2])
        print_comparison(baseline, current)


if __name__ == "__main__":
    main()
