"""snek — a fast Python web framework backed by Zig."""

from snek.app import App
from . import loop as loop

__all__ = ["App", "loop"]
