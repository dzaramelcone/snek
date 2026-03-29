#!/usr/bin/env python3
"""TCP echo benchmark matching uvloop's published control categories more closely."""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import socket
import statistics
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Provider:
    name: str


@dataclass(frozen=True)
class Mode:
    name: str


PROVIDERS: dict[str, Provider] = {
    "asyncio": Provider("asyncio"),
    "uvloop": Provider("uvloop"),
}

MODES: dict[str, Mode] = {
    "streams": Mode("streams"),
    "protocol": Mode("protocol"),
    "sockets": Mode("sockets"),
}


def _parse_duration(value: str) -> float:
    if value.endswith("ms"):
        return float(value[:-2]) / 1000.0
    if value.endswith("s"):
        return float(value[:-1])
    return float(value)


def _parse_sizes(value: str) -> list[int]:
    sizes = [int(part.strip()) for part in value.split(",") if part.strip()]
    if not sizes:
        raise SystemExit("at least one message size is required")
    return sizes


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run TCP echo benchmarks against asyncio and uvloop.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9098)
    parser.add_argument("--duration", default="5s")
    parser.add_argument("--connections", type=int, default=32)
    parser.add_argument("--message-sizes", default="64,1024,16384")
    parser.add_argument("--sample-stride", type=int, default=32)
    parser.add_argument("--providers", default="uvloop,asyncio")
    parser.add_argument("--modes", default="streams,protocol,sockets")
    parser.add_argument("--json-out", help="write consolidated JSON to this path")
    parser.add_argument("--raw-dir", help="write per-case JSON to this directory")
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


def _providers(provider_arg: str) -> list[Provider]:
    requested = [name.strip() for name in provider_arg.split(",") if name.strip()]
    providers: list[Provider] = []
    for name in requested:
        provider = PROVIDERS.get(name)
        if provider is None:
            raise SystemExit(f"unknown provider: {name}")
        if name == "uvloop":
            try:
                import uvloop  # noqa: F401
            except Exception:
                continue
        providers.append(provider)
    if not providers:
        raise SystemExit("no echo benchmark providers available")
    return providers


def _modes(mode_arg: str) -> list[Mode]:
    requested = [name.strip() for name in mode_arg.split(",") if name.strip()]
    modes: list[Mode] = []
    for name in requested:
        mode = MODES.get(name)
        if mode is None:
            raise SystemExit(f"unknown mode: {name}")
        modes.append(mode)
    if not modes:
        raise SystemExit("no echo benchmark modes available")
    return modes


def _recv_exactly(sock: socket.socket, size: int) -> bool:
    remaining = size
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            return False
        remaining -= len(chunk)
    return True


def _run_client_round(
    host: str,
    port: int,
    duration_s: float,
    connections: int,
    message_size: int,
    sample_stride: int,
) -> dict[str, object]:
    payload = b"x" * message_size
    barrier = threading.Barrier(connections + 1)
    deadline = time.perf_counter() + duration_s
    results: list[tuple[int, int, list[float]]] = []
    lock = threading.Lock()

    def worker() -> None:
        messages = 0
        bytes_total = 0
        samples_ms: list[float] = []
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.connect((host, port))
        sock.settimeout(2.0)
        try:
            barrier.wait()
            while time.perf_counter() < deadline:
                sample = (messages % sample_stride) == 0
                start_ns = time.perf_counter_ns() if sample else 0
                sock.sendall(payload)
                if not _recv_exactly(sock, message_size):
                    break
                if sample:
                    samples_ms.append((time.perf_counter_ns() - start_ns) / 1_000_000.0)
                messages += 1
                bytes_total += message_size
        finally:
            sock.close()
            with lock:
                results.append((messages, bytes_total, samples_ms))

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(connections)]
    for thread in threads:
        thread.start()
    barrier.wait()
    started = time.perf_counter()
    for thread in threads:
        thread.join()
    elapsed = time.perf_counter() - started

    total_messages = sum(row[0] for row in results)
    total_bytes = sum(row[1] for row in results)
    latency_samples = [sample for _, _, samples in results for sample in samples]
    latency_samples.sort()
    p95_latency_ms = None
    if latency_samples:
        idx = min(len(latency_samples) - 1, math.ceil(len(latency_samples) * 0.95) - 1)
        p95_latency_ms = latency_samples[idx]

    return {
        "messages": total_messages,
        "bytes": total_bytes,
        "elapsed_s": elapsed,
        "messages_per_sec": 0.0 if elapsed == 0 else total_messages / elapsed,
        "mib_per_sec": 0.0 if elapsed == 0 else total_bytes / elapsed / (1024.0 * 1024.0),
        "average_latency_ms": None if not latency_samples else statistics.mean(latency_samples),
        "p95_latency_ms": p95_latency_ms,
        "latency_sample_count": len(latency_samples),
    }


