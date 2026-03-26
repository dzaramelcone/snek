## Build

```bash
# Native (macOS kqueue)
zig build
zig build -Doptimize=ReleaseFast

# Cross-compile for Linux aarch64 (io_uring)
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseFast -Dpython=true

# Clear cache when binary doesn't update after code changes
rm -rf .zig-cache

# Build just the Python extension
zig build pyext
```

Outputs:
- `zig-out/lib/lib_snek.dylib` — Python extension (macOS)
- `zig-out/lib/lib_snek.so` — Python extension (Linux cross-compile)

## Running locally

```bash
# Symlink the extension into the Python package (one-time)
ln -sf $(pwd)/zig-out/lib/lib_snek.dylib python/snek/_snek.cpython-314-darwin.so

# Run
PYTHONPATH=python:bench/scenarios python3 bench/scenarios/hello_minimal.py

# Verify
curl http://127.0.0.1:8080/
```

## Benchmarking protocol

Use oha (not hey). Always warm up before measuring:

```bash
# 1. Primer — establish connections (c=8, 4s)
oha --no-tui -c 8 -z 4s http://127.0.0.1:8080/

# 2. Warmup — ramp to target concurrency (c=target, 3s)
oha --no-tui -c 50 -z 3s http://127.0.0.1:8080/

# 3. Bench — actual measurement (c=target, 10s)
oha --no-tui -c 50 -z 10s http://127.0.0.1:8080/
```

Only report numbers from step 3.

## Docker benchmarking

```bash
cd bench/compose

# Start container (has oha + granian + Python 3.14)
docker compose up -d

# Run snek inside container
docker compose exec -T bench bash -c '
ln -sf /bench/snek_lib/lib_snek.so /bench/snek_root/snek/_snek.so
PYTHONPATH=/bench/snek_root:/bench python3 /bench/snek_app.py &
sleep 3
oha --no-tui -c 50 -z 10s http://127.0.0.1:8080/
'

# Run granian for comparison
docker compose exec -T bench bash -c '
granian --interface asgi --log-level warning --http 1 --no-ws \
  --workers 1 --runtime-threads 1 app:app &
sleep 2
oha --no-tui -c 50 -z 10s http://127.0.0.1:8000/
'

# Stop
docker compose down
```

Granian benchmark methodology: primer (c=8, 4s), warmup (c=max, 3s), bench (10s).

## Stale binary gotchas

- Python prefers `.cpython-*-darwin.so` files in `python/snek/` over built-in modules. Delete stale ones.
- `zig build` caches aggressively. If the binary timestamp doesn't change after editing source, `rm -rf .zig-cache`.
- `-Dpython` defaults to true for native builds, false for cross-compile. Pass `-Dpython=true` explicitly when cross-compiling.
