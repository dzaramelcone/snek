"""Thin Python shell for the native snek event loop."""

from __future__ import annotations

import asyncio
import concurrent.futures
import os
import sys
from snek import _snek

_MISSING = object()
_UNSET = object()
_ACTIVE_SNEK_LOOPS = 0
_SHIMS_INSTALLED = False
_ENABLE_NATIVE_GATHER = os.getenv("SNEK_EXPERIMENTAL_NATIVE_GATHER") == "1"

_ORIG_ASYNCIO_FUTURE = asyncio.Future
_ORIG_ASYNCIO_TASK = asyncio.Task
_ORIG_FUTURES_FUTURE = asyncio.futures.Future
_ORIG_TASKS_TASK = asyncio.tasks.Task
_ORIG_PY_FUTURE = getattr(asyncio.futures, "_PyFuture", _MISSING)
_ORIG_C_FUTURE = getattr(asyncio.futures, "_CFuture", _MISSING)
_ORIG_PY_TASK = getattr(asyncio.tasks, "_PyTask", _MISSING)
_ORIG_C_TASK = getattr(asyncio.tasks, "_CTask", _MISSING)
_ORIG_ASYNCIO_GATHER = asyncio.gather
_ORIG_TASKS_GATHER = asyncio.tasks.gather
_ORIG_NEW_EVENT_LOOP = asyncio.new_event_loop
_ORIG_SET_EVENT_LOOP = asyncio.set_event_loop
_ORIG_SET_EVENT_LOOP_POLICY = asyncio.set_event_loop_policy
_GATHERING_FUTURE = getattr(asyncio.tasks, "_GatheringFuture", None)
_FUTURE_ADD_TO_AWAITED_BY = getattr(asyncio.futures, "future_add_to_awaited_by", None)
_FUTURE_DISCARD_FROM_AWAITED_BY = getattr(asyncio.futures, "future_discard_from_awaited_by", None)
_stdlib_current_task = getattr(asyncio.tasks, "_py_current_task", asyncio.current_task)
_stdlib_all_tasks = getattr(asyncio.tasks, "_py_all_tasks", asyncio.all_tasks)
_MIXED_LOOP_ERROR = (
    "snek.loop does not support mixing loop implementations in one interpreter; "
    "install snek.loop.EventLoopPolicy() and use only snek loops in this interpreter"
)


def _is_snek_loop(loop) -> bool:
    return isinstance(loop, EventLoop)


def _current_policy_loop(policy):
    if isinstance(policy, EventLoopPolicy):
        return policy._loop
    local = getattr(policy, "_local", None)
    if local is None:
        return None
    return getattr(local, "_loop", None)


def _raise_mixed_loop(detail: str):
    raise RuntimeError(f"{detail}; {_MIXED_LOOP_ERROR}")


def _assert_snek_runtime_ownership() -> None:
    running_loop = None
    get_running_loop = getattr(asyncio.events, "_get_running_loop", None)
    if get_running_loop is not None:
        running_loop = get_running_loop()
    if running_loop is not None and not _is_snek_loop(running_loop):
        _raise_mixed_loop("cannot activate snek.loop while another event loop is running")

    policy = asyncio.get_event_loop_policy()
    current_loop = _current_policy_loop(policy)
    if current_loop is not None and not _is_snek_loop(current_loop):
        _raise_mixed_loop("cannot activate snek.loop while another event loop is current")

    if asyncio.Future is not _ORIG_ASYNCIO_FUTURE or asyncio.Task is not _ORIG_ASYNCIO_TASK:
        _raise_mixed_loop("cannot activate snek.loop while asyncio Task/Future are already patched")


def _guard_foreign_loop(loop) -> None:
    if _ACTIVE_SNEK_LOOPS == 0 or loop is None or _is_snek_loop(loop):
        return
    _raise_mixed_loop(f"cannot use foreign event loop {loop!r} while snek.loop is active")


def _is_snek_future(obj) -> bool:
    return type(obj) in (_snek.Future, _snek.Task)


