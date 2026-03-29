"""Thin Python shell for the native snek event loop."""

from __future__ import annotations

import asyncio
import sys
from snek import _snek


class _SnekHandle:
    __slots__ = ("_loop", "_slot", "_cancelled", "_repr_fragment", "_context", "__weakref__")

    def __init__(self, loop, context=None) -> None:
        self._loop = loop
        self._slot = None
        self._cancelled = False
        self._repr_fragment = None
        self._context = context

    def __repr__(self) -> str:
        parts = [self.__class__.__name__]
        if self._cancelled:
            parts.append("cancelled")
        fragment = self._repr_fragment
        if fragment is None and self._slot is not None:
            fragment = self._loop._handle_repr(self._slot)
            self._repr_fragment = fragment
        if fragment is not None:
            parts.append(fragment)
        return f"<{' '.join(parts)}>"

    def cancel(self) -> None:
        if self._cancelled:
            return
        self._cancelled = True
        slot = self._slot
        self._slot = None
        if slot is not None:
            self._loop._cancel_handle(slot)

    def cancelled(self) -> bool:
        return self._cancelled

    def get_context(self):
        return self._context

    def _bind(self, slot: int) -> None:
        self._slot = slot

    def _mark_done(self) -> None:
        return None

    def _mark_cancelled(self) -> None:
        self._cancelled = True
        self._slot = None


class _SnekTimerHandle(_SnekHandle):
    __slots__ = ("_when",)

    def __init__(self, when, loop, context=None) -> None:
        super().__init__(loop, context=context)
        self._when = when

    def __repr__(self) -> str:
        parts = [self.__class__.__name__]
        if self._cancelled:
            parts.append("cancelled")
        parts.append(f"when={self._when}")
        fragment = self._repr_fragment
        if fragment is None and self._slot is not None:
            fragment = self._loop._handle_repr(self._slot)
            self._repr_fragment = fragment
        if fragment is not None:
            parts.append(fragment)
        return f"<{' '.join(parts)}>"

    def cancel(self) -> None:
        if not self._cancelled:
            self._loop._timer_handle_cancelled(self)
        super().cancel()

    def when(self) -> float:
        return self._when


class EventLoop:
    __slots__ = ("_handle",)

    def __init__(self) -> None:
        self._handle = _snek.loop_new()

    def __del__(self) -> None:
        handle = getattr(self, "_handle", None)
        if handle is None:
            return
        try:
            _snek.loop_free(handle)
        except Exception:
            pass
        self._handle = None

    @property
    def _closed(self) -> bool:
        return True if self._handle is None else _snek.loop_is_closed(self._handle)

    def is_closed(self) -> bool:
        return self._closed

    def is_running(self) -> bool:
        return False if self._handle is None else _snek.loop_is_running(self._handle)

    def get_debug(self) -> bool:
        return False if self._handle is None else _snek.loop_get_debug(self._handle)

    def set_debug(self, enabled: bool) -> None:
        _snek.loop_set_debug(self._handle, enabled)

    def time(self) -> float:
        return _snek.loop_time(self._handle)

    def create_future(self):
        return asyncio.Future(loop=self)

    def create_task(self, coro, *, name=None, context=None):
        if self.is_closed():
            raise RuntimeError("Event loop is closed")
        return asyncio.tasks.Task(coro, loop=self, name=name, context=context)

    def call_soon(self, callback, *args, context=None):
        if self.is_closed():
            raise RuntimeError("Event loop is closed")
        handle = _SnekHandle(self, context=context)
        slot = _snek.loop_call_soon(self._handle, self, handle, callback, args, context)
        handle._bind(slot)
        return handle

    def call_soon_threadsafe(self, callback, *args, context=None):
        return self.call_soon(callback, *args, context=context)

    def call_at(self, when, callback, *args, context=None):
        if self.is_closed():
            raise RuntimeError("Event loop is closed")
        handle = _SnekTimerHandle(when, self, context=context)
        slot = _snek.loop_call_at(self._handle, self, when, handle, callback, args, context)
        handle._bind(slot)
        return handle

    def call_later(self, delay, callback, *args, context=None):
        return self.call_at(self.time() + delay, callback, *args, context=context)

    def stop(self) -> None:
        _snek.loop_stop(self._handle)

    def close(self) -> None:
        if self._handle is None:
            return
        _snek.loop_close(self._handle)

    def run_forever(self) -> None:
        _snek.loop_run_forever(self._handle, self)

    def run_until_complete(self, future):
        return _snek.loop_run_until_complete(self._handle, self, future)

    def call_exception_handler(self, context):
        message = context.get("message", "Unhandled exception in event loop")
        exception = context.get("exception")
        print(message, file=sys.stderr)
        if exception is not None:
            print(repr(exception), file=sys.stderr)

    def default_exception_handler(self, context):
        self.call_exception_handler(context)

    def get_exception_handler(self):
        return None

    def set_exception_handler(self, handler) -> None:
        if handler is not None:
            raise NotImplementedError("custom exception handlers are not supported yet")

    def _cancel_handle(self, slot: int) -> None:
        _snek.loop_handle_cancel(self._handle, slot)

    def _handle_repr(self, slot: int):
        return _snek.loop_handle_repr(self._handle, slot, self.get_debug())

    def _timer_handle_cancelled(self, handle) -> None:
        _ = handle


class EventLoopPolicy(asyncio.AbstractEventLoopPolicy):
    __slots__ = ("_loop",)

    def __init__(self) -> None:
        self._loop = None

    def get_event_loop(self):
        if self._loop is None:
            self._loop = self.new_event_loop()
        return self._loop

    def set_event_loop(self, loop) -> None:
        self._loop = loop

    def new_event_loop(self):
        return EventLoop()

    def get_child_watcher(self):
        return None

    def set_child_watcher(self, watcher) -> None:
        if watcher is not None:
            raise NotImplementedError("child watchers are not supported")


def new_event_loop():
    return EventLoop()


__all__ = ["EventLoop", "EventLoopPolicy", "new_event_loop"]
