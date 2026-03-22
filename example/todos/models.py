"""Todo app models — snek.Model definitions for request/response shapes."""

from __future__ import annotations

from datetime import datetime
from typing import Annotated

import snek
from snek import Model


# ── Constraints ──────────────────────────────────────────────────────

PositiveInt = Annotated[int, snek.Gt(0)]
Priority = Annotated[int, snek.Ge(1), snek.Le(5)]
Email = Annotated[str, snek.Email()]
ShortStr = Annotated[str, snek.MinLen(1), snek.MaxLen(200)]
Tag = Annotated[str, snek.MinLen(1), snek.MaxLen(50)]


# ── Users ────────────────────────────────────────────────────────────

class UserCreate(Model):
    email: Email
    name: ShortStr
    password: Annotated[str, snek.MinLen(8)]


class UserResponse(Model):
    id: int
    email: str
    name: str
    created_at: datetime


# ── Todos ────────────────────────────────────────────────────────────

class TodoCreate(Model):
    title: Annotated[str, snek.MinLen(1), snek.MaxLen(200)]
    description: str | None = None
    priority: Annotated[int, snek.Ge(1), snek.Le(5)] = 3
    due_date: datetime | None = None
    tags: list[Tag] = []


class TodoUpdate(Model):
    title: Annotated[str, snek.MinLen(1), snek.MaxLen(200)] | None = None
    description: str | None = None
    done: bool | None = None
    priority: Annotated[int, snek.Ge(1), snek.Le(5)] | None = None
    due_date: datetime | None = None
    tags: list[Tag] | None = None


class TodoResponse(Model):
    id: int
    user_id: int
    title: str
    description: str | None
    done: bool
    priority: int
    due_date: datetime | None
    tags: list[str]
    created_at: datetime
    updated_at: datetime


class TodoList(Model):
    items: list[TodoResponse]
    total: int


# ── Nested example ───────────────────────────────────────────────────

class TodoWithUser(Model):
    todo: TodoResponse
    user: UserResponse
