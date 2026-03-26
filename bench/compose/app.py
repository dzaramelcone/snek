"""Minimal ASGI app — mirrors snek hello benchmark."""

BODY = b'{"message":"hello"}'
HEADERS = [
    (b"content-type", b"application/json"),
    (b"content-length", b"19"),
]


async def app(scope, receive, send):
    await send({"type": "http.response.start", "status": 200, "headers": HEADERS})
    await send({"type": "http.response.body", "body": BODY})
