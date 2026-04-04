from __future__ import annotations

from datetime import datetime

from snek.models import Model


class FakeRow:
    def __init__(self, values: dict[str, str]) -> None:
        self._values = values

    def __getattr__(self, name: str) -> str:
        try:
            return self._values[name]
        except KeyError as exc:
            raise AttributeError(name) from exc

    def raw(self, name: str) -> memoryview:
        return memoryview(self._values[name].encode())


class FlatRow:
    def __init__(self, field_names: tuple[str, ...], values: tuple[str | None, ...]) -> None:
        self._field_names = field_names
        self._values = values

    def __getattr__(self, name: str) -> str | None:
        for field_name, value in zip(self._field_names, self._values, strict=True):
            if field_name == name:
                return value
        raise AttributeError(name)

    def raw(self, name: str) -> memoryview:
        value = getattr(self, name)
        if value is None:
            raise AttributeError(name)
        return memoryview(value.encode())

    def subrow(
        self,
        field_names: tuple[str, ...],
        field_indexes: tuple[int, ...],
        nullable: bool = False,
    ) -> "FlatRow | None":
        values = tuple(self._values[index] for index in field_indexes)
        if nullable and all(value is None for value in values):
            return None
        return FlatRow(field_names, values)


class User(Model):
    id: int
    active: bool
    tags: list[str]
    created_at: datetime


class Idea(Model):
    id: int
    name: str


class Thesis(Model):
    id: int
    title: str


class JoinedRow(Model):
    __snek_nested__ = {
        "idea": (Idea, False, ("id", "name"), (0, 1)),
        "thesis": (Thesis, True, ("id", "title"), (2, 3)),
    }

    idea: Idea
    thesis: Thesis | None
    thesis_count: int


def test_model_init_uses_declared_fields_only() -> None:
    user = User(id=1, active=True, tags=["a"], created_at=datetime(2024, 1, 2, 3, 4, 5))
    assert user.id == 1
    assert user.active is True
    assert user.tags == ["a"]


def test_pg_backed_model_decodes_lazily() -> None:
    row = FakeRow(
        {
            "id": "42",
            "active": "t",
            "tags": '{"alpha","beta"}',
            "created_at": "2024-01-02T03:04:05",
        }
    )

    user = User._snek_from_row(row)

    assert user.id == 42
    assert user.active is True
    assert user.tags == ["alpha", "beta"]
    assert user.created_at == datetime(2024, 1, 2, 3, 4, 5)
    assert user.raw("id").tobytes() == b"42"
    assert user.model_dump() == {
        "id": 42,
        "active": True,
        "tags": ["alpha", "beta"],
        "created_at": datetime(2024, 1, 2, 3, 4, 5),
    }


def test_pg_backed_nested_models_decode_lazily() -> None:
    row = FlatRow(
        ("id", "name", "id", "title", "thesis_count"),
        ("1", "idea", "2", "thesis", "7"),
    )

    joined = JoinedRow._snek_from_row(row)

    assert joined.idea.id == 1
    assert joined.idea.name == "idea"
    assert joined.thesis is not None
    assert joined.thesis.id == 2
    assert joined.thesis.title == "thesis"
    assert joined.thesis_count == 7
    assert joined.raw("thesis_count").tobytes() == b"7"
    assert joined.model_dump() == {
        "idea": {"id": 1, "name": "idea"},
        "thesis": {"id": 2, "title": "thesis"},
        "thesis_count": 7,
    }


def test_pg_backed_left_join_models_can_be_none() -> None:
    row = FlatRow(
        ("id", "name", "id", "title", "thesis_count"),
        ("1", "idea", None, None, "0"),
    )

    joined = JoinedRow._snek_from_row(row)

    assert joined.thesis is None


def test_pg_backed_model_assignment_marks_it_dirty() -> None:
    row = FakeRow(
        {
            "id": "42",
            "active": "t",
            "tags": '{"alpha","beta"}',
            "created_at": "2024-01-02T03:04:05",
        }
    )

    user = User._snek_from_row(row)
    assert user.raw("id").tobytes() == b"42"

    user.id = 99

    assert user.model_dump()["id"] == 99


def test_pg_backed_model_raw_is_unavailable_after_mutation() -> None:
    row = FakeRow(
        {
            "id": "42",
            "active": "t",
            "tags": '{"alpha","beta"}',
            "created_at": "2024-01-02T03:04:05",
        }
    )

    user = User._snek_from_row(row)
    assert user.raw("id").tobytes() == b"42"

    user.id = 99

    try:
        user.raw("id")
    except RuntimeError as exc:
        assert "mutated" in str(exc)
    else:
        raise AssertionError("expected raw() to reject dirty models")


def test_pg_backed_list_mutation_marks_it_dirty() -> None:
    row = FakeRow(
        {
            "id": "42",
            "active": "t",
            "tags": '{"alpha","beta"}',
            "created_at": "2024-01-02T03:04:05",
        }
    )

    user = User._snek_from_row(row)
    tags = user.tags

    assert user.raw("id").tobytes() == b"42"

    tags.append("gamma")

    assert user.model_dump()["tags"] == ["alpha", "beta", "gamma"]
    try:
        user.raw("id")
    except RuntimeError as exc:
        assert "mutated" in str(exc)
    else:
        raise AssertionError("expected raw() to reject mutated list-backed models")


def test_nested_child_mutation_marks_parent_dirty() -> None:
    row = FlatRow(
        ("id", "name", "id", "title", "thesis_count"),
        ("1", "idea", "2", "thesis", "7"),
    )

    joined = JoinedRow._snek_from_row(row)
    idea = joined.idea

    assert joined.raw("thesis_count").tobytes() == b"7"

    idea.name = "changed"

    assert joined.model_dump()["idea"] == {"id": 1, "name": "changed"}
    try:
        joined.raw("thesis_count")
    except RuntimeError as exc:
        assert "mutated" in str(exc)
    else:
        raise AssertionError("expected raw() to reject mutated nested models")
