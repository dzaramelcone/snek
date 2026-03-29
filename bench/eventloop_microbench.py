#!/usr/bin/env python3
"""Microbenchmarks for Python event-loop internals.

This complements the HTTP load tests by measuring loop scheduling cost
without HTTP parsing, socket I/O, or response serialization in the way.
"""

from __future__ import annotations

import argparse
import asyncio
import gc
import json
import os
import platform
import statistics
import sys
import time
import warnings
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
PYTHON_DIR = ROOT_DIR / "python"

sys.path.insert(0, str(ROOT_DIR))
sys.path.insert(0, str(PYTHON_DIR))

READY_BATCH_SIZE = 64
TIMER_BATCH_SIZE = 32


def _set_policy(policy_factory: Callable[[], asyncio.AbstractEventLoopPolicy] | None) -> None:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        asyncio.set_event_loop_policy(policy_factory() if policy_factory else None)


@dataclass(frozen=True)
class Provider:
    name: str
    loop_factory: Callable[[], asyncio.AbstractEventLoop]
    policy_factory: Callable[[], asyncio.AbstractEventLoopPolicy] | None = None


@dataclass(frozen=True)
class Case:
    name: str
    op_name: str
    default_count: int
    runner: Callable[[asyncio.AbstractEventLoop, int], tuple[float, int]]


def _load_snek_provider() -> Provider:
    try:
        from snek import loop as snek_loop
    except Exception as exc:  # pragma: no cover - environment specific
        raise SystemExit(
            "failed to import snek.loop; build or install the extension first "
            "(for example: `zig build pyext` or `pip install -e .`)."
        ) from exc

    return Provider(
        name="snek",
        loop_factory=snek_loop.new_event_loop,
        policy_factory=snek_loop.EventLoopPolicy,
    )


def _load_uvloop_provider() -> Provider | None:
    try:
        import uvloop
    except Exception:
        return None

    return Provider(
        name="uvloop",
        loop_factory=uvloop.new_event_loop,
        policy_factory=uvloop.EventLoopPolicy,
    )


def _run_with_provider(provider: Provider, fn: Callable[[asyncio.AbstractEventLoop], tuple[float, int]]) -> tuple[float, int]:
    gc_was_enabled = gc.isenabled()
    gc.collect()
    if gc_was_enabled:
        gc.disable()

    _set_policy(provider.policy_factory)
    loop = provider.loop_factory()
    asyncio.set_event_loop(loop)
    try:
        return fn(loop)
    finally:
        asyncio.set_event_loop(None)
        loop.close()
        _set_policy(None)
        if gc_was_enabled:
            gc.enable()


def _bench_call_soon(loop: asyncio.AbstractEventLoop, count: int) -> tuple[float, int]:
    remaining = count
    scheduled = 0
    start = time.perf_counter()

    while remaining > 0:
        done = loop.create_future()
        batch_remaining = min(READY_BATCH_SIZE, remaining)

        def cb() -> None:
            nonlocal batch_remaining
            batch_remaining -= 1
            if batch_remaining == 0 and not done.done():
                done.set_result(None)

        for _ in range(batch_remaining):
            loop.call_soon(cb)
            scheduled += 1
        loop.run_until_complete(done)
        remaining -= min(READY_BATCH_SIZE, remaining)

    elapsed = time.perf_counter() - start
    if scheduled != count or remaining != 0:
        raise RuntimeError(
            f"call_soon benchmark drained incorrectly: remaining={remaining} scheduled={scheduled}"
        )
    return elapsed, scheduled


def _bench_call_later_zero(loop: asyncio.AbstractEventLoop, count: int) -> tuple[float, int]:
    remaining = count
    scheduled = 0
    start = time.perf_counter()

    while remaining > 0:
        done = loop.create_future()
        batch_remaining = min(TIMER_BATCH_SIZE, remaining)

        def cb() -> None:
            nonlocal batch_remaining
            batch_remaining -= 1
            if batch_remaining == 0 and not done.done():
                done.set_result(None)

        for _ in range(batch_remaining):
            loop.call_later(0, cb)
            scheduled += 1
        loop.run_until_complete(done)
        remaining -= min(TIMER_BATCH_SIZE, remaining)

    elapsed = time.perf_counter() - start
    if scheduled != count or remaining != 0:
        raise RuntimeError(
            f"call_later(0) benchmark drained incorrectly: remaining={remaining} scheduled={scheduled}"
        )
    return elapsed, scheduled


def _bench_sleep_zero_chain(loop: asyncio.AbstractEventLoop, count: int) -> tuple[float, int]:
    async def worker() -> int:
        completed = 0
        for _ in range(count):
            await asyncio.sleep(0)
            completed += 1
        return completed

    start = time.perf_counter()
    completed = loop.run_until_complete(worker())
    elapsed = time.perf_counter() - start
    return elapsed, completed


