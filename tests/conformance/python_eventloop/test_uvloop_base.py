"""Initial upstream loop-conformance coverage for snek.

Adapted from uvloop `tests/test_base.py` at commit
`a308f75ff8f133262d234e87b1263dd1571894c2`.

Source:
https://github.com/MagicStack/uvloop/blob/a308f75ff8f133262d234e87b1263dd1571894c2/tests/test_base.py
"""

from __future__ import annotations

import asyncio
import time
import weakref

from _snek_loop_base import SnekLoopTestCase


class _TestBase:
    def test_handle_weakref(self):
        handles = weakref.WeakValueDictionary()
        handle = self.loop.call_soon(lambda: None)
        handles["handle"] = handle

    def test_close(self):
        self.assertFalse(self.loop._closed)
        self.assertFalse(self.loop.is_closed())
        self.loop.close()
        self.assertTrue(self.loop._closed)
        self.assertTrue(self.loop.is_closed())

        self.loop.close()
        self.loop.close()

        future = asyncio.Future()
        self.assertRaises(RuntimeError, self.loop.run_forever)
        self.assertRaises(RuntimeError, self.loop.run_until_complete, future)

    def test_call_soon_1(self):
        calls = []

        def cb(inc):
            calls.append(inc)
            self.loop.stop()

        self.loop.call_soon(cb, 10)

        handle = self.loop.call_soon(cb, 100)
        self.assertIn(".cb", repr(handle))
        handle.cancel()
        self.assertIn("cancelled", repr(handle))

        self.loop.call_soon(cb, 1)

        self.loop.run_forever()

        self.assertEqual(calls, [10, 1])

    def test_call_soon_2(self):
        waiter = self.loop.create_future()
        waiter_ref = weakref.ref(waiter)
        self.loop.call_soon(lambda future: future.set_result(None), waiter)
        self.loop.run_until_complete(waiter)
        del waiter
        self.assertIsNone(waiter_ref())

    def test_call_soon_3(self):
        waiter = self.loop.create_future()
        waiter_ref = weakref.ref(waiter)
        self.loop.call_soon(lambda future=waiter: future.set_result(None))
        self.loop.run_until_complete(waiter)
        del waiter
        self.assertIsNone(waiter_ref())

    def test_call_soon_base_exc(self):
        def cb():
            raise KeyboardInterrupt()

        self.loop.call_soon(cb)

        with self.assertRaises(KeyboardInterrupt):
            self.loop.run_forever()

        self.assertFalse(self.loop.is_closed())

    def test_now_update(self):
        async def run():
            started = self.loop.time()
            time.sleep(0.05)
            return self.loop.time() - started

        delta = self.loop.run_until_complete(run())
        self.assertTrue(delta > 0.049 and delta < 0.6)

    def test_call_later_1(self):
        calls = []

        def cb(inc=10, stop=False):
            calls.append(inc)
            self.assertTrue(self.loop.is_running())
            if stop:
                self.loop.call_soon(self.loop.stop)

        self.loop.call_later(0.05, cb)

        handle = self.loop.call_later(0.05, cb, 100, True)
        self.assertIn(".cb", repr(handle))
        handle.cancel()
        self.assertIn("cancelled", repr(handle))

        self.loop.call_later(0.05, cb, 1, True)
        self.loop.call_later(1000, cb, 1000)

        started = time.monotonic()
        self.loop.run_forever()
        finished = time.monotonic()

        self.assertEqual(calls, [10, 1])
        self.assertFalse(self.loop.is_running())

        self.assertLess(finished - started, 0.3)
        self.assertGreater(finished - started, 0.04)

    def test_call_later_2(self):
        async def main():
            await asyncio.sleep(0.001)
            time.sleep(0.01)
            await asyncio.sleep(0.01)

        started = time.monotonic()
        self.loop.run_until_complete(main())
        elapsed = time.monotonic() - started
        self.assertGreater(elapsed, 0.019)

    def test_call_later_3(self):
        waiter = self.loop.create_future()
        waiter_ref = weakref.ref(waiter)
        self.loop.call_later(0.01, lambda future: future.set_result(None), waiter)
        self.loop.run_until_complete(waiter)
        del waiter
        self.assertIsNone(waiter_ref())

    def test_call_later_4(self):
        waiter = self.loop.create_future()
        waiter_ref = weakref.ref(waiter)
        self.loop.call_later(0.01, lambda future=waiter: future.set_result(None))
        self.loop.run_until_complete(waiter)
        del waiter
        self.assertIsNone(waiter_ref())

    def test_call_later_negative(self):
        calls = []

        def cb(value):
            calls.append(value)
            self.loop.stop()

        self.loop.call_later(-1, cb, "a")
        self.loop.run_forever()
        self.assertEqual(calls, ["a"])

    def test_call_at(self):
        total = 0

        def cb(inc):
            nonlocal total
            total += inc
            self.loop.stop()

        when = self.loop.time() + 0.05
        self.loop.call_at(when, cb, 100).cancel()
        self.loop.call_at(when, cb, 10)

        started = time.monotonic()
        self.loop.run_forever()
        finished = time.monotonic()

        self.assertEqual(total, 10)
        self.assertLess(finished - started, 0.07)
        self.assertGreater(finished - started, 0.045)

    def test_loop_call_later_handle_when(self):
        cb = lambda: False  # noqa: E731
        delay = 1.0
        loop_t = self.loop.time()
        handle = self.loop.call_later(delay, cb)
        self.assertAlmostEqual(handle.when(), loop_t + delay, places=2)
        handle.cancel()
        self.assertTrue(handle.cancelled())
        self.assertAlmostEqual(handle.when(), loop_t + delay, places=2)

    def test_loop_call_later_handle_when_after_fired(self):
        future = self.loop.create_future()
        handle = self.loop.call_later(0.05, future.set_result, None)
        when = handle.when()
        self.loop.run_until_complete(future)
        self.assertEqual(handle.when(), when)

    def test_run_until_complete_type_error(self):
        with self.assertRaises(TypeError):
            self.loop.run_until_complete("blah")

    def test_run_until_complete_loop(self):
        task = asyncio.Future()
        other_loop = self.new_loop()
        self.addCleanup(other_loop.close)
        with self.assertRaises(ValueError):
            other_loop.run_until_complete(task)

    def test_run_until_complete_error(self):
        async def foo():
            raise ValueError("aaa")

        with self.assertRaisesRegex(ValueError, "aaa"):
            self.loop.run_until_complete(foo())

    def test_run_until_complete_loop_orphan_future_close_loop(self):
        async def foo(delay):
            await asyncio.sleep(delay)

        def throw():
            raise KeyboardInterrupt

        self.loop.call_soon(throw)
        try:
            self.loop.run_until_complete(foo(0.1))
        except KeyboardInterrupt:
            pass

        self.loop.run_until_complete(foo(0.2))

    def test_run_until_complete_keyboard_interrupt(self):
        async def raise_keyboard_interrupt():
            raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            self.loop.run_until_complete(raise_keyboard_interrupt())

        marker = {"called": False}

        def func():
            self.loop.stop()
            marker["called"] = True

        self.loop.call_later(0.01, func)
        self.loop.run_forever()
        self.assertTrue(marker["called"])


class TestBaseSnek(_TestBase, SnekLoopTestCase):
    pass
