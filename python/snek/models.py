"""snek.Model — the base model class for request/response shapes.

Feels like pydantic, but validation happens in Zig for speed.
Schema generation stays in Python (introspecting annotations).
"""

from __future__ import annotations

import inspect
from datetime import datetime
from typing import Any, ClassVar, get_type_hints

# Registry of all Model subclasses, keyed by qualified name.
_model_registry: dict[str, type[Model]] = {}


class Model:
    """Base class for snek data models.

    Subclass this to define request bodies, response shapes, and
    any structured data that crosses the Python/Zig boundary.

    Validation is dispatched to the Zig runtime via the C extension.
    Schema generation uses Python's typing introspection so OpenAPI
    docs stay in pure Python with zero Zig calls.
    """

    _schema_cache: ClassVar[dict | None] = None

    def __init_subclass__(cls, **kwargs: Any) -> None:
        super().__init_subclass__(**kwargs)
        qualname = f"{cls.__module__}.{cls.__qualname__}"
        _model_registry[qualname] = cls
        cls._schema_cache = None
        # Trigger schema compilation in Zig at import time.
        # The C extension walks cls.__annotations__ via get_type_hints
        # and builds a SchemaNode tree for fused decode+validate.
        _compile_schema_in_zig(cls)

    def __init__(self, **data: Any) -> None:
        hints = get_type_hints(self.__class__, include_extras=True)
        for name, _hint in hints.items():
            value = data.get(name, getattr(self.__class__, name, _MISSING))
            if value is _MISSING:
                raise ValueError(f"missing required field: {name}")
            object.__setattr__(self, name, value)

    @classmethod
    def model_json_schema(cls) -> dict:
        """Return a JSON Schema dict for this model.

        Uses cached result after first call. The schema follows
        JSON Schema draft 2020-12, compatible with OpenAPI 3.1.

        Calls the Zig schema serializer when the C extension is loaded,
        falls back to pure-Python introspection otherwise.
        """
        if cls._schema_cache is not None:
            return cls._schema_cache

        hints = get_type_hints(cls, include_extras=True)
        properties: dict[str, Any] = {}
        required: list[str] = []

        for name, hint in hints.items():
            prop_schema = _type_to_schema(hint)
            properties[name] = prop_schema

            # Field is required if the class has no default for it
            if not hasattr(cls, name):
                required.append(name)

        schema: dict[str, Any] = {
            "type": "object",
            "title": cls.__name__,
            "properties": properties,
        }
        if required:
            schema["required"] = required

        cls._schema_cache = schema
        return schema

    @classmethod
    def model_validate(cls, data: dict) -> "Model":
        """Validate a dict and return a model instance.

        In production this dispatches to Zig for fused decode+validate.
        The Python fallback does basic construction.
        """
        return cls(**data)

    def model_dump(self) -> dict:
        """Serialize this model instance to a plain dict."""
        hints = get_type_hints(self.__class__, include_extras=True)
        out: dict[str, Any] = {}
        for name in hints:
            value = getattr(self, name)
            if isinstance(value, Model):
                value = value.model_dump()
            out[name] = value
        return out

    def json(self) -> str:
        """Serialize to a JSON string."""
        import json
        return json.dumps(self.model_dump(), default=str)

    def dict(self, *, exclude_none: bool = False) -> dict:
        """Alias for model_dump with optional None filtering."""
        d = self.model_dump()
        if exclude_none:
            return {k: v for k, v in d.items() if v is not None}
        return d


class _MissingSentinel:
    """Sentinel for missing field values."""

_MISSING = _MissingSentinel()


def _compile_schema_in_zig(cls: type) -> None:
    """Trigger Zig-side schema compilation for a Model subclass.

    Called from __init_subclass__. When the C extension is loaded, this
    calls _snek.register_model(cls) which runs SchemaBuilder.inspectAnnotations
    to build and cache a SchemaNode tree for fused decode+validate.
    """
    # Stub: import _snek and call _snek.register_model(cls)
    # Silently no-op if the C extension isn't loaded yet (pure-Python mode).
    ...


class Field:
    """Field metadata for snek.Model fields.

    Provides default values, aliases, exclusion flags, and descriptions
    for OpenAPI doc generation.
    """

    def __init__(
        self,
        *,
        default: Any = _MISSING,
        alias: str | None = None,
        exclude: bool = False,
        description: str | None = None,
    ) -> None:
        self.default = default
        self.alias = alias
        self.exclude = exclude
        self.description = description


# ── Type-to-JSON-Schema mapping ─────────────────────────────────────

_SIMPLE_MAP: dict[type, dict] = {
    str: {"type": "string"},
    int: {"type": "integer"},
    float: {"type": "number"},
    bool: {"type": "boolean"},
    datetime: {"type": "string", "format": "date-time"},
}


def _type_to_schema(hint: Any) -> dict:
    """Convert a Python type annotation to a JSON Schema fragment."""
    import typing

    origin = getattr(hint, "__origin__", None)

    # Annotated[T, ...metadata] — unwrap and apply constraints
    if origin is typing.Annotated:
        args = hint.__args__
        base_schema = _type_to_schema(args[0])
        for meta in args[1:]:
            base_schema.update(_constraint_to_schema(meta))
        return base_schema

    # Optional / Union with None
    if origin is typing.Union:
        args = [a for a in hint.__args__ if a is not type(None)]
        if len(args) == 1:
            schema = _type_to_schema(args[0])
            schema["nullable"] = True
            return schema
        return {"oneOf": [_type_to_schema(a) for a in args]}

    # list[T]
    if origin is list:
        item_type = hint.__args__[0] if hint.__args__ else Any
        return {"type": "array", "items": _type_to_schema(item_type)}

    # dict[K, V]
    if origin is dict:
        return {"type": "object"}

    # Simple types
    if hint in _SIMPLE_MAP:
        return dict(_SIMPLE_MAP[hint])

    # Model references
    if isinstance(hint, type) and issubclass(hint, Model):
        return {"$ref": f"#/components/schemas/{hint.__name__}"}

    return {}


def _constraint_to_schema(meta: Any) -> dict:
    """Map a snek constraint annotation to JSON Schema keywords."""
    cls_name = type(meta).__name__
    mapping: dict[str, str] = {
        "Gt": "exclusiveMinimum",
        "Ge": "minimum",
        "Lt": "exclusiveMaximum",
        "Le": "maximum",
        "MinLen": "minLength",
        "MaxLen": "maxLength",
        "Pattern": "pattern",
        "Email": "format",
    }
    key = mapping.get(cls_name)
    if key is None:
        return {}
    if cls_name == "Email":
        return {"format": "email"}
    # Constraint objects store their value as the first init arg
    value = getattr(meta, "value", getattr(meta, "v", None))
    if value is None and hasattr(meta, "__args__"):
        value = meta.__args__[0]
    if value is not None:
        return {key: value}
    return {}
