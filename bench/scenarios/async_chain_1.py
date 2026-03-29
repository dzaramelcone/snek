"""HTTP benchmark: one nested await before responding."""

import snek
from bench.scenarios.eventloop_shared import async_1_payload

app = snek.App()

@app.get("/")
async def handler():
    return await async_1_payload()
