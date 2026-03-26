"""snek application class with FastAPI-style decorators."""

import types


class App:
    def __init__(self):
        self._routes = []
        self.redis = Redis()

    def get(self, path):
        return self._route("GET", path)

    def post(self, path):
        return self._route("POST", path)

    def put(self, path):
        return self._route("PUT", path)

    def delete(self, path):
        return self._route("DELETE", path)

    def patch(self, path):
        return self._route("PATCH", path)

    def _route(self, method, path):
        def decorator(func):
            from snek import _snek
            _snek.add_route(method, path, func)
            self._routes.append((method, path, func))
            return func
        return decorator

    def run(self, host="0.0.0.0", port=8080, module_ref=""):
        from snek import _snek
        print(f"\n  snek listening on http://{host}:{port}/")
        print(f"  {len(self._routes)} routes registered\n")
        for method, path, _ in self._routes:
            print(f"    {method} {path}")
        print()
        _snek.run(host, port, module_ref)


def _encode_resp(*args: str) -> bytes:
    """Encode a Redis command as RESP protocol bytes."""
    parts = [b"*", str(len(args)).encode(), b"\r\n"]
    for arg in args:
        encoded = arg.encode() if isinstance(arg, str) else arg
        parts.extend([b"$", str(len(encoded)).encode(), b"\r\n", encoded, b"\r\n"])
    return b"".join(parts)


class Redis:
    @types.coroutine
    def get(self, key: str):
        return (yield ("redis", _encode_resp("GET", key)))

    @types.coroutine
    def set(self, key: str, value: str):
        return (yield ("redis", _encode_resp("SET", key, value)))

    @types.coroutine
    def setex(self, key: str, seconds: int, value: str):
        return (yield ("redis", _encode_resp("SETEX", key, str(seconds), value)))

    @types.coroutine
    def delete(self, *keys: str):
        return (yield ("redis", _encode_resp("DEL", *keys)))

    @types.coroutine
    def incr(self, key: str):
        return (yield ("redis", _encode_resp("INCR", key)))

    @types.coroutine
    def expire(self, key: str, seconds: int):
        return (yield ("redis", _encode_resp("EXPIRE", key, str(seconds))))

    @types.coroutine
    def ttl(self, key: str):
        return (yield ("redis", _encode_resp("TTL", key)))

    @types.coroutine
    def exists(self, *keys: str):
        return (yield ("redis", _encode_resp("EXISTS", *keys)))

    @types.coroutine
    def ping(self):
        return (yield ("redis", _encode_resp("PING")))
