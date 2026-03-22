"""Parallel DB queries benchmark — 3 concurrent queries via app.gather()."""

import snek
from pydantic import BaseModel

app = snek.App()


class MultiResult(BaseModel):
    users: int
    orders: int
    products: int


@app.route("GET", "/")
async def multi_query() -> MultiResult:
    users, orders, products = await app.gather(
        app.db.fetch_one("SELECT count(*) AS n FROM users"),
        app.db.fetch_one("SELECT count(*) AS n FROM orders"),
        app.db.fetch_one("SELECT count(*) AS n FROM products"),
    )
    return MultiResult(
        users=users["n"],
        orders=orders["n"],
        products=products["n"],
    )
