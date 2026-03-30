"""Local ownership-boundary tests for snek.loop.

These are not upstream CPython tests. They pin the intentional design choice
that one interpreter may only have one active loop family at a time while
`snek.loop` owns asyncio's Task/Future globals.
"""

from __future__ import annotations

import asyncio
import unittest

from _snek_loop_base import _load_snek_loop


class SnekLoopOwnershipTests(unittest.TestCase):
    def setUp(self) -> None:
        super().setUp()
        self._orig_policy = asyncio.get_event_loop_policy()
        self._snek_loop = None
        self._foreign_loop = None

    def tearDown(self) -> None:
        try:
            if self._foreign_loop is not None:
                asyncio.set_event_loop(None)
                self._foreign_loop.close()
        finally:
            if self._snek_loop is not None:
                self._snek_loop.close()
            asyncio.set_event_loop(None)
            asyncio.set_event_loop_policy(self._orig_policy)
            self._foreign_loop = None
            self._snek_loop = None
            super().tearDown()

    def test_rejects_foreign_new_event_loop_while_snek_loop_is_alive(self):
        snek_loop = _load_snek_loop()
        self._snek_loop = snek_loop.new_event_loop()

        with self.assertRaisesRegex(RuntimeError, "mixing loop implementations"):
            asyncio.new_event_loop()

    def test_rejects_foreign_policy_while_snek_loop_is_alive(self):
        snek_loop = _load_snek_loop()
        self._snek_loop = snek_loop.new_event_loop()

        with self.assertRaisesRegex(RuntimeError, "mixing loop implementations"):
            asyncio.set_event_loop_policy(asyncio.DefaultEventLoopPolicy())

    def test_rejects_activating_snek_loop_with_foreign_current_loop(self):
        self._foreign_loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._foreign_loop)

        with self.assertRaisesRegex(RuntimeError, "mixing loop implementations"):
            _load_snek_loop().new_event_loop()

    def test_foreign_loops_work_again_after_snek_loop_closes(self):
        snek_loop = _load_snek_loop()
        loop = snek_loop.new_event_loop()
        loop.close()

        foreign_loop = asyncio.new_event_loop()
        try:
            self.assertIsNotNone(foreign_loop)
        finally:
            foreign_loop.close()

