"""snek.di — Dependency injection decorators and scope management.

First-class DI that works uniformly in middleware AND handlers.
Unlike FastAPI's Depends(), snek DI:
  - validates the full graph at startup (circular + missing deps)
  - supports three scopes (singleton/request/transient)
  - provides yield-based lifecycle management
  - allows testing overrides without monkey-patching
"""

from __future__ import annotations

import enum
from typing import Any, Callable


class Scope(enum.Enum):
    """Injectable lifetime scope."""

    singleton = "singleton"
    request = "request"
    transient = "transient"


class InjectableRegistry:
    """Collects all registered injectables for graph construction.

    The Zig runtime reads this registry at startup to build the
    DependencyGraph and validate it before serving any requests.
    """

    def __init__(self) -> None:
        self._entries: dict[str, InjectableEntry] = {}

    def register(self, entry: InjectableEntry) -> None:
        """Register an injectable factory."""
        self._entries[entry.name] = entry

    def get(self, name: str) -> InjectableEntry | None:
        """Look up an injectable by name."""
        return self._entries.get(name)

    def all_entries(self) -> list[InjectableEntry]:
        """Return all registered entries."""
        return list(self._entries.values())

    def override(self, name: str, replacement: Callable[..., Any]) -> None:
        """Replace an injectable's factory for testing.

        Does not require monkey-patching. The Zig DI engine picks up
        the replacement at the next resolution.
        """
        entry = self._entries.get(name)
        if entry is not None:
            entry.factory = replacement


class InjectableEntry:
    """Metadata for a single injectable."""

    def __init__(
        self,
        name: str,
        factory: Callable[..., Any],
        scope: Scope = Scope.request,
        is_generator: bool = False,
    ) -> None:
        self.name = name
        self.factory = factory
        self.scope = scope
        self.is_generator = is_generator


# ── Module-level registry ────────────────────────────────────────────

_registry = InjectableRegistry()


def injectable(
    scope: str = "request",
) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
    """Decorator to register a function as an injectable dependency.

    Usage:
        @injectable(scope="request")
        async def db_session():
            async with app.db.transaction() as tx:
                yield tx

        @injectable(scope="singleton")
        def config():
            return load_config()
    """
    scope_enum = Scope(scope)

    def decorator(func: Callable[..., Any]) -> Callable[..., Any]:
        import inspect

        is_gen = inspect.isasyncgenfunction(func) or inspect.isgeneratorfunction(func)
        entry = InjectableEntry(
            name=func.__qualname__,
            factory=func,
            scope=scope_enum,
            is_generator=is_gen,
        )
        _registry.register(entry)
        return func

    return decorator


def override(original: Callable[..., Any], replacement: Callable[..., Any]) -> None:
    """Replace an injectable for testing without monkey-patching.

    Usage:
        app.override(db_session, fake_db_session)
    """
    _registry.override(original.__qualname__, replacement)
