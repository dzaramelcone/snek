#!/usr/bin/env python3
"""HTTP-facing async throughput benchmarks using oha."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Scenario:
    name: str
    module_ref: str
    description: str


@dataclass(frozen=True)
class Provider:
    name: str
    description: str


SCENARIOS: dict[str, Scenario] = {
    "async_0": Scenario(
        name="async_0",
        module_ref="bench.scenarios.hello_minimal:app",
        description="async route with no inner await",
    ),
    "async_1": Scenario(
        name="async_1",
        module_ref="bench.scenarios.async_chain_1:app",
        description="async route awaiting one nested coroutine",
    ),
    "async_10": Scenario(
        name="async_10",
        module_ref="bench.scenarios.async_chain_10:app",
        description="async route awaiting a 10-hop nested coroutine chain",
    ),
}

PROVIDERS: dict[str, Provider] = {
    "snek": Provider(name="snek", description="native snek runtime"),
    "asyncio": Provider(name="asyncio", description="stdlib asyncio control server"),
    "uvloop": Provider(name="uvloop", description="libuv-backed control server"),
}


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run oha against async route scenarios.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9081)
    parser.add_argument("--duration", default="15s", help="oha duration, for example 15s")
    parser.add_argument("--connections", type=int, default=256)
    parser.add_argument(
        "--scenarios",
        default="async_0,async_1,async_10",
        help="comma-separated scenario list",
    )
    parser.add_argument(
        "--providers",
        default="snek,uvloop,asyncio",
        help="comma-separated provider list: snek,uvloop,asyncio",
    )
    parser.add_argument("--json-out", help="write consolidated JSON to this path")
    parser.add_argument("--raw-dir", help="write raw oha JSON per scenario into this directory")
    return parser.parse_args()


def _pythonpath_env() -> dict[str, str]:
    env = os.environ.copy()
    existing = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = f"{ROOT_DIR / 'python'}:{ROOT_DIR}:{existing}".rstrip(":")
    return env


def _wait_for_server(host: str, port: int, timeout_s: float = 10.0) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        with socket.socket() as sock:
            sock.settimeout(0.2)
            try:
                sock.connect((host, port))
            except OSError:
                time.sleep(0.05)
                continue
            return
    raise TimeoutError(f"server did not start listening on {host}:{port} within {timeout_s}s")


def _fmt_float(value: float | None) -> str:
    return "null" if value is None else f"{value:.3f}"


def _available_providers(provider_arg: str) -> list[Provider]:
    requested = [name.strip() for name in provider_arg.split(",") if name.strip()]
    providers: list[Provider] = []

    for name in requested:
        provider = PROVIDERS.get(name)
        if provider is None:
            raise SystemExit(f"unknown provider: {name}")
        if name == "uvloop" and importlib.util.find_spec("uvloop") is None:
            continue
        providers.append(provider)

    if not providers:
        raise SystemExit("no HTTP benchmark providers available")
    return providers


def _server_cmd(args: argparse.Namespace, provider: Provider, scenario: Scenario) -> list[str]:
    if provider.name == "snek":
        return [
            sys.executable,
            "-m",
            "snek.cli",
            scenario.module_ref,
            "--host",
            args.host,
            "--port",
            str(args.port),
        ]

    return [
        sys.executable,
        str(ROOT_DIR / "bench" / "eventloop_control_server.py"),
        "--provider",
        provider.name,
        "--scenario",
        scenario.name,
        "--host",
        args.host,
        "--port",
        str(args.port),
    ]


def _run_scenario(args: argparse.Namespace, provider: Provider, scenario: Scenario, log_dir: Path) -> dict[str, object]:
    log_dir.mkdir(parents=True, exist_ok=True)
    stdout_log = log_dir / f"{provider.name}_{scenario.name}.stdout.log"
    stderr_log = log_dir / f"{provider.name}_{scenario.name}.stderr.log"

    server_env = _pythonpath_env()
    server_cmd = _server_cmd(args, provider, scenario)

    with stdout_log.open("w") as out, stderr_log.open("w") as err:
        server = subprocess.Popen(
            server_cmd,
            cwd=ROOT_DIR,
            env=server_env,
            stdout=out,
            stderr=err,
        )
        try:
            _wait_for_server(args.host, args.port)

            oha_env = os.environ.copy()
            oha_env.pop("NO_COLOR", None)
            oha_cmd = [
                "oha",
                "--no-tui",
                "--output-format",
                "json",
                "-z",
                args.duration,
                "-c",
                str(args.connections),
                f"http://{args.host}:{args.port}/",
            ]
            completed = subprocess.run(
                oha_cmd,
                cwd=ROOT_DIR,
                env=oha_env,
                capture_output=True,
                text=True,
                check=False,
            )
            if completed.returncode != 0:
                raise RuntimeError(
                    f"oha failed for {provider.name}/{scenario.name} with exit code "
                    f"{completed.returncode}: {completed.stderr.strip()}"
                )

            raw = json.loads(completed.stdout)
            summary = raw["summary"]
            latency = raw["latencyPercentiles"]
            result = {
                "provider": provider.name,
                "provider_description": provider.description,
                "scenario": scenario.name,
                "module_ref": scenario.module_ref,
                "description": scenario.description,
                "summary": {
                    "success_rate": summary["successRate"],
                    "total_s": summary["total"],
                    "requests_per_sec": summary["requestsPerSec"],
                    "average_latency_ms": None if summary["average"] is None else summary["average"] * 1000.0,
                    "p99_latency_ms": None if latency["p99"] is None else latency["p99"] * 1000.0,
                    "fastest_ms": None if summary["fastest"] is None else summary["fastest"] * 1000.0,
                    "slowest_ms": None if summary["slowest"] is None else summary["slowest"] * 1000.0,
                },
                "status_code_distribution": raw["statusCodeDistribution"],
                "error_distribution": raw["errorDistribution"],
                "raw": raw,
            }
            return result
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)


def main() -> int:
    args = _parse_args()

    if not shutil.which("oha"):
        raise SystemExit("oha is required for HTTP event-loop benchmarks")

    providers = _available_providers(args.providers)
    requested = [name.strip() for name in args.scenarios.split(",") if name.strip()]
    try:
        scenarios = [SCENARIOS[name] for name in requested]
    except KeyError as exc:
        raise SystemExit(f"unknown scenario: {exc.args[0]}") from exc

    raw_dir = Path(args.raw_dir) if args.raw_dir else None
    log_dir = (raw_dir / "logs") if raw_dir else (ROOT_DIR / "bench" / "results" / "eventloop_logs")

    payload: dict[str, object] = {
        "meta": {
            "timestamp_ns": time.time_ns(),
            "platform": platform.platform(),
            "python": platform.python_version(),
            "host": args.host,
            "port": args.port,
            "duration": args.duration,
            "connections": args.connections,
            "providers": [provider.name for provider in providers],
        },
        "results": [],
    }

    print("provider\tscenario\trps\tavg_ms\tp99_ms\tsuccess")
    for provider in providers:
        for scenario in scenarios:
            result = _run_scenario(args, provider, scenario, log_dir)
            if raw_dir is not None:
                raw_dir.mkdir(parents=True, exist_ok=True)
                raw_path = raw_dir / f"{provider.name}_{scenario.name}.json"
                raw_path.write_text(json.dumps(result["raw"], indent=2) + "\n")
            raw = result.pop("raw")
            _ = raw
            payload["results"].append(result)

            summary = result["summary"]
            print(
                f"{provider.name}\t{scenario.name}\t{summary['requests_per_sec']:.0f}\t"
                f"{_fmt_float(summary['average_latency_ms'])}\t{_fmt_float(summary['p99_latency_ms'])}\t"
                f"{summary['success_rate']:.3f}"
            )

    if args.json_out:
        out_path = Path(args.json_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, indent=2) + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
