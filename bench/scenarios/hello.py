"""Minimal JSON response — baseline benchmark."""

import snek
from pydantic import BaseModel

app = snek.App()


class HelloResponse(BaseModel):
    message: str = "hello"


@app.route("GET", "/")
async def hello() -> HelloResponse:
    return HelloResponse()
