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
