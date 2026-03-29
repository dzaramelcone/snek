"""HTTP benchmark: ten nested awaits before responding."""

import snek
from bench.scenarios.eventloop_shared import async_10_payload

app = snek.App()

@app.get("/")
async def handler():
    return await async_10_payload()
