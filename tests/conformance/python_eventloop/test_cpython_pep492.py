"""Initial upstream coroutine/loop integration coverage for snek.

Adapted from CPython `Lib/test/test_asyncio/test_pep492.py` at commit
`1fd66eadd258223a0e3446b5b23ff2303294112c`.

Source:
https://github.com/python/cpython/blob/1fd66eadd258223a0e3446b5b23ff2303294112c/Lib/test/test_asyncio/test_pep492.py
"""

from __future__ import annotations

import asyncio
import sys
import types

from _snek_loop_base import SnekLoopTestCase


class FakeCoro:
    def send(self, value):
        pass

    def throw(self, typ, val=None, tb=None):
        pass

    def close(self):
        pass

    def __await__(self):
        yield


class BaseTest(SnekLoopTestCase):
    pass


class LockTests(BaseTest):
    def test_context_manager_async_with(self):
        primitives = [
            asyncio.Lock(),
            asyncio.Condition(),
            asyncio.Semaphore(),
            asyncio.BoundedSemaphore(),
        ]

        async def test(lock):
            await asyncio.sleep(0.01)
            self.assertFalse(lock.locked())
            async with lock as _lock:
                self.assertIs(_lock, None)
                self.assertTrue(lock.locked())
                await asyncio.sleep(0.01)
                self.assertTrue(lock.locked())
            self.assertFalse(lock.locked())

        for primitive in primitives:
            self.loop.run_until_complete(test(primitive))
            self.assertFalse(primitive.locked())


class StreamReaderTests(BaseTest):
    def test_readline(self):
        data = b"line1\nline2\nline3"

        stream = asyncio.StreamReader(loop=self.loop)
        stream.feed_data(data)
        stream.feed_eof()

        async def reader():
            lines = []
            async for line in stream:
                lines.append(line)
            return lines

        result = self.loop.run_until_complete(reader())
        self.assertEqual(result, [b"line1\n", b"line2\n", b"line3"])


class CoroutineTests(BaseTest):
    def test_iscoroutine(self):
        async def foo():
            pass

        future = foo()
        try:
            self.assertTrue(asyncio.iscoroutine(future))
        finally:
            future.close()

        self.assertTrue(asyncio.iscoroutine(FakeCoro()))

    def test_async_def_coroutines(self):
        async def bar():
            return "spam"

        async def foo():
            return await bar()

        data = self.loop.run_until_complete(foo())
        self.assertEqual(data, "spam")

        self.loop.set_debug(True)
        data = self.loop.run_until_complete(foo())
        self.assertEqual(data, "spam")

    def test_debug_mode_manages_coroutine_origin_tracking(self):
        async def start():
            self.assertTrue(sys.get_coroutine_origin_tracking_depth() > 0)

        self.assertEqual(sys.get_coroutine_origin_tracking_depth(), 0)
        self.loop.set_debug(True)
        self.loop.run_until_complete(start())
        self.assertEqual(sys.get_coroutine_origin_tracking_depth(), 0)

    def test_types_coroutine(self):
        def gen():
            yield from ()
            return "spam"

        @types.coroutine
        def func():
            return gen()

        async def coro():
            wrapper = func()
            self.assertIsInstance(wrapper, types._GeneratorWrapper)
            return await wrapper

        data = self.loop.run_until_complete(coro())
        self.assertEqual(data, "spam")

    def test_task_print_stack(self):
        task_ref = None

        async def foo():
            frames = task_ref.get_stack(limit=1)
            try:
                self.assertEqual(frames[0].f_code.co_name, "foo")
            finally:
                frames = None

        async def runner():
            nonlocal task_ref
            task_ref = asyncio.ensure_future(foo(), loop=self.loop)
            await task_ref

        self.loop.run_until_complete(runner())

    def test_double_await(self):
        async def afunc():
            await asyncio.sleep(0.1)

        async def runner():
            coro = afunc()
            task = self.loop.create_task(coro)
            try:
                await asyncio.sleep(0)
                await coro
            finally:
                task.cancel()

        self.loop.set_debug(True)
        with self.assertRaises(
            RuntimeError,
            msg="coroutine is being awaited already",
        ):
            self.loop.run_until_complete(runner())
