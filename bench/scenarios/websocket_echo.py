"""WebSocket echo server for throughput benchmarking."""

import snek

app = snek.App()


@app.websocket("/ws")
async def echo(ws: snek.WebSocket):
    async for message in ws:
        await ws.send(message)
