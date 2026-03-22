"""snek.background — Background task support.

Fire-and-forget tasks submitted to the Zig scheduler via app.spawn().
These run outside the request lifecycle.
"""

from __future__ import annotations

from typing import Any, Callable


class BackgroundTask:
    """A background task to be spawned on the Zig scheduler.

    Wraps a callable with its arguments. The Zig runtime drives
    the coroutine (if async) or executes it directly (if sync)
    after the current request completes.
    """

    def __init__(
        self,
        func: Callable[..., Any],
        *args: Any,
        **kwargs: Any,
    ) -> None:
        self.func = func
        self.args = args
        self.kwargs = kwargs


def spawn(func: Callable[..., Any], *args: Any, **kwargs: Any) -> BackgroundTask:
    """Create and submit a fire-and-forget background task.

    Usage:
        app.spawn(send_welcome_email, user_id=user.id)

    The task is submitted to the Zig scheduler and runs outside
    the request lifecycle. Exceptions in background tasks are
    logged but do not affect the response.
    """
    return BackgroundTask(func, *args, **kwargs)
