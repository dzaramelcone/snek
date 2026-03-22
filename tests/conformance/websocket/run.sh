#!/usr/bin/env bash
#
# WebSocket conformance via autobahn-testsuite (RFC 6455).
# Requires: Docker, snek on PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
PORT=9001

mkdir -p "$RESULTS_DIR"

echo "==> Starting snek WebSocket echo server on :$PORT"
snek serve --ws-echo --port "$PORT" &
SNEK_PID=$!

# Give the server a moment to bind.
sleep 1

echo "==> Running autobahn-testsuite"
docker run --rm \
    -v "$SCRIPT_DIR/autobahn.toml:/config/autobahn.toml:ro" \
    -v "$RESULTS_DIR:/results" \
    --add-host=host.docker.internal:host-gateway \
    crossbario/autobahn-testsuite \
    wstest -m fuzzingclient -s /config/autobahn.toml

echo "==> Stopping echo server"
kill "$SNEK_PID" 2>/dev/null || true
wait "$SNEK_PID" 2>/dev/null || true

# Check results: autobahn writes an index.json with per-case verdicts.
if [ -f "$RESULTS_DIR/index.json" ]; then
    FAILURES=$(python3 -c "
import json, sys
data = json.load(open('$RESULTS_DIR/index.json'))
agent = list(data.keys())[0]
fails = [k for k, v in data[agent].items() if v['behavior'] not in ('OK', 'INFORMATIONAL', 'NON-STRICT')]
print(len(fails))
")
    if [ "$FAILURES" -gt 0 ]; then
        echo "FAIL: $FAILURES test cases did not pass."
        echo "See $RESULTS_DIR/index.json for details."
        exit 1
    fi
fi

echo "PASS: all autobahn test cases passed."
