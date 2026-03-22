"""Redis cache with DB fallback benchmark."""

import json

import snek
from pydantic import BaseModel

app = snek.App()


class CachedRow(BaseModel):
    id: int
    value: str


@app.route("GET", "/")
async def cached_query() -> CachedRow:
    cached = await app.redis.get("bench:row")
    if cached:
        return CachedRow.model_validate_json(cached)
    row = await app.db.fetch_one("SELECT id, value FROM bench_table LIMIT 1")
    result = CachedRow(id=row["id"], value=row["value"])
    await app.redis.setex("bench:row", 10, result.model_dump_json())
    return result
