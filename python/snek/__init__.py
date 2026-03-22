"""snek — a fast Python web framework backed by Zig.

Public API surface. Everything users need is importable from `snek`.
"""

from __future__ import annotations

# ── Core application ─────────────────────────────────────────────────
from snek._snek import App

# ── Models & validation ──────────────────────────────────────────────
from snek.models import Model, Field

# ── Parameter source wrappers ────────────────────────────────────────
# Reference: FastAPI parameter types (https://fastapi.tiangolo.com/reference/parameters/)
from snek._snek import Body, Query, Path, Header, Cookie, Form, File

# ── Constraints (Annotated metadata) ────────────────────────────────
from snek._snek import Gt, Ge, Lt, Le, MinLen, MaxLen, Pattern, Email, OneOf

# ── Request / Response ───────────────────────────────────────────────
from snek._snek import Request, WebSocket
from snek.responses import (
    JSONResponse,
    HTMLResponse,
    TextResponse,
    RedirectResponse,
    FileResponse,
    StreamingResponse,
    response,
    html,
    text,
    redirect,
    file,
    stream,
)

# ── HTTP exceptions ──────────────────────────────────────────────────
from snek.exceptions import (
    SnekError,
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    MethodNotAllowed,
    Conflict,
    Gone,
    UnprocessableEntity,
    TooManyRequests,
    InternalServerError,
)

# ── Dependency injection ─────────────────────────────────────────────
from snek.di import injectable, override, Scope
from snek._snek import Inject, Transaction

# ── Request context ──────────────────────────────────────────────────
from snek.context import RequestContext, current_request

# ── Background tasks ────────────────────────────────────────────────
from snek.background import BackgroundTask, spawn

# ── Utilities ────────────────────────────────────────────────────────
from snek._snek import (
    hash_password,
    verify_password,
    verify_signature,
    unsigned_value,
    sign,
    generate_id,
    json_encode,
    json_decode,
    urlencode,
)

# ── Documentation ────────────────────────────────────────────────────
from snek import docs  # noqa: F401

# ── Testing (not re-exported; import via `from snek.testing import TestClient`)
# See snek.testing for TestClient, TestResponse, TestWebSocket.

__all__ = [
    # Core
    "App",
    "Model",
    "Field",
    # Parameters (ref: FastAPI parameter types)
    "Body",
    "Query",
    "Path",
    "Header",
    "Cookie",
    "Form",
    "File",
    # Constraints
    "Gt",
    "Ge",
    "Lt",
    "Le",
    "MinLen",
    "MaxLen",
    "Pattern",
    "Email",
    "OneOf",
    # Request/Response
    "Request",
    "WebSocket",
    "JSONResponse",
    "HTMLResponse",
    "TextResponse",
    "RedirectResponse",
    "FileResponse",
    "StreamingResponse",
    "response",
    "html",
    "text",
    "redirect",
    "file",
    "stream",
    # Exceptions
    "SnekError",
    "BadRequest",
    "Unauthorized",
    "Forbidden",
    "NotFound",
    "MethodNotAllowed",
    "Conflict",
    "Gone",
    "UnprocessableEntity",
    "TooManyRequests",
    "InternalServerError",
    # DI
    "injectable",
    "override",
    "Scope",
    "Inject",
    "Transaction",
    # Request context
    "RequestContext",
    "current_request",
    # Background tasks
    "BackgroundTask",
    "spawn",
    # Utilities
    "hash_password",
    "verify_password",
    "verify_signature",
    "unsigned_value",
    "sign",
    "generate_id",
    "json_encode",
    "json_decode",
    "urlencode",
    # Docs
    "docs",
]
