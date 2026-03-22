"""Built-in documentation UI endpoints for snek applications.

Call setup_docs(app) to register /docs, /redoc, and /openapi.json.
Only enabled when debug=true or docs.enabled=true in snek.toml.
"""

from __future__ import annotations

import json
from typing import Any

from snek.docs_ui import redoc_html, swagger_html
from snek.openapi import OpenAPIGenerator


def setup_docs(
    app: Any,
    *,
    path: str = "/docs",
    openapi_path: str = "/openapi.json",
    redoc_path: str = "/redoc",
    title: str | None = None,
    version: str = "0.1.0",
    description: str = "",
) -> None:
    """Register documentation routes on the app.

    Serves Swagger UI, ReDoc, and raw OpenAPI JSON. Skips registration
    entirely when docs are disabled (checks debug flag and docs.enabled).
    """
    if not _docs_enabled(app):
        return

    doc_title = title or getattr(app.config, "name", "snek API")

    generator = OpenAPIGenerator(
        title=doc_title,
        version=version,
        description=description,
    )

    # Cache the spec after first generation
    _spec_cache: dict[str, dict] = {}

    @app.route("GET", openapi_path)
    async def openapi_json() -> dict:
        """OpenAPI 3.1 specification."""
        if "spec" not in _spec_cache:
            _spec_cache["spec"] = generator.generate(app)
        return _spec_cache["spec"]

    @app.route("GET", path)
    async def docs_ui():
        """Swagger UI — interactive API explorer."""
        return snek.html(swagger_html(openapi_path, title=doc_title))

    @app.route("GET", redoc_path)
    async def redoc_ui():
        """ReDoc — clean API reference."""
        return snek.html(redoc_html(openapi_path, title=doc_title))


def _docs_enabled(app: Any) -> bool:
    """Check whether documentation should be served."""
    config = getattr(app, "config", None)
    if config is None:
        return True

    # Explicit docs.enabled flag takes priority
    docs_config = getattr(config, "docs", None)
    if docs_config is not None:
        return bool(getattr(docs_config, "enabled", False))

    # Fall back to debug mode
    return bool(getattr(config, "debug", False))


# Lazy import — docs.py uses snek.html() which lives in the top-level package
import snek  # noqa: E402
