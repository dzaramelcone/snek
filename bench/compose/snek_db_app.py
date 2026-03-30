import sys, os

sys.path.insert(0, "/bench/snek_root")

_so_target = "/bench/snek_root/snek/_snek.so"
if not os.path.exists(_so_target):
    os.symlink("/bench/snek_lib/lib_snek.so", _so_target)

import snek

app = snek.App()

@app.get("/")
async def handler():
    row = await app.db.fetch_one("SELECT id, name FROM bench WHERE id = $1", "1")
    return row

if __name__ == "__main__":
    app.run(module_ref="snek_db_app:app")
