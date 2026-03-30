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

# Run event-loop benchmarks
./bench/run_eventloop.sh

# Compare results
python3 bench/compare.py bench/results/latest.json
```

## Event Loop Benchmarks

The event-loop benchmark is split into two layers:

- `bench/eventloop_microbench.py` measures raw loop throughput in-process:
  `call_soon`, `call_later(0)`, `asyncio.sleep(0)` chains, and task fan-out.
- `bench/eventloop_http_bench.py` uses `oha` against async route scenarios so
  you can see the HTTP-facing cost of additional await hops across `snek`,
  stdlib `asyncio`, and `uvloop`.
- `bench/eventloop_echo_bench.py` runs uvloop-style TCP echo controls for
  `streams`, `protocol`, and `sockets` modes against stdlib `asyncio` and
  `uvloop`.

Examples:

```sh
# In-process loop microbench only
python3 bench/eventloop_microbench.py --json-out bench/results/eventloop_microbench.json

# Isolated provider microbench checkpoint
python3 bench/eventloop_regression_check.py --json-out bench/results/eventloop_regression.json

# HTTP async-route benchmark only
python3 bench/eventloop_http_bench.py --duration 15s --connections 256 --providers snek,uvloop

# Combined runner
./bench/run_eventloop.sh

# Echo-style control benchmark only
python3 bench/eventloop_echo_bench.py --duration 5s --connections 32
```

The runner bootstraps a local benchmark venv under `bench/.venv-eventloop`,
installs `uvloop` there, rebuilds the native extension, and refreshes the
in-tree `_snek` module before each run. The in-process microbench compares
`snek.loop` against the default `asyncio` loop and `uvloop` when available.
The HTTP benchmark uses `snek` directly plus a minimal `asyncio`/`uvloop`
control server that exercises the same await chains. The `call_soon`, timer,
and task cases run in bounded batches so they stay within the native loop's
current fixed-capacity ready/timer queues.

The TCP echo benchmark is a control benchmark, not a direct `snek.loop`
comparison yet. `snek.loop` does not expose the socket/server APIs needed to
run the same `streams` / `protocol` / `sockets` workloads, so this benchmark is
currently for `uvloop` versus stdlib `asyncio`, matching uvloop's published
benchmark categories more closely.

For quick regression tracking on macOS, prefer
`bench/eventloop_regression_check.py`. It runs each provider in a separate
subprocess so `snek.loop`'s `asyncio` monkeypatching does not contaminate the
`asyncio` and `uvloop` control measurements.

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
