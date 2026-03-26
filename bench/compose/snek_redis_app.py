import sys, os

sys.path.insert(0, "/bench/snek_root")

_so_target = "/bench/snek_root/snek/_snek.so"
if not os.path.exists(_so_target):
    os.symlink("/bench/snek_lib/lib_snek.so", _so_target)

import snek

app = snek.App()

@app.get("/")
async def handler():
    val = await app.redis.get("bench:key")
    if val is None:
        await app.redis.set("bench:key", "hello")
        val = b"hello"
    return {"cached": val.decode() if isinstance(val, bytes) else str(val)}

if __name__ == "__main__":
    app.run(module_ref="snek_redis_app:app")
