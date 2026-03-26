"""Granian benchmark control — raw ASGI, no framework overhead."""

import json

HELLO_BODY = json.dumps({"message": "hello"}).encode()
HELLO_HEADERS = [
    (b"content-type", b"application/json"),
    (b"content-length", str(len(HELLO_BODY)).encode()),
    (b"connection", b"close"),
]

HEALTH_BODY = json.dumps({"status": "ok"}).encode()
HEALTH_HEADERS = [
    (b"content-type", b"application/json"),
    (b"content-length", str(len(HEALTH_BODY)).encode()),
    (b"connection", b"close"),
]

NOT_FOUND_BODY = b"Not Found"
NOT_FOUND_HEADERS = [
    (b"content-type", b"text/plain"),
    (b"content-length", b"9"),
    (b"connection", b"close"),
]


async def app(scope, receive, send):
    path = scope["path"]

    if path == "/":
        await send({"type": "http.response.start", "status": 200, "headers": HELLO_HEADERS})
        await send({"type": "http.response.body", "body": HELLO_BODY})
    elif path == "/health":
        await send({"type": "http.response.start", "status": 200, "headers": HEALTH_HEADERS})
        await send({"type": "http.response.body", "body": HEALTH_BODY})
    else:
        await send({"type": "http.response.start", "status": 404, "headers": NOT_FOUND_HEADERS})
        await send({"type": "http.response.body", "body": NOT_FOUND_BODY})