def _bench_task_fanout(loop: asyncio.AbstractEventLoop, count: int) -> tuple[float, int]:
    async def child() -> int:
        await asyncio.sleep(0)
        return 1

    async def main() -> int:
        completed = 0
        remaining = count
        while remaining > 0:
            batch_size = min(READY_BATCH_SIZE, remaining)
            tasks = [loop.create_task(child()) for _ in range(batch_size)]
            results = await asyncio.gather(*tasks)
            completed += sum(results)
            remaining -= batch_size
        return completed

    start = time.perf_counter()
    completed = loop.run_until_complete(main())
    elapsed = time.perf_counter() - start
    return elapsed, completed


CASES: list[Case] = [
    Case("call_soon_batch", "callbacks", 100_000, _bench_call_soon),
    Case("call_later_zero_batch", "timers", 50_000, _bench_call_later_zero),
    Case("sleep_zero_chain", "awaits", 100_000, _bench_sleep_zero_chain),
    Case("task_fanout_one_sleep", "tasks", 10_000, _bench_task_fanout),
]


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark Python event-loop throughput.")
    parser.add_argument("--repeats", type=int, default=5, help="timed repetitions per case")
    parser.add_argument("--warmup", type=int, default=1, help="warmup repetitions per case")
    parser.add_argument("--callbacks", type=int, default=CASES[0].default_count)
    parser.add_argument("--timers", type=int, default=CASES[1].default_count)
    parser.add_argument("--yields", type=int, default=CASES[2].default_count)
    parser.add_argument("--tasks", type=int, default=CASES[3].default_count)
    parser.add_argument(
        "--providers",
        default="snek,asyncio,uvloop",
        help="comma-separated provider list: snek,asyncio,uvloop",
    )
    parser.add_argument("--json-out", help="write full JSON results to this path")
    return parser.parse_args()


def _provider_set(provider_arg: str) -> list[Provider]:
    requested = [part.strip() for part in provider_arg.split(",") if part.strip()]
    providers: list[Provider] = []
    uvloop_provider = _load_uvloop_provider()

    for name in requested:
        if name == "snek":
            providers.append(_load_snek_provider())
        elif name == "asyncio":
            providers.append(Provider(name="asyncio", loop_factory=asyncio.new_event_loop))
        elif name == "uvloop":
            if uvloop_provider is not None:
                providers.append(uvloop_provider)
        else:
            raise SystemExit(f"unknown provider: {name}")

    if not providers:
        raise SystemExit("no benchmark providers available")
    return providers


def _case_count(args: argparse.Namespace, case: Case) -> int:
    if case.op_name == "callbacks":
        return args.callbacks
    if case.op_name == "timers":
        return args.timers
    if case.op_name == "awaits":
        return args.yields
    if case.op_name == "tasks":
        return args.tasks
    raise AssertionError(case.op_name)


def main() -> int:
    args = _parse_args()
    providers = _provider_set(args.providers)

    payload: dict[str, object] = {
        "meta": {
            "timestamp_ns": time.time_ns(),
            "platform": platform.platform(),
            "python": platform.python_version(),
            "cwd": os.getcwd(),
            "repeats": args.repeats,
            "warmup": args.warmup,
            "counts": {
                "callbacks": args.callbacks,
                "timers": args.timers,
                "awaits": args.yields,
                "tasks": args.tasks,
            },
        },
        "results": [],
    }

    print("provider\tcase\tops\tbest_ms\tmedian_ms\tops_per_sec")
    for provider in providers:
        for case in CASES:
            count = _case_count(args, case)
            samples: list[float] = []
            ops = count

            for run_idx in range(args.warmup + args.repeats):
                elapsed, completed = _run_with_provider(provider, lambda loop, c=case, n=count: c.runner(loop, n))
                ops = completed
                if run_idx >= args.warmup:
                    samples.append(elapsed)

            best = min(samples)
            median = statistics.median(samples)
            ops_per_sec = ops / best if best > 0 else 0.0

            payload["results"].append(
                {
                    "provider": provider.name,
                    "case": case.name,
                    "op_name": case.op_name,
                    "ops": ops,
                    "samples_s": samples,
                    "best_s": best,
                    "median_s": median,
                    "ops_per_sec": ops_per_sec,
                }
            )
            print(
                f"{provider.name}\t{case.name}\t{ops}\t"
                f"{best * 1000:.3f}\t{median * 1000:.3f}\t{ops_per_sec:.0f}"
            )

    if args.json_out:
        out_path = Path(args.json_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, indent=2) + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
