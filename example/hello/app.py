"""snek hello world — @app.get style decorators."""

from snek import App

app = App()


@app.get("/")
async def hello():
    return {"message": "hello from snek python"}


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/greet/{name}")
async def greet(name: str):
    return {"message": f"hello {name}"}


@app.get("/redis-ping")
async def redis_ping():
    result = app.redis("PING")
    return {"redis": result}


@app.get("/redis-set/{key}/{value}")
async def redis_set(key: str, value: str):
    result = app.redis("SET", key, value)
    return {"set": result}


@app.get("/redis-get/{key}")
async def redis_get(key: str):
    val = app.redis("GET", key)
    return {"key": key, "value": val.decode() if isinstance(val, bytes) else val}


if __name__ == "__main__":
    app.run()