class _SnekGatheringFuture(_snek.Future):
    __slots__ = ("_children", "_cancel_requested")

    def __init__(self, children, *, loop):
        super().__init__(loop=loop)
        self._children = list(children)
        self._cancel_requested = False

    def cancel(self, msg=None):
        if self.done():
            return False
        ret = False
        for child in self._children:
            if child.cancel(msg=msg):
                ret = True
        if ret:
            self._cancel_requested = True
        return ret


def _cancelled_result(fut):
    return asyncio.exceptions.CancelledError(
        "" if fut._cancel_message is None else fut._cancel_message
    )


def _gather_results(children):
    results = []
    for fut in children:
        if fut.cancelled():
            res = _cancelled_result(fut)
        else:
            res = fut.exception()
            if res is None:
                res = fut.result()
        results.append(res)
    return results


def _gather_cancelled_error(children):
    for fut in children:
        if fut.cancelled():
            return fut._make_cancelled_error()
    return asyncio.exceptions.CancelledError()


def _fast_gather(*coros_or_futures, return_exceptions=False):
    loop = asyncio.events._get_running_loop()

    children = list(coros_or_futures)
    seen = set()

    for fut in children:
        if not _is_snek_future(fut):
            return None
        if fut in seen:
            return None
        seen.add(fut)
        child_loop = fut.get_loop()
        if not _is_snek_loop(child_loop):
            return None
        if loop is None:
            loop = child_loop
        elif loop is not child_loop:
            return None

    if loop is None:
        return None

    outer = _SnekGatheringFuture(children, loop=loop)
    _snek.gather_register(loop._handle, outer, children, return_exceptions)
    return outer


def _fast_gather_existing(*children, return_exceptions=False):
    loop = asyncio.events._get_running_loop()
    seen = set()
    snek_future_types = (_snek.Future, _snek.Task)

    for fut in children:
        if type(fut) not in snek_future_types:
            return None
        if fut in seen:
            return None
        seen.add(fut)
        child_loop = fut._loop
        if type(child_loop) is not EventLoop:
            return None
        if loop is None:
            loop = child_loop
        elif loop is not child_loop:
            return None

    if loop is None:
        return None

    nfuts = len(children)
    nfinished = 0
    done_futs = []
    outer = None

    if not return_exceptions:

        def _done_callback(fut):
            nonlocal nfinished
            nfinished += 1

            if outer is None or outer.done():
                if fut._exception is not None:
                    fut.exception()
                return

            exc = fut._exception
            if exc is not None:
                outer.set_exception(exc)
                return
            if fut.cancelled():
                outer.set_exception(fut._make_cancelled_error())
                return

            if nfinished == nfuts:
                if outer._cancel_requested:
                    outer.set_exception(fut._make_cancelled_error())
                else:
                    outer.set_result([child._result for child in children])

    else:

        def _done_callback(fut):
            nonlocal nfinished
            nfinished += 1

            if outer is None or outer.done():
                if fut._exception is not None:
                    fut.exception()
                return

            if nfinished == nfuts:
                if outer._cancel_requested:
                    outer.set_exception(fut._make_cancelled_error())
                    return

                results = []
                for child in children:
                    if child.cancelled():
                        res = asyncio.exceptions.CancelledError(
                            "" if child._cancel_message is None else child._cancel_message
                        )
                    else:
                        res = child._exception
                        if res is None:
                            res = child.result()
                    results.append(res)
                outer.set_result(results)

    for fut in children:
        if fut.done():
            done_futs.append(fut)
        else:
            fut.add_done_callback(_done_callback)

    outer = _SnekGatheringFuture(children, loop=loop)
    for fut in done_futs:
        _done_callback(fut)
    return outer


def _patched_gather(*coros_or_futures, return_exceptions=False):
    if not coros_or_futures:
        return _ORIG_ASYNCIO_GATHER(*coros_or_futures, return_exceptions=return_exceptions)

    if _ACTIVE_SNEK_LOOPS != 0:
        fast = _fast_gather_existing(*coros_or_futures, return_exceptions=return_exceptions)
        if fast is not None:
            return fast
        if _ENABLE_NATIVE_GATHER:
            fast = _fast_gather(*coros_or_futures, return_exceptions=return_exceptions)
            if fast is not None:
                return fast

    return _ORIG_ASYNCIO_GATHER(*coros_or_futures, return_exceptions=return_exceptions)


