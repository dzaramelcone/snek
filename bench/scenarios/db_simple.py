"""Simple Postgres query benchmark."""

import snek

app = snek.App()


@app.get("/")
async def handler():
    row = await app.db.fetch_one("SELECT id, name FROM bench WHERE id = 1")
    return row


if __name__ == "__main__":
    app.run(module_ref="db_simple:app")
