"""FastAPI benchmark control — mirrors snek's example app."""

from fastapi import FastAPI, Request, Response
from starlette.middleware.base import BaseHTTPMiddleware

app = FastAPI()


class ConnectionCloseMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response: Response = await call_next(request)
        response.headers["connection"] = "close"
        return response


app.add_middleware(ConnectionCloseMiddleware)


@app.get("/")
async def root():
    return {"message": "hello"}


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/greet/{name}")
async def greet(name: str):
    return {"message": f"hello {name}"}
