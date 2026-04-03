# Benchmarks

Performance benchmarks for snek, with comparison against other Python web frameworks.

## Scenarios

| Scenario | Description |
|----------|-------------|
| `hello.py` | Minimal JSON response — baseline latency |
| `json_serialization.py` | Large JSON payload (100 nested items) |
| `db_query.py` | Single SELECT query |
| `db_multi.py` | 3 parallel queries via `app.gather()` |
| `middleware_chain.py` | 5 middleware layers — measures overhead |
| `websocket_echo.py` | WebSocket echo — throughput test |
| `redis_cached.py` | Redis cache with DB fallback |

## Running

```sh
# Run all benchmarks
./bench/run.sh

# Compare results
python3 bench/compare.py bench/results/latest.json
```

## Methodology

- Each scenario runs for 30 seconds with wrk (configurable).
- Default: 4 threads, 256 connections.
- Results collected in JSON for regression tracking.
- Comparison targets: uvicorn+FastAPI, Starlette, BlackSheep.

## Reproducibility

Use the Dockerfile for consistent environments:

```sh
docker build -t snek-bench bench/
docker run --rm snek-bench
```

## Linux Container Note

When building the Python extension locally for the Linux `bench/compose` container,
use the GNU target triple:

```sh
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu
```

Using `aarch64-linux` produced an ELF with `libc.so` as a direct dependency,
which does not load in the Debian-based bench container. The `-gnu` target
produces the expected `libc.so.6` dependency and can be copied or mounted into
the container directly.

## Docker Benchmarking

For throughput numbers, do not benchmark the compose app through the host
published port on Docker Desktop. That path mixes in Docker Desktop NAT and
host/container networking overhead and can produce badly misleading numbers.

Use the internal Docker network with a separate loadgen container instead:

```sh
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu
bash bench/compose/run_scenario.sh hello_min
bash bench/compose/run_scenario.sh db_param_one
```

You can override the main knobs with environment variables:

```sh
CONCURRENCY=256 THREADS=7 DURATION=10s bash bench/compose/run_scenario.sh db_param_one
PROJECT=basebench COMPOSE_FILE=/tmp/snek-baseline/bench/compose/docker-compose.yml \
  bash bench/compose/run_scenario.sh hello_min
```

The runner:
- starts `postgres` and `bench`
- restarts the `bench` service to clear any previous app process
- starts the selected scenario inside `bench`
- waits for readiness from inside the container
- runs `oha` from a separate container on the same compose network
