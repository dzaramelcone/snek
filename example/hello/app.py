"""snek hello world — @app.get style decorators."""

import _snek


class App:
    def __init__(self):
        self._routes = []

    def get(self, path):
        return self._route("GET", path)

    def post(self, path):
        return self._route("POST", path)

    def _route(self, method, path):
        def decorator(func):
            _snek.add_route(method, path, func)
            self._routes.append((method, path, func))
            return func
        return decorator

    def run(self, host="0.0.0.0", port=8080):
        print(f"\n  snek listening on http://{host}:{port}/")
        print(f"  {len(self._routes)} routes registered\n")
        for method, path, _ in self._routes:
            print(f"    {method} {path}")
        print()
        _snek.run(host, port)


app = App()


@app.get("/")
def hello(request):
    return {"message": "hello from snek python"}


@app.get("/health")
def health(request):
    return {"status": "ok"}


if __name__ == "__main__":
    app.run()
