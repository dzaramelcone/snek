"""snek CLI — run a snek app.

Usage: snek app:app
       snek app:app --port 9000
       snek app:app --host 0.0.0.0 --port 8080
"""

import sys
import importlib


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print("Usage: snek <module>:<app> [--host HOST] [--port PORT]")
        print("Example: snek app:app --port 8080")
        sys.exit(0)

    app_ref = args[0]
    host = "0.0.0.0"
    port = 8080

    i = 1
    while i < len(args):
        if args[i] == "--host" and i + 1 < len(args):
            host = args[i + 1]
            i += 2
        elif args[i] == "--port" and i + 1 < len(args):
            port = int(args[i + 1])
            i += 2
        else:
            i += 1

    if ":" not in app_ref:
        print(f"Error: expected module:app format, got '{app_ref}'")
        sys.exit(1)

    module_name, app_name = app_ref.split(":", 1)

    sys.path.insert(0, ".")
    mod = importlib.import_module(module_name)
    app = getattr(mod, app_name)

    app.run(host=host, port=port)


if __name__ == "__main__":
    main()
