"""Minimal snek app — Phase 9 milestone target.

No database, no Redis, no middleware. Just routing and JSON responses.
"""

import snek

app = snek.App()


@app.route("GET", "/")
async def hello():
    return {"message": "hello from snek"}


@app.route("GET", "/users/{id}")
async def get_user(id: int):
    return {"id": id, "name": "snek user"}
