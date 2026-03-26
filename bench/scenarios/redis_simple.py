"""Simple Redis GET/SET benchmark."""

import snek

app = snek.App()


@app.get("/")
async def handler():
    val = await app.redis.get("bench:key")
    if val is None:
        await app.redis.set("bench:key", "hello")
        val = b"hello"
    return {"cached": val.decode() if isinstance(val, bytes) else str(val)}


if __name__ == "__main__":
    app.run(module_ref="redis_simple:app")
