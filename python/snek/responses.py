"""snek.responses — Response helpers and typed response classes.

Convenience functions for common response patterns:

    return response(data, status=201, headers={"X-Custom": "value"})
    return html("<h1>Hello</h1>")
    return redirect("/login")
    return file("/static/report.pdf")
    return stream(event_generator(), content_type="text/event-stream")
"""

from __future__ import annotations

from typing import Any, AsyncIterator, Iterator


# ── Response helpers ─────────────────────────────────────────────────


def response(
    data: Any = None,
    *,
    status: int = 200,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    """Create a JSON response with optional status and headers."""
    return JSONResponse(data=data, status=status, headers=headers)


def html(content: str, *, status: int = 200) -> HTMLResponse:
    """Create an HTML response."""
    return HTMLResponse(content=content, status=status)


def text(content: str, *, status: int = 200) -> TextResponse:
    """Create a plain text response."""
    return TextResponse(content=content, status=status)


def redirect(url: str, *, status: int = 302) -> RedirectResponse:
    """Create a redirect response."""
    return RedirectResponse(url=url, status=status)


def file(path: str, *, content_type: str | None = None) -> FileResponse:
    """Create a file response (uses sendfile for zero-copy)."""
    return FileResponse(path=path, content_type=content_type)


def stream(
    generator: AsyncIterator[bytes] | Iterator[bytes],
    *,
    content_type: str = "application/octet-stream",
    status: int = 200,
) -> StreamingResponse:
    """Create a streaming response (SSE, chunked transfer)."""
    return StreamingResponse(
        generator=generator, content_type=content_type, status=status
    )


# ── Response classes ─────────────────────────────────────────────────


class JSONResponse:
    """JSON-serialized response."""

    def __init__(
        self,
        data: Any = None,
        *,
        status: int = 200,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.data = data
        self.status = status
        self.headers = headers or {}


class HTMLResponse:
    """HTML content response."""

    def __init__(self, content: str, *, status: int = 200) -> None:
        self.content = content
        self.status = status


class TextResponse:
    """Plain text response."""

    def __init__(self, content: str, *, status: int = 200) -> None:
        self.content = content
        self.status = status


class RedirectResponse:
    """HTTP redirect response."""

    def __init__(self, url: str, *, status: int = 302) -> None:
        self.url = url
        self.status = status


class FileResponse:
    """File response with sendfile support."""

    def __init__(
        self, path: str, *, content_type: str | None = None
    ) -> None:
        self.path = path
        self.content_type = content_type


class StreamingResponse:
    """Streaming response for SSE or chunked transfer."""

    def __init__(
        self,
        generator: AsyncIterator[bytes] | Iterator[bytes],
        *,
        content_type: str = "application/octet-stream",
        status: int = 200,
    ) -> None:
        self.generator = generator
        self.content_type = content_type
        self.status = status
