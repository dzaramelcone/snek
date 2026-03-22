"""Single DB query benchmark."""

import snek
from pydantic import BaseModel

app = snek.App()


class Row(BaseModel):
    id: int
    name: str


@app.route("GET", "/")
async def single_query() -> Row:
    row = await app.db.fetch_one("SELECT id, name FROM bench_table LIMIT 1")
    return row