def _patched_new_event_loop():
    if _ACTIVE_SNEK_LOOPS != 0 and not isinstance(asyncio.get_event_loop_policy(), EventLoopPolicy):
        _raise_mixed_loop("cannot create a new asyncio loop while snek.loop is active")
    loop = _ORIG_NEW_EVENT_LOOP()
    _guard_foreign_loop(loop)
    return loop


def _patched_set_event_loop(loop) -> None:
    _guard_foreign_loop(loop)
    _ORIG_SET_EVENT_LOOP(loop)


def _patched_set_event_loop_policy(policy) -> None:
    if _ACTIVE_SNEK_LOOPS != 0 and policy is not None and not isinstance(policy, EventLoopPolicy):
        _raise_mixed_loop("cannot install a foreign event loop policy while snek.loop is active")
    _ORIG_SET_EVENT_LOOP_POLICY(policy)


def _install_asyncio_shims() -> None:
    global _ACTIVE_SNEK_LOOPS, _SHIMS_INSTALLED
    if _ACTIVE_SNEK_LOOPS == 0:
        _assert_snek_runtime_ownership()
    _ACTIVE_SNEK_LOOPS += 1
    if _SHIMS_INSTALLED:
        return

    asyncio.Future = _snek.Future
    asyncio.Task = _snek.Task
    asyncio.futures.Future = _snek.Future
    asyncio.tasks.Task = _snek.Task

    if _ORIG_PY_FUTURE is not _MISSING:
        asyncio.futures._PyFuture = _snek.Future
    if _ORIG_C_FUTURE is not _MISSING:
        asyncio.futures._CFuture = _snek.Future
    if _ORIG_PY_TASK is not _MISSING:
        asyncio.tasks._PyTask = _snek.Task
    if _ORIG_C_TASK is not _MISSING:
        asyncio.tasks._CTask = _snek.Task

    asyncio.gather = _patched_gather
    asyncio.tasks.gather = _patched_gather
    asyncio.new_event_loop = _patched_new_event_loop
    asyncio.events.new_event_loop = _patched_new_event_loop
    asyncio.set_event_loop = _patched_set_event_loop
    asyncio.events.set_event_loop = _patched_set_event_loop
    asyncio.set_event_loop_policy = _patched_set_event_loop_policy
    asyncio.events.set_event_loop_policy = _patched_set_event_loop_policy

    _SHIMS_INSTALLED = True


def _restore_asyncio_shims() -> None:
    global _ACTIVE_SNEK_LOOPS, _SHIMS_INSTALLED
    if _ACTIVE_SNEK_LOOPS == 0:
        return
    _ACTIVE_SNEK_LOOPS -= 1
    if _ACTIVE_SNEK_LOOPS != 0 or not _SHIMS_INSTALLED:
        return

    asyncio.Future = _ORIG_ASYNCIO_FUTURE
    asyncio.Task = _ORIG_ASYNCIO_TASK
    asyncio.futures.Future = _ORIG_FUTURES_FUTURE
    asyncio.tasks.Task = _ORIG_TASKS_TASK

    if _ORIG_PY_FUTURE is not _MISSING:
        asyncio.futures._PyFuture = _ORIG_PY_FUTURE
    if _ORIG_C_FUTURE is not _MISSING:
        asyncio.futures._CFuture = _ORIG_C_FUTURE
    if _ORIG_PY_TASK is not _MISSING:
        asyncio.tasks._PyTask = _ORIG_PY_TASK
    if _ORIG_C_TASK is not _MISSING:
        asyncio.tasks._CTask = _ORIG_C_TASK

    asyncio.gather = _ORIG_ASYNCIO_GATHER
    asyncio.tasks.gather = _ORIG_TASKS_GATHER
    asyncio.new_event_loop = _ORIG_NEW_EVENT_LOOP
    asyncio.events.new_event_loop = _ORIG_NEW_EVENT_LOOP
    asyncio.set_event_loop = _ORIG_SET_EVENT_LOOP
    asyncio.events.set_event_loop = _ORIG_SET_EVENT_LOOP
    asyncio.set_event_loop_policy = _ORIG_SET_EVENT_LOOP_POLICY
    asyncio.events.set_event_loop_policy = _ORIG_SET_EVENT_LOOP_POLICY

    _SHIMS_INSTALLED = False


