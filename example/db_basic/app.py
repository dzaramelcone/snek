"""Basic database example — Phase 13 milestone target.

Minimal app with one DB query. No Redis, no middleware, no auth.
"""

import snek

app = snek.App()


@app.route("GET", "/")
async def hello():
    return {"message": "hello from snek"}


@app.route("GET", "/users/{id}")
async def get_user(id: int):
    user = await app.db.fetch_one("SELECT * FROM users WHERE id = $1", id)
    if not user:
        raise snek.NotFound("user not found")
    return user


@app.route("GET", "/users")
async def list_users():
    rows = await app.db.fetch("SELECT id, name, email FROM users ORDER BY id")
    return {"users": rows}
