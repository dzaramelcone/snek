"""snek CLI — run a snek app.

Usage: snek app:app
       snek app:app --port 9000
       snek app:app --host 0.0.0.0 --port 8080
       snek app:app --reload
"""

import importlib
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def _parse_args(args: list[str]) -> dict:
    if not args or args[0] in ("-h", "--help"):
        print("Usage: snek <module>:<app> [--host HOST] [--port PORT] [--reload]")
        print("Example: snek app:app --port 8080 --reload")
        sys.exit(0)

    result = {"app_ref": args[0], "host": "0.0.0.0", "port": 8080, "reload": False}
    i = 1
    while i < len(args):
        if args[i] == "--host" and i + 1 < len(args):
            result["host"] = args[i + 1]
            i += 2
        elif args[i] == "--port" and i + 1 < len(args):
            result["port"] = int(args[i + 1])
            i += 2
        elif args[i] == "--reload":
            result["reload"] = True
            i += 1
        else:
            i += 1

    if ":" not in result["app_ref"]:
        print(f"Error: expected module:app format, got '{result['app_ref']}'")
        sys.exit(1)

    return result


_WATCH_EXCLUDE = {".venv", "venv", "__pycache__", "refs", "build", "zig-out", ".zig-cache", "node_modules"}


def _collect_py_mtimes(directory: str = ".") -> dict[str, float]:
    mtimes: dict[str, float] = {}
    for p in Path(directory).rglob("*.py"):
        if any(part in _WATCH_EXCLUDE for part in p.parts):
            continue
        mtimes[str(p)] = p.stat().st_mtime
    return mtimes


def _run_with_reload(args: dict) -> None:
    """Supervisor process: spawn the server, watch .py files, restart on change."""
    cmd = [sys.executable, "-m", "snek.cli", args["app_ref"],
           "--host", args["host"], "--port", str(args["port"])]

    while True:
        mtimes = _collect_py_mtimes()
        proc = subprocess.Popen(cmd)
        print(f"  [reload] watching for .py changes (pid {proc.pid})\n")

        changed = False
        while not changed:
            time.sleep(1)
            if proc.poll() is not None:
                sys.exit(proc.returncode)
            current = _collect_py_mtimes()
            for path, old_mtime in mtimes.items():
                if current.get(path, 0) != old_mtime:
                    print(f"\n  [reload] {path} changed, restarting...")
                    changed = True
                    break
            if not changed and set(current) - set(mtimes):
                print(f"\n  [reload] new file detected, restarting...")
                changed = True

        os.kill(proc.pid, signal.SIGTERM)
        proc.wait()


def _run_server(args: dict) -> None:
    """Run the server directly (no reload)."""
    module_name, app_name = args["app_ref"].split(":", 1)
    sys.path.insert(0, ".")
    mod = importlib.import_module(module_name)
    app = getattr(mod, app_name)
    app.run(host=args["host"], port=args["port"])


def main():
    args = _parse_args(sys.argv[1:])

    if args["reload"]:
        _run_with_reload(args)
    else:
        _run_server(args)


if __name__ == "__main__":
    main()