def current_task(loop=None):
    if loop is None:
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return _stdlib_current_task()
    handle = getattr(loop, "_handle", None)
    if isinstance(loop, EventLoop) and handle is not None:
        return _snek.loop_current_task(handle)
    return _stdlib_current_task(loop=loop)


def all_tasks(loop=None):
    if loop is None:
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return _stdlib_all_tasks()
    handle = getattr(loop, "_handle", None)
    if isinstance(loop, EventLoop) and handle is not None:
        return _snek.loop_all_tasks(handle)
    return _stdlib_all_tasks(loop=loop)


if hasattr(asyncio.tasks, "_py_register_task"):
    asyncio.tasks._register_task = asyncio.tasks._py_register_task
if hasattr(asyncio.tasks, "_py_unregister_task"):
    asyncio.tasks._unregister_task = asyncio.tasks._py_unregister_task
if hasattr(asyncio.tasks, "_py_enter_task"):
    asyncio.tasks._enter_task = asyncio.tasks._py_enter_task
if hasattr(asyncio.tasks, "_py_leave_task"):
    asyncio.tasks._leave_task = asyncio.tasks._py_leave_task
asyncio.current_task = current_task
asyncio.tasks.current_task = current_task
asyncio.all_tasks = all_tasks
asyncio.tasks.all_tasks = all_tasks


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


class _BaseEventLoopMethodProxy:
    __slots__ = ("_name",)

    def __init__(self, name: str) -> None:
        self._name = name

    def __get__(self, instance, owner=None):
        if instance is None:
            return self
        instance_dict = object.__getattribute__(instance, "__dict__")
        if self._name in instance_dict:
            return instance_dict[self._name]
        method = getattr(asyncio.base_events.BaseEventLoop, self._name)
        if hasattr(method, "__get__"):
            return method.__get__(instance, owner or type(instance))
        return method

    def __set__(self, instance, value) -> None:
        instance.__dict__[self._name] = value

    def __delete__(self, instance) -> None:
        instance.__dict__.pop(self._name, None)


