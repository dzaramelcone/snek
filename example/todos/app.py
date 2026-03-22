"""Todo app — a snek proof-of-concept showing the full API surface."""

import json
from typing import Annotated

import snek
from snek import Body, Path, Query
from snek.docs import setup_docs

from middleware import (
    auth_middleware,
    logging_middleware,
    oauth_middleware,
    session_middleware,
    timing_middleware,
)
from models import (
    TodoCreate,
    TodoList,
    TodoResponse,
    TodoUpdate,
    UserCreate,
    UserResponse,
)

app = snek.App()

# ── Docs (Swagger UI at /docs, ReDoc at /redoc, spec at /openapi.json)
setup_docs(app, title="Todos API", version="1.0.0", description="A snek proof-of-concept todo app")

# ── Middleware (order matters: first registered = outermost) ──────────

logging_middleware(app)
timing_middleware(app)
session_middleware(app)
oauth_middleware(app)
auth_middleware(app)


# ── Injectable dependencies (shared DI graph for middleware + handlers)

DbSession = Annotated[snek.Transaction, snek.Inject]
CurrentUser = Annotated[dict, snek.Inject]


@app.injectable
async def db_session() -> DbSession:
    async with app.db.transaction() as tx:
        yield tx


@app.injectable
async def current_user(req: snek.Request) -> CurrentUser:
    return req.user


# ── Lifecycle ────────────────────────────────────────────────────────


@app.on_startup
async def startup():
    app.log.info("todos app starting")


@app.on_shutdown
async def shutdown():
    app.log.info("todos app shutting down")


# ── Health ───────────────────────────────────────────────────────────


@app.route("GET", "/health", tags=["system"])
async def health():
    """Check service health."""
    return {"status": "ok"}


# ── Session info ─────────────────────────────────────────────────────


@app.route("GET", "/me")
async def me(req: snek.Request):
    user = await req.session.get("user")
    if not user:
        raise snek.Unauthorized("not logged in")
    return user


# ── Auth ─────────────────────────────────────────────────────────────


@app.route("POST", "/signup", tags=["auth"], summary="Register a new user")
async def signup(body: Body[UserCreate], db: DbSession) -> UserResponse:
    hashed = snek.hash_password(body.password)
    row = await db.fetch_one(
        "INSERT INTO users (email, name, password) VALUES ($1, $2, $3) RETURNING *",
        body.email,
        body.name,
        hashed,
    )
    return row


@app.route("POST", "/login", tags=["auth"], summary="Authenticate and get a JWT")
async def login(req: snek.Request, body: Body[UserCreate], db: DbSession) -> dict:
    user = await db.fetch_one(
        "SELECT * FROM users WHERE email = $1",
        body.email,
    )
    if not user or not snek.verify_password(body.password, user["password"]):
        raise snek.Unauthorized("invalid credentials")

    token = await app.jwt.encode({"sub": user["id"], "email": user["email"]})
    await req.session.set("user", {"id": user["id"], "email": user["email"], "name": user["name"]})
    return {"token": token}


# ── Todos CRUD ───────────────────────────────────────────────────────


@app.route("GET", "/todos", tags=["todos"], summary="List todos with filtering")
async def list_todos(
    user: CurrentUser,
    done: Query[bool | None] = None,
    limit: Query[int] = 50,
    offset: Query[int] = 0,
) -> TodoList:
    cache_key = f"todos:{user['sub']}:{done}:{limit}:{offset}"
    cached = await app.redis.get(cache_key)
    if cached:
        return json.loads(cached)

    where = "WHERE user_id = $1"
    params: list = [user["sub"]]

    if done is not None:
        where += " AND done = $2"
        params.append(done)

    rows, total = await app.gather(
        app.db.fetch(
            f"SELECT * FROM todos {where} ORDER BY created_at DESC LIMIT ${len(params) + 1} OFFSET ${len(params) + 2}",
            *params,
            limit,
            offset,
        ),
        app.db.fetch_one(
            f"SELECT count(*) AS total FROM todos {where}",
            *params,
        ),
    )

    result = TodoList(items=rows, total=total["total"])
    await app.redis.setex(cache_key, 30, result.json())
    return result


@app.route("GET", "/todos/{todo_id}", tags=["todos"])
async def get_todo(user: CurrentUser, todo_id: Path[int]) -> TodoResponse:
    """Fetch a single todo by ID."""
    row = await app.db.fetch_one(
        "SELECT * FROM todos WHERE id = $1 AND user_id = $2",
        todo_id,
        user["sub"],
    )
    if not row:
        raise snek.NotFound("todo not found")
    return row


@app.route("POST", "/todos", tags=["todos"], summary="Create a new todo")
async def create_todo(body: Body[TodoCreate], user: CurrentUser, db: DbSession) -> TodoResponse:
    # db is an injected transaction — auto-commits on success, auto-rollbacks on error
    row = await db.fetch_one(
        "INSERT INTO todos (user_id, title, description, priority, due_date, tags) "
        "VALUES ($1, $2, $3, $4, $5, $6) RETURNING *",
        user["sub"],
        body.title,
        body.description,
        body.priority,
        body.due_date,
        body.tags,
    )
    await app.redis.publish("todos:live", json.dumps({"event": "created", "todo": row}))
    return snek.response(row, status=201)


@app.route("PATCH", "/todos/{todo_id}", tags=["todos"], summary="Update a todo")
async def update_todo(
    user: CurrentUser,
    todo_id: Path[int],
    body: Body[TodoUpdate],
    db: DbSession,
) -> TodoResponse:
    fields = body.dict(exclude_none=True)
    if not fields:
        raise snek.BadRequest("nothing to update")

    sets = ", ".join(f"{k} = ${i + 2}" for i, k in enumerate(fields))
    values = list(fields.values())

    row = await db.fetch_one(
        f"UPDATE todos SET {sets}, updated_at = now() WHERE id = $1 AND user_id = ${len(values) + 2} RETURNING *",
        todo_id,
        *values,
        user["sub"],
    )
    if not row:
        raise snek.NotFound("todo not found")

    await app.redis.publish("todos:live", json.dumps({"event": "updated", "todo": row}))
    return row


@app.route("DELETE", "/todos/{todo_id}", tags=["todos"], summary="Delete a todo")
async def delete_todo(user: CurrentUser, todo_id: Path[int], db: DbSession):
    row = await db.fetch_one(
        "DELETE FROM todos WHERE id = $1 AND user_id = $2 RETURNING id",
        todo_id,
        user["sub"],
    )
    if not row:
        raise snek.NotFound("todo not found")

    await app.redis.publish(
        "todos:live", json.dumps({"event": "deleted", "id": row["id"]})
    )
    return snek.response(None, status=204)


# ── WebSocket: live todo updates ─────────────────────────────────────


@app.websocket("/ws/todos")
async def todo_ws(ws: snek.WebSocket):
    sub = await app.redis.subscribe("todos:live")
    async for message in sub:
        await ws.send(message)


# ── SSE: todo feed ───────────────────────────────────────────────────


@app.route("GET", "/todos/feed")
async def todo_feed():
    async def generate():
        sub = await app.redis.subscribe("todos:live")
        async for message in sub:
            yield f"data: {message}\n\n"

    return snek.stream(generate(), content_type="text/event-stream")
