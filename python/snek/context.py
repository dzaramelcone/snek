"""snek.context — Request context helpers.

Provides the RequestContext class and current_request() accessor
backed by Python's contextvars. snek creates a new Context per
request to ensure proper isolation.
"""

from __future__ import annotations

import contextvars
from typing import Any


# ── ContextVar for the current request ───────────────────────────────

_current_request_var: contextvars.ContextVar[RequestContext | None] = (
    contextvars.ContextVar("snek_current_request", default=None)
)


def current_request() -> RequestContext:
    """Get the current request context.

    Raises RuntimeError if called outside a request lifecycle.
    """
    ctx = _current_request_var.get()
    if ctx is None:
        raise RuntimeError("current_request() called outside of a request context")
    return ctx


# ── RequestContext ───────────────────────────────────────────────────


class RequestContext:
    """Per-request context accessible from handlers, middleware, and DI.

    Set by the Zig runtime at the start of each request. Provides:
      - .state: dict for arbitrary middleware-set data
      - .id: unique request ID
      - .user: user identity (set by auth middleware)
      - .trace: W3C traceparent value
    """

    def __init__(
        self,
        *,
        request_id: str,
        user: Any = None,
        trace: str | None = None,
    ) -> None:
        self.id: str = request_id
        self.user: Any = user
        self.trace: str | None = trace
        self.state: dict[str, Any] = {}

    def set_user(self, user: Any) -> None:
        """Set the authenticated user (called by auth middleware)."""
        self.user = user

    def set_trace(self, traceparent: str) -> None:
        """Set the W3C traceparent value."""
        self.trace = traceparent
