import snek
from bench.scenarios.eventloop_shared import async_0_payload

app = snek.App()

@app.get("/")
async def hello():
    return await async_0_payload()

if __name__ == "__main__":
    app.run(module_ref="hello_minimal:app")
