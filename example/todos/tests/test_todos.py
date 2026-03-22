"""Integration tests for the todo app."""

import pytest

from snek.testing import TestClient

from app import app


@pytest.fixture
async def client():
    return TestClient(app)


@pytest.fixture
async def auth_client(client: TestClient):
    await client.post("/signup", json={
        "email": "test@example.com",
        "name": "Test User",
        "password": "securepassword123",
    })
    resp = await client.post("/login", json={
        "email": "test@example.com",
        "password": "securepassword123",
    })
    client.headers["Authorization"] = f"Bearer {(await resp.json())['token']}"
    return client


# ── Health ───────────────────────────────────────────────────────────

@pytest.mark.anyio
async def test_health(client: TestClient):
    resp = await client.get("/health")
    assert resp.status == 200
    assert await resp.json() == {"status": "ok"}


# ── Auth ─────────────────────────────────────────────────────────────

@pytest.mark.anyio
async def test_signup(client: TestClient):
    resp = await client.post("/signup", json={
        "email": "new@example.com",
        "name": "New User",
        "password": "securepassword123",
    })
    assert resp.status == 200
    data = await resp.json()
    assert data["email"] == "new@example.com"
    assert "password" not in data


@pytest.mark.anyio
async def test_login_wrong_password(client: TestClient):
    await client.post("/signup", json={
        "email": "wrong@example.com",
        "name": "Wrong",
        "password": "securepassword123",
    })
    resp = await client.post("/login", json={
        "email": "wrong@example.com",
        "password": "badpassword",
    })
    assert resp.status == 401


@pytest.mark.anyio
async def test_unauthenticated_request(client: TestClient):
    resp = await client.get("/todos")
    assert resp.status == 401


# ── CRUD ─────────────────────────────────────────────────────────────

@pytest.mark.anyio
async def test_create_todo(auth_client: TestClient):
    resp = await auth_client.post("/todos", json={
        "title": "Buy milk",
        "priority": 1,
    })
    assert resp.status == 201
    data = await resp.json()
    assert data["title"] == "Buy milk"
    assert data["done"] is False
    assert data["priority"] == 1


@pytest.mark.anyio
async def test_list_todos(auth_client: TestClient):
    await auth_client.post("/todos", json={"title": "First"})
    await auth_client.post("/todos", json={"title": "Second"})

    resp = await auth_client.get("/todos")
    assert resp.status == 200
    data = await resp.json()
    assert data["total"] >= 2
    assert len(data["items"]) >= 2


@pytest.mark.anyio
async def test_get_todo(auth_client: TestClient):
    create_resp = await auth_client.post("/todos", json={"title": "Fetch me"})
    todo_id = (await create_resp.json())["id"]

    resp = await auth_client.get(f"/todos/{todo_id}")
    assert resp.status == 200
    assert (await resp.json())["title"] == "Fetch me"


@pytest.mark.anyio
async def test_update_todo(auth_client: TestClient):
    create_resp = await auth_client.post("/todos", json={"title": "Update me"})
    todo_id = (await create_resp.json())["id"]

    resp = await auth_client.patch(f"/todos/{todo_id}", json={"done": True})
    assert resp.status == 200
    assert (await resp.json())["done"] is True


@pytest.mark.anyio
async def test_delete_todo(auth_client: TestClient):
    create_resp = await auth_client.post("/todos", json={"title": "Delete me"})
    todo_id = (await create_resp.json())["id"]

    resp = await auth_client.delete(f"/todos/{todo_id}")
    assert resp.status == 204

    resp = await auth_client.get(f"/todos/{todo_id}")
    assert resp.status == 404


# ── Validation ───────────────────────────────────────────────────────

@pytest.mark.anyio
async def test_create_todo_empty_title(auth_client: TestClient):
    resp = await auth_client.post("/todos", json={"title": ""})
    assert resp.status == 422


@pytest.mark.anyio
async def test_create_todo_bad_priority(auth_client: TestClient):
    resp = await auth_client.post("/todos", json={"title": "X", "priority": 99})
    assert resp.status == 422


@pytest.mark.anyio
async def test_update_todo_empty_body(auth_client: TestClient):
    create_resp = await auth_client.post("/todos", json={"title": "Noop"})
    todo_id = (await create_resp.json())["id"]

    resp = await auth_client.patch(f"/todos/{todo_id}", json={})
    assert resp.status == 400
