"""Shared harness for upstream Python event-loop conformance tests."""

from __future__ import annotations

import asyncio
import unittest


def _load_snek_loop():
    try:
        from snek import loop as snek_loop
    except Exception as exc:  # pragma: no cover - current expected failure path
        raise AssertionError(
            "snek.loop is not available. Implement "
            "snek.loop.new_event_loop() and snek.loop.EventLoopPolicy() "
            "to run the upstream Python event-loop conformance suite."
        ) from exc
    return snek_loop


class SnekLoopTestCase(unittest.TestCase):
    """Base class for upstream loop-conformance tests."""

    implementation = "snek"
    loop: asyncio.AbstractEventLoop | None = None

    def new_loop(self) -> asyncio.AbstractEventLoop:
        return _load_snek_loop().new_event_loop()

    def new_policy(self):
        return _load_snek_loop().EventLoopPolicy()

    def setUp(self) -> None:
        super().setUp()
        self.loop = self.new_loop()
        asyncio.set_event_loop_policy(self.new_policy())
        asyncio.set_event_loop(self.loop)

    def tearDown(self) -> None:
        try:
            if self.loop is not None:
                self.loop.close()
        finally:
            asyncio.set_event_loop(None)
            asyncio.set_event_loop_policy(None)
            self.loop = None
            super().tearDown()
