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


if __name__ == "__main__":
    app.run()
