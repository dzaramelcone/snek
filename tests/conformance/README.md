# Conformance Tests

Protocol conformance suites for snek's network implementations.

## Suites

| Suite | Protocol | Tool | Spec |
|-------|----------|------|------|
| `websocket/` | WebSocket | [autobahn-testsuite](https://github.com/crossbario/autobahn-testsuite) | RFC 6455 |
| `http1/` | HTTP/1.1 | curl + h2load | RFC 7230-7235 |
| `http2/` | HTTP/2 | [h2spec](https://github.com/summerwind/h2spec) | RFC 7540 |
| `tls/` | TLS | [testssl.sh](https://github.com/drwetter/testssl.sh) | RFC 8446 / 5246 |
| `postgres/` | PostgreSQL wire | psql + libpq | Frontend/Backend Protocol |
| `python_eventloop/` | Python event loop | uvloop + CPython upstream tests | asyncio / PEP 492 |

## Running

Each suite has a `run.sh` script. They assume snek is available on PATH and Docker is running.

```sh
# Run a single suite
./tests/conformance/websocket/run.sh

# Run all suites
for s in tests/conformance/*/run.sh; do bash "$s" || exit 1; done
```

Results land in each suite's `results/` directory (gitignored).
