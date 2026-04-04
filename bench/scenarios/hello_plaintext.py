"""Minimal plaintext response benchmark."""

import snek

app = snek.App()


@app.get("/")
def hello() -> str:
    return "Hello, World!"


if __name__ == "__main__":
    app.run(module_ref="hello_plaintext:app")
