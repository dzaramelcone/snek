#!/usr/bin/env python3
"""TCP echo control servers for asyncio and uvloop benchmarks."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import socket


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a TCP echo server for event-loop benchmarks.")
    parser.add_argument("--provider", choices=("asyncio", "uvloop"), required=True)
    parser.add_argument("--mode", choices=("streams", "protocol", "sockets"), required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--message-size", type=int, required=True)
    return parser.parse_args()


async def _read_exactly(reader: asyncio.StreamReader, size: int) -> bytes | None:
    try:
        return await reader.readexactly(size)
    except asyncio.IncompleteReadError:
        return None


async def _handle_stream(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, size: int) -> None:
    sock = writer.get_extra_info("socket")
    if sock is not None:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    try:
        while True:
            data = await _read_exactly(reader, size)
            if data is None:
                break
            writer.write(data)
            await writer.drain()
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()


class EchoProtocol(asyncio.Protocol):
    def __init__(self, size: int) -> None:
        self._size = size
        self._transport: asyncio.Transport | None = None
        self._buffer = bytearray()

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self._transport = transport  # type: ignore[assignment]
        sock = transport.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def data_received(self, data: bytes) -> None:
        self._buffer.extend(data)
        if self._transport is None:
            return
        while len(self._buffer) >= self._size:
            chunk = bytes(self._buffer[: self._size])
            del self._buffer[: self._size]
            self._transport.write(chunk)


async def _recv_exactly(loop: asyncio.AbstractEventLoop, sock: socket.socket, size: int) -> bytes | None:
    remaining = size
    chunks: list[bytes] = []
    while remaining > 0:
        chunk = await loop.sock_recv(sock, remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


async def _handle_socket_client(loop: asyncio.AbstractEventLoop, client: socket.socket, size: int) -> None:
    try:
        while True:
            data = await _recv_exactly(loop, client, size)
            if data is None:
                break
            await loop.sock_sendall(client, data)
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass
    finally:
        with contextlib.suppress(OSError):
            client.close()


async def _serve_streams(host: str, port: int, size: int) -> None:
    server = await asyncio.start_server(
        lambda reader, writer: _handle_stream(reader, writer, size),
        host,
        port,
        reuse_address=True,
    )
    async with server:
        await server.serve_forever()


async def _serve_protocol(host: str, port: int, size: int) -> None:
    loop = asyncio.get_running_loop()
    server = await loop.create_server(lambda: EchoProtocol(size), host, port, reuse_address=True)
    async with server:
        await server.serve_forever()


async def _serve_sockets(host: str, port: int, size: int) -> None:
    loop = asyncio.get_running_loop()
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    server_sock.bind((host, port))
    server_sock.listen(socket.SOMAXCONN)
    server_sock.setblocking(False)

    tasks: set[asyncio.Task[None]] = set()
    try:
        while True:
            client, _ = await loop.sock_accept(server_sock)
            client.setblocking(False)
            client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            task = asyncio.create_task(_handle_socket_client(loop, client, size))
            tasks.add(task)
            task.add_done_callback(tasks.discard)
    finally:
        server_sock.close()
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)


async def _main_async(args: argparse.Namespace) -> None:
    if args.mode == "streams":
        await _serve_streams(args.host, args.port, args.message_size)
    elif args.mode == "protocol":
        await _serve_protocol(args.host, args.port, args.message_size)
    else:
        await _serve_sockets(args.host, args.port, args.message_size)


def main() -> int:
    args = _parse_args()
    if args.provider == "uvloop":
        import uvloop

        with asyncio.Runner(loop_factory=uvloop.new_event_loop) as runner:
            runner.run(_main_async(args))
    else:
        asyncio.run(_main_async(args))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
