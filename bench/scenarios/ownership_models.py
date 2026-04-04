from __future__ import annotations

import os
import sys
import types
from pathlib import Path
from tempfile import TemporaryDirectory

import ownership_helpers as helpers
import snek
from snek.codegen import emit_models, emit_queries, parse_queries, parse_schemas


SCHEMA_SQL = """
CREATE TABLE ideas (
    id          TEXT PRIMARY KEY,
    description TEXT NOT NULL
);

CREATE TABLE theses (
    id       TEXT PRIMARY KEY,
    idea_id  TEXT NOT NULL REFERENCES ideas(id),
    summary  TEXT NOT NULL
);
"""


QUERY_SQL = """
-- name: GetIdeaLite :one
SELECT id, description
FROM ideas
WHERE id = {id};

-- name: GetIdeaWithThesisLite :one
SELECT idea.id, idea.description, thesis.id, thesis.summary
FROM ideas idea
JOIN theses thesis ON thesis.idea_id = idea.id
WHERE idea.id = {id};
"""


def _load_codegen():
    with TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        schema_path = tmp / "schema.sql"
        query_path = tmp / "queries.sql"
        schema_path.write_text(SCHEMA_SQL)
        query_path.write_text(QUERY_SQL)

        tables = parse_schemas([schema_path])
        queries = parse_queries(query_path, tables)
        models_src = emit_models(tables, queries)
        db_src = emit_queries(queries, tables, "ownership_generated_models")

    models_mod = types.ModuleType("ownership_generated_models")
    models_mod.__file__ = "<ownership_generated_models>"
    sys.modules[models_mod.__name__] = models_mod
    exec(models_src, models_mod.__dict__)

    db_mod = types.ModuleType("ownership_generated_db")
    db_mod.__file__ = "<ownership_generated_db>"
    sys.modules[db_mod.__name__] = db_mod
    exec(db_src, db_mod.__dict__)
    return models_mod, db_mod


_models, _db_mod = _load_codegen()
db = _db_mod.Db()
app = snek.App()
app.db = db


@app.get("/reset")
async def reset():
    helpers.reset()
    return {"ok": True}


@app.post("/request/inspect/{slug}")
async def request_inspect(req):
    return helpers._request_summary(req)


@app.post("/request/copy-mutate/{slug}")
async def request_copy_mutate(req):
    original_body = None if req.body is None else req.body.decode("utf-8")
    body_copy = None
    body_bytearray = None
    if req.body is not None:
        body_copy = bytes(req.body)
        body_bytearray = bytearray(req.body)
        if body_bytearray:
            body_bytearray[0] = ord("X")

    headers_copy = dict(req.headers)
    if headers_copy:
        first_key = next(iter(headers_copy))
        headers_copy[first_key] = headers_copy[first_key] + "-copy"

    params_copy = dict(req.params)
    if params_copy:
        first_key = next(iter(params_copy))
        params_copy[first_key] = params_copy[first_key] + "-copy"

    return {
        "original": helpers._request_summary(req),
        "body_copy": None if body_copy is None else body_copy.decode("utf-8"),
        "body_bytearray": None if body_bytearray is None else body_bytearray.decode("utf-8"),
        "headers_copy": headers_copy,
        "params_copy": params_copy,
    }


@app.post("/request/await-inspect/{slug}")
async def request_await_inspect(req):
    return await helpers.inspect_request(req)


@app.post("/request/mutate-fail/{slug}")
async def request_mutate_fail(req):
    errors: dict[str, str] = {}
    try:
        req.method[0] = "P"
    except Exception as exc:  # noqa: BLE001
        errors["method"] = f"{type(exc).__name__}: {exc}"
    try:
        req.headers["x-test-header"] = "changed"
    except Exception as exc:  # noqa: BLE001
        errors["headers"] = f"{type(exc).__name__}: {exc}"
    try:
        req.params["slug"] = "changed"
    except Exception as exc:  # noqa: BLE001
        errors["params"] = f"{type(exc).__name__}: {exc}"
    return errors


@app.get("/clean")
async def clean():
    return await db.get_idea_lite(id="idea-1")


@app.get("/mutate")
async def mutate():
    model = await db.get_idea_lite(id="idea-1")
    model.description = "changed-in-route"
    return model


@app.get("/await-pass")
async def await_pass():
    model = await db.get_idea_lite(id="idea-1")
    return await helpers.passthrough(model)


@app.get("/await-mutate")
async def await_mutate():
    model = await db.get_idea_lite(id="idea-1")
    return await helpers.mutate_model(model)


@app.get("/nested")
async def nested():
    joined = await db.get_idea_with_thesis_lite(id="idea-1")
    return await helpers.extract_idea(joined)


@app.get("/cache/store")
async def cache_store():
    helpers.cache_value(await db.get_idea_lite(id="idea-1"))
    return {"stored": True}


@app.get("/cache/get")
async def cache_get():
    value = helpers.get_cached_value()
    return value if value is not None else {"ready": False}


@app.get("/view/store")
async def view_store():
    helpers.cache_view((await db.get_idea_lite(id="idea-1")).raw("description"))
    return {"stored": True}


@app.get("/view/get")
async def view_get():
    view = helpers.get_cached_view()
    return {"ready": view is not None, "description": None if view is None else view.tobytes().decode()}


@app.get("/dirty-raw")
async def dirty_raw():
    model = await db.get_idea_lite(id="idea-1")
    model.description = "changed-before-raw"
    try:
        model.raw("description")
    except RuntimeError as exc:
        return {"error": str(exc)}
    return {"error": None}


@app.get("/thread/store")
async def thread_store():
    helpers.spawn_store_value_later(await db.get_idea_lite(id="idea-1"))
    return {"queued": True}


@app.get("/thread/get")
async def thread_get():
    value = helpers.get_thread_value()
    return value if value is not None else {"ready": False}


@app.get("/thread/mutate/store")
async def thread_mutate_store():
    helpers.spawn_mutate_and_store_later(await db.get_idea_lite(id="idea-1"))
    return {"queued": True}


@app.get("/thread/mutate/get")
async def thread_mutate_get():
    value = helpers.get_thread_mutated_value()
    return value if value is not None else {"ready": False}


@app.get("/thread/view/store")
async def thread_view_store():
    helpers.spawn_store_view_later((await db.get_idea_lite(id="idea-1")).raw("description"))
    return {"queued": True}


@app.get("/thread/view/get")
async def thread_view_get():
    view = helpers.get_thread_view()
    return {"ready": view is not None, "description": None if view is None else view.tobytes().decode()}


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "18090"))
    app.run(host="0.0.0.0", port=port, threads=1, module_ref="ownership_models:app")