class EventLoop(asyncio.AbstractEventLoop):
    __slots__ = (
        "_handle",
        "_exception_handler",
        "_current_handle",
        "_default_executor",
        "_task_factory",
    )
    call_exception_handler = _BaseEventLoopMethodProxy("call_exception_handler")
    default_exception_handler = _BaseEventLoopMethodProxy("default_exception_handler")

    def __init__(self) -> None:
        self._handle = None
        self._exception_handler = None
        self._current_handle = None
        self._default_executor = None
        self._task_factory = None
        _install_asyncio_shims()
        try:
            self._handle = _snek.loop_new()
        except Exception:
            _restore_asyncio_shims()
            raise

    def __del__(self) -> None:
        if sys.is_finalizing():
            return
        handle = getattr(self, "_handle", None)
        if handle is None:
            return
        try:
            _snek.loop_free(handle)
        except Exception:
            pass
        self._handle = None
        _restore_asyncio_shims()

    @property
    def _closed(self) -> bool:
        return True if self._handle is None else _snek.loop_is_closed(self._handle)

    @property
    def _ready(self):
        if self._handle is None:
            return range(0)
        return range(_snek.loop_ready_count(self._handle))

    def is_closed(self) -> bool:
        return self._closed

    def is_running(self) -> bool:
        return False if self._handle is None else _snek.loop_is_running(self._handle)

    def get_debug(self) -> bool:
        return False if self._handle is None else _snek.loop_get_debug(self._handle)

    def set_debug(self, enabled: bool) -> None:
        if self._handle is None:
            raise RuntimeError("Event loop is closed")
        _snek.loop_set_debug(self._handle, enabled)

    def time(self) -> float:
        if self._handle is None:
            raise RuntimeError("Event loop is closed")
        return _snek.loop_time(self._handle)

    def create_future(self):
        handle = self._handle
        if handle is None:
            raise RuntimeError("Event loop is closed")
        return _snek.future_new(handle, self)

    def create_task(self, coro, *, name=_UNSET, context=_UNSET, eager_start=_UNSET):
        handle = self._handle
        if handle is None:
            raise RuntimeError("Event loop is closed")
        task_factory = self._task_factory
        if task_factory is not None:
            kwargs = {}
            if name is not _UNSET:
                kwargs["name"] = name
            if context is not _UNSET:
                kwargs["context"] = context
            if eager_start is not _UNSET:
                kwargs["eager_start"] = eager_start
            return task_factory(self, coro, **kwargs)
        if "call_soon" in self.__dict__:
            custom_call_soon = self.__dict__["call_soon"]
            try:
                probe = custom_call_soon(lambda: None)
            except Exception:
                asyncio.base_events.logger.error("Task was destroyed but it is pending")
                raise
            cancel = getattr(probe, "cancel", None)
            if cancel is not None:
                cancel()
        native_context = None if context is _UNSET else context
        native_name = None if name is _UNSET else name
        native_eager_start = None if eager_start is _UNSET else eager_start
        return _snek.task_new(handle, self, coro, native_context, native_name, native_eager_start)

    def get_task_factory(self):
        return self._task_factory

    def set_task_factory(self, factory) -> None:
        if factory is not None and not callable(factory):
            raise TypeError(f"A callable object or None is expected, got {factory!r}")
        self._task_factory = factory

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
        if self._handle is None:
            raise RuntimeError("Event loop is closed")
        _snek.loop_stop(self._handle)

    def close(self) -> None:
        handle = self._handle
        if handle is None:
            return
        _snek.loop_free(handle)
        self._handle = None
        executor = self._default_executor
        self._default_executor = None
        if executor is not None:
            executor.shutdown(wait=False)
        _restore_asyncio_shims()

    def run_forever(self) -> None:
        if self._handle is None:
            raise RuntimeError("Event loop is closed")
        _snek.loop_run_forever(self._handle, self)

    def run_until_complete(self, future):
        if self._handle is None:
            raise RuntimeError("Event loop is closed")
        return _snek.loop_run_until_complete(self._handle, self, future)

    def run_in_executor(self, executor, func, *args):
        if self._handle is None:
            raise RuntimeError("Event loop is closed")
        if executor is None:
            executor = self._default_executor
            if executor is None:
                executor = concurrent.futures.ThreadPoolExecutor(
                    thread_name_prefix="asyncio"
                )
                self._default_executor = executor
        return asyncio.futures.wrap_future(executor.submit(func, *args), loop=self)

    async def shutdown_asyncgens(self):
        return None

    async def shutdown_default_executor(self, timeout=None):
        _ = timeout
        executor = self._default_executor
        self._default_executor = None
        if executor is not None:
            executor.shutdown(wait=True)
        return None

    def get_exception_handler(self):
        return self._exception_handler

    def set_exception_handler(self, handler) -> None:
        if handler is not None and not callable(handler):
            raise TypeError(f"A callable object or None is expected, got {handler!r}")
        self._exception_handler = handler

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
            raise RuntimeError("There is no current event loop in thread 'MainThread'.")
        return self._loop

    def set_event_loop(self, loop) -> None:
        if loop is not None and not _is_snek_loop(loop):
            _raise_mixed_loop(f"cannot attach foreign event loop {loop!r} to snek.loop.EventLoopPolicy")
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


asyncio.EventLoop = EventLoop


__all__ = ["EventLoop", "EventLoopPolicy", "new_event_loop"]
