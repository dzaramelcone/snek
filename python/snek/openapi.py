"""OpenAPI 3.1 schema generator for snek applications.

Introspects the route registry, Model definitions, and type annotations
to produce a complete OpenAPI spec — no manual schema authoring needed.
"""

from __future__ import annotations

import inspect
import typing
from typing import Any, get_type_hints

from snek.models import Model, _model_registry, _type_to_schema

# Type wrappers that snek uses for parameter sources
_PARAM_SOURCES = {"Body", "Query", "Path", "Header"}


class OpenAPIGenerator:
    """Walks an snek.App's route table and builds an OpenAPI 3.1 spec."""

    def __init__(
        self,
        *,
        title: str = "snek API",
        version: str = "0.1.0",
        description: str = "",
    ) -> None:
        self.title = title
        self.version = version
        self.description = description
        self._schemas: dict[str, dict] = {}

    def generate(self, app: Any) -> dict:
        """Produce the full OpenAPI 3.1 spec dict from an app instance."""
        paths: dict[str, dict] = {}

        for route in app.routes:
            path = _zig_path_to_openapi(route.path)
            method = route.method.lower()
            operation = self._route_to_operation(route)
            paths.setdefault(path, {})[method] = operation

        spec: dict[str, Any] = {
            "openapi": "3.1.0",
            "info": {
                "title": self.title,
                "version": self.version,
            },
            "paths": paths,
        }

        if self.description:
            spec["info"]["description"] = self.description

        if self._schemas:
            spec["components"] = {"schemas": self._schemas}

        security_schemes = self._build_security_schemes(app)
        if security_schemes:
            spec.setdefault("components", {})["securitySchemes"] = security_schemes

        return spec

    def _route_to_operation(self, route: Any) -> dict:
        """Convert a single route into an OpenAPI Operation object."""
        handler = route.handler
        hints = get_type_hints(handler, include_extras=True)
        sig = inspect.signature(handler)

        operation: dict[str, Any] = {}

        # Summary and description from decorator kwargs or docstring
        if hasattr(route, "summary") and route.summary:
            operation["summary"] = route.summary
        if handler.__doc__:
            doc = inspect.cleandoc(handler.__doc__)
            if "summary" not in operation:
                operation["summary"] = doc.split("\n")[0]
            if "\n" in doc:
                operation["description"] = doc

        # Tags
        if hasattr(route, "tags") and route.tags:
            operation["tags"] = list(route.tags)

        # Operation ID from function name
        operation["operationId"] = handler.__name__

        # Parameters (Query, Path, Header)
        parameters: list[dict] = []
        request_body: dict | None = None

        for name, param in sig.parameters.items():
            hint = hints.get(name)
            if hint is None:
                continue

            source, inner_type = _unwrap_param_source(hint)

            if source == "Body":
                request_body = self._build_request_body(inner_type)
            elif source in ("Query", "Path", "Header"):
                p = self._annotation_to_param(name, source, inner_type, param)
                parameters.append(p)
            # Skip Request, injected deps, etc.

        if parameters:
            operation["parameters"] = parameters
        if request_body:
            operation["requestBody"] = request_body

        # Response schema from return type
        return_hint = hints.get("return")
        operation["responses"] = self._resolve_response_schema(return_hint, route)

        return operation

    def _annotation_to_param(
        self, name: str, source: str, inner_type: Any, param: inspect.Parameter
    ) -> dict:
        """Convert a typed parameter into an OpenAPI Parameter object."""
        location_map = {"Query": "query", "Path": "path", "Header": "header"}
        schema = _type_to_schema(inner_type)

        p: dict[str, Any] = {
            "name": name,
            "in": location_map[source],
            "schema": schema,
        }

        if source == "Path":
            p["required"] = True
        elif param.default is not inspect.Parameter.empty:
            p["schema"]["default"] = param.default
        else:
            p["required"] = True

        return p

    def _build_request_body(self, body_type: Any) -> dict:
        """Build a requestBody from a Body[T] inner type."""
        if isinstance(body_type, type) and issubclass(body_type, Model):
            self._register_schema(body_type)
            return {
                "required": True,
                "content": {
                    "application/json": {
                        "schema": {"$ref": f"#/components/schemas/{body_type.__name__}"},
                    }
                },
            }
        return {
            "required": True,
            "content": {
                "application/json": {
                    "schema": _type_to_schema(body_type),
                }
            },
        }

    def _resolve_response_schema(self, return_hint: Any, route: Any) -> dict:
        """Build the responses object from the return type annotation."""
        # Default success status by method
        status = "200"
        if hasattr(route, "method") and route.method == "POST":
            status = "201"
        if hasattr(route, "method") and route.method == "DELETE":
            status = "204"

        # Check for status overrides
        if hasattr(route, "status") and route.status:
            status = str(route.status)

        if return_hint is None or return_hint is type(None):
            return {status: {"description": "Success"}}

        if isinstance(return_hint, type) and issubclass(return_hint, Model):
            self._register_schema(return_hint)
            return {
                status: {
                    "description": "Success",
                    "content": {
                        "application/json": {
                            "schema": {
                                "$ref": f"#/components/schemas/{return_hint.__name__}"
                            }
                        }
                    },
                }
            }

        schema = _type_to_schema(return_hint)
        if schema:
            return {
                status: {
                    "description": "Success",
                    "content": {"application/json": {"schema": schema}},
                }
            }

        return {status: {"description": "Success"}}

    def _register_schema(self, model_class: type) -> None:
        """Add a Model's JSON Schema to the components/schemas map.

        Recursively registers any nested Model references.
        """
        if model_class.__name__ in self._schemas:
            return

        schema = model_class.model_json_schema()
        self._schemas[model_class.__name__] = schema

        # Walk properties for nested $ref models
        for prop in schema.get("properties", {}).values():
            ref = prop.get("$ref", "")
            if ref.startswith("#/components/schemas/"):
                ref_name = ref.rsplit("/", 1)[-1]
                for cls in _model_registry.values():
                    if cls.__name__ == ref_name:
                        self._register_schema(cls)
                        break

            # Also check array items
            items = prop.get("items", {})
            ref = items.get("$ref", "")
            if ref.startswith("#/components/schemas/"):
                ref_name = ref.rsplit("/", 1)[-1]
                for cls in _model_registry.values():
                    if cls.__name__ == ref_name:
                        self._register_schema(cls)
                        break

    def _build_security_schemes(self, app: Any) -> dict:
        """Extract security schemes from app config."""
        schemes: dict[str, Any] = {}

        if hasattr(app, "config") and hasattr(app.config, "jwt"):
            schemes["bearerAuth"] = {
                "type": "http",
                "scheme": "bearer",
                "bearerFormat": "JWT",
            }

        if hasattr(app, "config") and hasattr(app.config, "oauth"):
            for provider_name in app.config.oauth:
                provider = app.config.oauth[provider_name]
                schemes[f"oauth2_{provider_name}"] = {
                    "type": "oauth2",
                    "flows": {
                        "authorizationCode": {
                            "authorizationUrl": provider.authorize_url,
                            "tokenUrl": provider.token_url,
                            "scopes": {
                                s: s for s in provider.scope.split()
                            },
                        }
                    },
                }

        return schemes

    def _extract_constraints(self, annotation: Any) -> dict:
        """Pull snek constraint metadata into JSON Schema keywords.

        Delegates to the shared _type_to_schema which already handles
        Annotated[T, Gt(0), MaxLen(200)] etc.
        """
        return _type_to_schema(annotation)

    def _model_to_schema(self, model_class: type) -> dict:
        """Convert a snek.Model subclass to a JSON Schema dict."""
        return model_class.model_json_schema()


# ── Helpers ──────────────────────────────────────────────────────────


def _zig_path_to_openapi(path: str) -> str:
    """Convert snek's {param} path syntax to OpenAPI's {param} syntax.

    snek already uses {param}, so this is mostly a passthrough.
    """
    return path


def _unwrap_param_source(hint: Any) -> tuple[str | None, Any]:
    """Unwrap Body[T], Query[T], Path[T], Header[T] to (source_name, T).

    Returns (None, hint) for non-source annotations like Request or deps.
    """
    origin = getattr(hint, "__origin__", None)

    # Direct: Body[T] where Body is a generic alias
    origin_name = getattr(origin, "__name__", "") or getattr(origin, "_name", "")
    if origin_name in _PARAM_SOURCES:
        inner = hint.__args__[0] if hasattr(hint, "__args__") and hint.__args__ else Any
        return (origin_name, inner)

    # Annotated[T, ...] — check if T itself is a source wrapper
    if origin is typing.Annotated:
        return _unwrap_param_source(hint.__args__[0])

    # Check class name directly (for non-generic usage)
    cls_name = getattr(hint, "__name__", "")
    if cls_name in _PARAM_SOURCES:
        return (cls_name, Any)

    return (None, hint)
