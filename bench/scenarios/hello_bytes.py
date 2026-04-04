"""Minimal bytes response benchmark."""

import snek

app = snek.App()


@app.get("/")
def hello() -> bytes:
    return b"Hello, World!"


if __name__ == "__main__":
    app.run(module_ref="hello_bytes:app")
