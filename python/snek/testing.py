"""Test utilities for snek applications.

Usage::

    from snek.testing import TestClient

    client = TestClient(app)
    resp = await client.get("/users/42")
    assert resp.status == 200
"""

from __future__ import annotations


class TestResponse:
    """Response from TestClient."""

    status: int
    headers: dict[str, str]
    _body: bytes

    async def json(self) -> dict: ...
    async def text(self) -> str: ...
    def header(self, name: str) -> str | None: ...


class TestClient:
    """Full-stack test client for snek applications.

    Spins up the snek server in-process and makes real HTTP
    requests over loopback. Tests what you ship.
    """

    def __init__(self, app) -> None: ...
    async def get(self, path: str, *, headers: dict[str, str] | None = None) -> TestResponse: ...
    async def post(self, path: str, *, json: dict | None = None, headers: dict[str, str] | None = None) -> TestResponse: ...
    async def put(self, path: str, *, json: dict | None = None, headers: dict[str, str] | None = None) -> TestResponse: ...
    async def delete(self, path: str, *, headers: dict[str, str] | None = None) -> TestResponse: ...
    async def patch(self, path: str, *, json: dict | None = None, headers: dict[str, str] | None = None) -> TestResponse: ...
    async def websocket(self, path: str) -> TestWebSocket: ...


class TestWebSocket:
    """WebSocket test client."""

    async def send(self, data: str | bytes) -> None: ...
    async def recv(self) -> str | bytes: ...
    async def close(self) -> None: ...
