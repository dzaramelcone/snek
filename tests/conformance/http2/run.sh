#!/usr/bin/env bash
#
# HTTP/2 conformance via h2spec (RFC 7540).
# Requires: Docker or h2spec binary, snek on PATH.
# Reference: https://github.com/summerwind/h2spec
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
PORT=8443

mkdir -p "$RESULTS_DIR"

echo "==> Starting snek with HTTP/2 on :$PORT"
snek serve --h2 --port "$PORT" &
SNEK_PID=$!
sleep 1

echo "==> Running h2spec (all RFC 7540 sections)"

if command -v h2spec &>/dev/null; then
    h2spec -h 127.0.0.1 -p "$PORT" -j "$RESULTS_DIR/h2spec.json" -v
    H2SPEC_EXIT=$?
else
    docker run --rm \
        --add-host=host.docker.internal:host-gateway \
        summerwind/h2spec \
        h2spec -h host.docker.internal -p "$PORT" -j /dev/stdout -v \
        > "$RESULTS_DIR/h2spec.json"
    H2SPEC_EXIT=$?
fi

kill "$SNEK_PID" 2>/dev/null || true
wait "$SNEK_PID" 2>/dev/null || true

if [ "$H2SPEC_EXIT" -ne 0 ]; then
    echo "FAIL: h2spec found conformance issues."
    echo "See $RESULTS_DIR/h2spec.json for details."
    exit 1
fi

echo "PASS: h2spec — all sections passed."
