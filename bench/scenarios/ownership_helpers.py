from __future__ import annotations

import threading
import time
from typing import Any


_cached_value: Any = None
_cached_view = None
_thread_value: Any = None
_thread_mutated_value: Any = None
_thread_view = None


async def passthrough(value: Any) -> Any:
    return await _identity(value)


async def mutate_model(model: Any) -> Any:
    await _identity(None)
    model.description = "changed-in-helper"
    return model


async def extract_idea(joined: Any) -> Any:
    return await _identity(joined.idea)


async def inspect_request(req: Any) -> dict[str, Any]:
    await _identity(None)
    return _request_summary(req)


def _request_summary(req: Any) -> dict[str, Any]:
    headers = dict(req.headers)
    params = dict(req.params)
    return {
        "method": req.method,
        "path": req.path,
        "body": None if req.body is None else req.body.decode("utf-8"),
        "headers": headers,
        "params": params,
        "keepalive": bool(req.keepalive),
    }


def reset() -> None:
    global _cached_value, _cached_view, _thread_value, _thread_mutated_value, _thread_view
    _cached_value = None
    _cached_view = None
    _thread_value = None
    _thread_mutated_value = None
    _thread_view = None


def cache_value(value: Any) -> None:
    global _cached_value
    _cached_value = value


def get_cached_value() -> Any:
    return _cached_value


def cache_view(view) -> None:
    global _cached_view
    _cached_view = view


def get_cached_view():
    return _cached_view


def spawn_store_value_later(value: Any, delay_s: float = 0.05) -> None:
    def worker() -> None:
        time.sleep(delay_s)
        global _thread_value
        _thread_value = value

    threading.Thread(target=worker).start()


def get_thread_value() -> Any:
    return _thread_value


def spawn_mutate_and_store_later(value: Any, delay_s: float = 0.05) -> None:
    def worker() -> None:
        time.sleep(delay_s)
        value.description = "changed-in-thread"
        global _thread_mutated_value
        _thread_mutated_value = value

    threading.Thread(target=worker).start()


def get_thread_mutated_value() -> Any:
    return _thread_mutated_value


def spawn_store_view_later(view, delay_s: float = 0.05) -> None:
    def worker() -> None:
        time.sleep(delay_s)
        global _thread_view
        _thread_view = view

    threading.Thread(target=worker).start()


def get_thread_view():
    return _thread_view


async def _identity(value: Any) -> Any:
    return value
