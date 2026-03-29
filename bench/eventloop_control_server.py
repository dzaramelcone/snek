#!/usr/bin/env python3
"""Minimal HTTP control server for asyncio and uvloop event-loop benchmarks."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import socket
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
PYTHON_DIR = ROOT_DIR / "python"

sys.path.insert(0, str(ROOT_DIR))
sys.path.insert(0, str(PYTHON_DIR))

from bench.scenarios.eventloop_shared import JSON_BODIES, SCENARIO_HANDLERS

REQUEST_END = b"\r\n\r\n"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a control HTTP server for event-loop benchmarks.")
    parser.add_argument("--provider", choices=("asyncio", "uvloop"), required=True)
    parser.add_argument("--scenario", choices=tuple(SCENARIO_HANDLERS), required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    return parser.parse_args()


def _response_bytes(scenario_name: str) -> bytes:
    body = JSON_BODIES[scenario_name]
    return (
        b"HTTP/1.1 200 OK\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: "
        + str(len(body)).encode()
        + b"\r\n"
        b"Connection: keep-alive\r\n"
        b"\r\n"
        + body
    )


async def _read_request(reader: asyncio.StreamReader) -> bool:
    try:
        await reader.readuntil(REQUEST_END)
        return True
    except asyncio.IncompleteReadError:
        return False
    except asyncio.LimitOverrunError:
        return False


async def _handle_client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    scenario_name: str,
) -> None:
    try:
        sock = writer.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        handler = SCENARIO_HANDLERS[scenario_name]
        response = _response_bytes(scenario_name)

        while await _read_request(reader):
            await handler()
            writer.write(response)
            await writer.drain()
    except asyncio.CancelledError:
        raise
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()


async def _serve(host: str, port: int, scenario_name: str) -> None:
    server = await asyncio.start_server(
        lambda reader, writer: _handle_client(reader, writer, scenario_name),
        host,
        port,
        reuse_address=True,
    )
    async with server:
        await server.serve_forever()


def main() -> int:
    args = _parse_args()

    if args.provider == "uvloop":
        import uvloop

        with asyncio.Runner(loop_factory=uvloop.new_event_loop) as runner:
            runner.run(_serve(args.host, args.port, args.scenario))
    else:
        asyncio.run(_serve(args.host, args.port, args.scenario))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
