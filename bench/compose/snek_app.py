import sys, os

sys.path.insert(0, "/bench/snek_root")

# _snek.so needs to be findable inside the snek package
_so_target = "/bench/snek_root/snek/_snek.so"
if not os.path.exists(_so_target):
    os.symlink("/bench/snek_lib/lib_snek.so", _so_target)

import snek

app = snek.App()

@app.get("/")
def hello():
    return {"message": "hello"}

if __name__ == "__main__":
    app.run(module_ref="snek_app:app")
