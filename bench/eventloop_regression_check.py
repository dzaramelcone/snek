#!/usr/bin/env python3
"""Run isolated event-loop microbenchmarks for regression tracking.

This wrapper avoids the same-process provider contamination caused by
`snek.loop` monkeypatching `asyncio.Task` / `asyncio.Future`.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
MICROBENCH = ROOT_DIR / "bench" / "eventloop_microbench.py"
DEFAULT_PROVIDERS = ("snek", "uvloop", "asyncio")
PRIMARY_CASE = "task_fanout_one_sleep"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run isolated event-loop microbenchmarks for regression tracking."
    )
    parser.add_argument(
        "--python",
        default=sys.executable,
        help="Python interpreter to use for child benchmark processes",
    )
    parser.add_argument(
        "--providers",
        default=",".join(DEFAULT_PROVIDERS),
        help="comma-separated provider list",
    )
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--callbacks", type=int, default=100_000)
    parser.add_argument("--timers", type=int, default=50_000)
    parser.add_argument("--yields", type=int, default=100_000)
    parser.add_argument("--tasks", type=int, default=10_000)
    parser.add_argument("--json-out", help="write merged JSON results to this path")
    return parser.parse_args()


def _providers(value: str) -> list[str]:
    providers = [part.strip() for part in value.split(",") if part.strip()]
    if not providers:
        raise SystemExit("no providers requested")
    return providers


def _run_provider(args: argparse.Namespace, provider: str) -> dict[str, object]:
    with tempfile.NamedTemporaryFile(prefix=f"snek_{provider}_", suffix=".json", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        cmd = [
            args.python,
            str(MICROBENCH),
            "--providers",
            provider,
            "--repeats",
            str(args.repeats),
            "--warmup",
            str(args.warmup),
            "--callbacks",
            str(args.callbacks),
            "--timers",
            str(args.timers),
            "--yields",
            str(args.yields),
            "--tasks",
            str(args.tasks),
            "--json-out",
            str(tmp_path),
        ]
        completed = subprocess.run(
            cmd,
            cwd=ROOT_DIR,
            text=True,
            capture_output=True,
            check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError(
                f"benchmark failed for {provider} with exit code {completed.returncode}\n"
                f"stdout:\n{completed.stdout}\n"
                f"stderr:\n{completed.stderr}"
            )

        payload = json.loads(tmp_path.read_text())
        payload["stdout"] = completed.stdout
        payload["stderr"] = completed.stderr
        return payload
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass


def _results_index(results: list[dict[str, object]]) -> dict[tuple[str, str], dict[str, object]]:
    index: dict[tuple[str, str], dict[str, object]] = {}
    for entry in results:
        provider = str(entry["provider"])
        case = str(entry["case"])
        index[(provider, case)] = entry
    return index


def main() -> int:
    args = _parse_args()
    providers = _providers(args.providers)

    merged_results: list[dict[str, object]] = []
    raw_runs: list[dict[str, object]] = []
    started_ns = time.time_ns()

    for provider in providers:
        payload = _run_provider(args, provider)
        raw_runs.append(payload)
        merged_results.extend(payload["results"])

    merged = {
        "meta": {
            "timestamp_ns": started_ns,
            "cwd": os.getcwd(),
            "python": args.python,
            "providers": providers,
            "repeats": args.repeats,
            "warmup": args.warmup,
            "counts": {
                "callbacks": args.callbacks,
                "timers": args.timers,
                "awaits": args.yields,
                "tasks": args.tasks,
            },
            "primary_case": PRIMARY_CASE,
        },
        "results": merged_results,
    }

    index = _results_index(merged_results)

    print("provider\tcase\tops_per_sec")
    for provider in providers:
        for case in ("call_soon_batch", "call_later_zero_batch", "sleep_zero_chain", PRIMARY_CASE):
            entry = index.get((provider, case))
            if entry is None:
                continue
            print(f"{provider}\t{case}\t{entry['ops_per_sec']:.0f}")

    primary = {provider: index.get((provider, PRIMARY_CASE)) for provider in providers}
    if primary.get("snek") and primary.get("uvloop"):
        snek_ops = float(primary["snek"]["ops_per_sec"])
        uv_ops = float(primary["uvloop"]["ops_per_sec"])
        print(f"\n{snek_ops / uv_ops:.3f}x snek/uvloop on {PRIMARY_CASE}")
    if primary.get("snek") and primary.get("asyncio"):
        snek_ops = float(primary["snek"]["ops_per_sec"])
        py_ops = float(primary["asyncio"]["ops_per_sec"])
        print(f"{snek_ops / py_ops:.3f}x snek/asyncio on {PRIMARY_CASE}")

    if args.json_out:
        out_path = Path(args.json_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(merged, indent=2) + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
