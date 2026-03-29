"""Shared coroutine scenarios for event-loop benchmarks."""

from __future__ import annotations

from collections.abc import Awaitable, Callable

JSON_BODIES: dict[str, bytes] = {
    "async_0": b'{"message":"hello"}',
    "async_1": b'{"value":1}',
    "async_10": b'{"value":1}',
}


async def async_0_payload() -> dict[str, object]:
    return {"message": "hello"}


async def _leaf() -> int:
    return 1


async def async_1_payload() -> dict[str, object]:
    return {"value": await _leaf()}


async def _chain(depth: int) -> int:
    if depth <= 0:
        return 1
    return await _chain(depth - 1)


async def async_10_payload() -> dict[str, object]:
    return {"value": await _chain(10)}


SCENARIO_HANDLERS: dict[str, Callable[[], Awaitable[dict[str, object]]]] = {
    "async_0": async_0_payload,
    "async_1": async_1_payload,
    "async_10": async_10_payload,
}
