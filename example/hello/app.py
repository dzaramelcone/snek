"""snek hello world — the first real Python snek app."""

import _snek


def hello(request):
    return {"message": "hello from snek python"}


def health(request):
    return {"status": "ok"}


def greet(request):
    name = request.get("params", {}).get("name", "world")
    return {"greeting": f"hello, {name}!"}


_snek.add_route("GET", "/", hello)
_snek.add_route("GET", "/health", health)
_snek.add_route("GET", "/greet/{name}", greet)

print("snek python app starting...")
_snek.run("0.0.0.0", 8080)
