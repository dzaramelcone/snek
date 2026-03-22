"""Large JSON payload benchmark — 100 nested items."""

import snek
from pydantic import BaseModel

app = snek.App()


class Address(BaseModel):
    street: str
    city: str
    zip: str


class Item(BaseModel):
    id: int
    name: str
    email: str
    active: bool
    score: float
    address: Address
    tags: list[str]


ITEMS: list[Item] = [
    Item(
        id=i,
        name=f"user-{i}",
        email=f"user-{i}@example.com",
        active=i % 2 == 0,
        score=i * 1.1,
        address=Address(street=f"{i} Main St", city="Testville", zip=f"{10000 + i}"),
        tags=[f"tag-{i}", f"group-{i % 10}"],
    )
    for i in range(100)
]


class ItemList(BaseModel):
    items: list[Item]
    total: int


@app.route("GET", "/")
async def list_items() -> ItemList:
    return ItemList(items=ITEMS, total=len(ITEMS))
