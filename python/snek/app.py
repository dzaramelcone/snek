"""snek application class with FastAPI-style decorators."""

import types
from enum import IntEnum

from snek import _snek


class App:
    def __init__(self):
        self._routes = []
        self.redis = Redis()
        self.db = Db()

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
            _snek.add_route(method, path, func)
            self._routes.append((method, path, func))
            return func

        return decorator

    def run(self, host="0.0.0.0", port=8080, threads=1, module_ref=""):
        print(f"\n  snek listening on http://{host}:{port}/ ({threads} threads)")
        print(f"  {len(self._routes)} routes registered\n")
        for method, path, _ in self._routes:
            print(f"    {method} {path}")
        print()
        _snek.run(host, port, threads, module_ref)


class _Cmd(IntEnum):
    """Command IDs — must match REDIS_CMD_NAMES in driver.zig."""
    GET = 0; SET = 1; DEL = 2; INCR = 3; EXPIRE = 4; TTL = 5; EXISTS = 6; PING = 7; SETEX = 8


class Redis:
    """Yield (cmd_id, *args). Zig looks up the command name and builds RESP."""

    @types.coroutine
    def get(self, key: str):
        return (yield (_Cmd.GET, key))

    @types.coroutine
    def set(self, key: str, value: str):
        return (yield (_Cmd.SET, key, value))

    @types.coroutine
    def setex(self, key: str, seconds: int, value: str):
        return (yield (_Cmd.SETEX, key, str(seconds), value))

    @types.coroutine
    def delete(self, *keys: str):
        return (yield (_Cmd.DEL, *keys))

    @types.coroutine
    def incr(self, key: str):
        return (yield (_Cmd.INCR, key))

    @types.coroutine
    def expire(self, key: str, seconds: int):
        return (yield (_Cmd.EXPIRE, key, str(seconds)))

    @types.coroutine
    def ttl(self, key: str):
        return (yield (_Cmd.TTL, key))

    @types.coroutine
    def exists(self, *keys: str):
        return (yield (_Cmd.EXISTS, *keys))

    @types.coroutine
    def ping(self):
        return (yield (_Cmd.PING,))


class _DbCmd(IntEnum):
    """Command IDs — must match PgCmd in driver.zig."""
    EXECUTE = 100; FETCH_ONE = 101; FETCH_ALL = 102


class Db:
    """Yield (cmd_id, sql). Zig builds postgres wire messages and pipelines them."""

    @types.coroutine
    def fetch_one(self, sql: str):
        return (yield (_DbCmd.FETCH_ONE, sql))

    @types.coroutine
    def fetch_all(self, sql: str):
        return (yield (_DbCmd.FETCH_ALL, sql))

    @types.coroutine
    def execute(self, sql: str):
        return (yield (_DbCmd.EXECUTE, sql))
