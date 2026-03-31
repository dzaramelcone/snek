"""Single parameterized PG query benchmark without schema dependencies."""

import snek

app = snek.App()


@app.get("/")
async def handler():
    row = await app.db.fetch_one("SELECT $1::int AS id, 'hello'::text AS name", "1")
    return row


if __name__ == "__main__":
    app.run(module_ref="db_param_one:app")
