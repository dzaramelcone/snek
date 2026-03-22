"""Middleware overhead benchmark — 5 layers."""

import snek
from pydantic import BaseModel

app = snek.App()


def make_middleware(name: str):
    @app.middleware
    async def mw(req: snek.Request, call_next):
        req.state[name] = True
        return await call_next(req)
    return mw


make_middleware("layer_1")
make_middleware("layer_2")
make_middleware("layer_3")
make_middleware("layer_4")
make_middleware("layer_5")


class OkResponse(BaseModel):
    ok: bool = True


@app.route("GET", "/")
async def handler() -> OkResponse:
    return OkResponse()
