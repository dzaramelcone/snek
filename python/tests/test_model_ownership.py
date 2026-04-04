from __future__ import annotations

import asyncio
import queue
import threading

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


class Idea(Model):
    id: str
    description: str


def make_idea() -> Idea:
    return Idea._snek_from_row(FakeRow({"id": "idea-1", "description": "hello"}))


async def pass_through_async(model: Idea) -> Idea:
    await asyncio.sleep(0)
    return model


async def mutate_in_async(model: Idea) -> Idea:
    await asyncio.sleep(0)
    model.description = "changed-in-helper"
    return model


def mutate_in_thread(model: Idea) -> None:
    model.description = "changed-in-thread"


def test_pg_backed_model_stays_clean_across_async_cache_and_thread_handoffs() -> None:
    model = make_idea()

    assert model.raw("description").tobytes() == b"hello"

    passed = asyncio.run(pass_through_async(model))
    assert passed is model
    assert passed.raw("description").tobytes() == b"hello"

    cache: dict[str, Idea] = {}
    cache["idea"] = model
    cached = cache["idea"]
    assert cached is model
    assert cached.raw("description").tobytes() == b"hello"

    q: queue.Queue[Idea] = queue.Queue()
    q.put(model)
    threaded = q.get_nowait()
    assert threaded is model
    assert threaded.raw("description").tobytes() == b"hello"


def test_pg_backed_model_mutation_marks_root_dirty_across_async_and_thread_handoffs() -> None:
    async_model = asyncio.run(mutate_in_async(make_idea()))
    assert async_model.model_dump() == {
        "id": "idea-1",
        "description": "changed-in-helper",
    }
    try:
        async_model.raw("description")
    except RuntimeError as exc:
        assert "mutated" in str(exc)
    else:
        raise AssertionError("expected dirty model raw() to fail after async mutation")

    thread_model = make_idea()
    worker = threading.Thread(target=mutate_in_thread, args=(thread_model,))
    worker.start()
    worker.join()

    assert thread_model.model_dump() == {
        "id": "idea-1",
        "description": "changed-in-thread",
    }
    try:
        thread_model.raw("description")
    except RuntimeError as exc:
        assert "mutated" in str(exc)
    else:
        raise AssertionError("expected dirty model raw() to fail after thread mutation")