def _fmt_float(value: float | None) -> str:
    return "null" if value is None else f"{value:.3f}"


def _run_case(
    args: argparse.Namespace,
    provider: Provider,
    mode: Mode,
    message_size: int,
    duration_s: float,
    log_dir: Path,
) -> dict[str, object]:
    log_dir.mkdir(parents=True, exist_ok=True)
    stdout_log = log_dir / f"{provider.name}_{mode.name}_{message_size}.stdout.log"
    stderr_log = log_dir / f"{provider.name}_{mode.name}_{message_size}.stderr.log"

    server_cmd = [
        sys.executable,
        str(ROOT_DIR / "bench" / "eventloop_echo_server.py"),
        "--provider",
        provider.name,
        "--mode",
        mode.name,
        "--host",
        args.host,
        "--port",
        str(args.port),
        "--message-size",
        str(message_size),
    ]

    with stdout_log.open("w") as out, stderr_log.open("w") as err:
        server = subprocess.Popen(
            server_cmd,
            cwd=ROOT_DIR,
            env=_pythonpath_env(),
            stdout=out,
            stderr=err,
        )
        try:
            _wait_for_server(args.host, args.port)
            summary = _run_client_round(
                args.host,
                args.port,
                duration_s,
                args.connections,
                message_size,
                args.sample_stride,
            )
            return {
                "provider": provider.name,
                "mode": mode.name,
                "message_size": message_size,
                "summary": summary,
            }
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)


def main() -> int:
    args = _parse_args()
    duration_s = _parse_duration(args.duration)
    providers = _providers(args.providers)
    modes = _modes(args.modes)
    message_sizes = _parse_sizes(args.message_sizes)

    raw_dir = Path(args.raw_dir) if args.raw_dir else None
    log_dir = (raw_dir / "logs") if raw_dir else (ROOT_DIR / "bench" / "results" / "eventloop_echo_logs")

    payload: dict[str, object] = {
        "meta": {
            "timestamp_ns": time.time_ns(),
            "platform": platform.platform(),
            "python": platform.python_version(),
            "host": args.host,
            "port": args.port,
            "duration_s": duration_s,
            "connections": args.connections,
            "sample_stride": args.sample_stride,
            "providers": [provider.name for provider in providers],
            "modes": [mode.name for mode in modes],
            "message_sizes": message_sizes,
        },
        "results": [],
    }

    print("provider\tmode\tsize\tmsg_per_s\tMiB_per_s\tavg_ms\tp95_ms")
    for provider in providers:
        for mode in modes:
            for message_size in message_sizes:
                result = _run_case(args, provider, mode, message_size, duration_s, log_dir)
                payload["results"].append(result)
                if raw_dir is not None:
                    raw_dir.mkdir(parents=True, exist_ok=True)
                    raw_path = raw_dir / f"{provider.name}_{mode.name}_{message_size}.json"
                    raw_path.write_text(json.dumps(result, indent=2) + "\n")

                summary = result["summary"]
                print(
                    f"{provider.name}\t{mode.name}\t{message_size}\t"
                    f"{summary['messages_per_sec']:.0f}\t{summary['mib_per_sec']:.3f}\t"
                    f"{_fmt_float(summary['average_latency_ms'])}\t{_fmt_float(summary['p95_latency_ms'])}"
                )

    if args.json_out:
        out_path = Path(args.json_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, indent=2) + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
