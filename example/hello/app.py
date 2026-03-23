"""snek hello world — async handlers with redis."""

from snek import App

app = App()


@app.get("/")
async def hello():
    return {"message": "hello from snek"}


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/greet/{name}")
async def greet(name: str):
    return {"message": f"hello {name}"}


@app.get("/redis-ping")
async def redis_ping():
    result = await app.redis.ping()
    return {"redis": result}


@app.get("/redis-set/{key}/{value}")
async def redis_set(key: str, value: str):
    result = await app.redis.set(key, value)
    return {"set": result}


@app.get("/redis-get/{key}")
async def redis_get(key: str):
    val = await app.redis.get(key)
    return {"key": key, "value": val.decode() if isinstance(val, bytes) else val}


if __name__ == "__main__":
    app.run()
