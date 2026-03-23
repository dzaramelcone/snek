"""snek hello world — @app.get style decorators."""

from snek import App

app = App()


@app.get("/")
async def hello(request):
    return {"message": "hello from snek python"}


@app.get("/health")
async def health(request):
    return {"status": "ok"}


@app.get("/greet/{name}")
async def greet(request):
    name = request["params"]["name"]
    return {"message": f"hello {name}"}


if __name__ == "__main__":
    app.run()
