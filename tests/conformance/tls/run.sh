#!/usr/bin/env bash
#
# TLS conformance via testssl.sh.
# Requires: Docker or testssl.sh, snek on PATH.
# Reference: https://github.com/drwetter/testssl.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
PORT=8443

mkdir -p "$RESULTS_DIR"

echo "==> Starting snek with TLS on :$PORT"
snek serve --tls --port "$PORT" &
SNEK_PID=$!
sleep 1

echo "==> Running testssl.sh"

TESTSSL_ARGS=(
    --protocols          # TLS 1.2 and 1.3 support
    --ciphers            # cipher suite enumeration
    --server-defaults    # certificate chain, OCSP, etc.
    --vulnerabilities    # BEAST, POODLE, Heartbleed, etc.
    --quiet
    --jsonfile "$RESULTS_DIR/testssl.json"
    "127.0.0.1:$PORT"
)

if command -v testssl &>/dev/null; then
    testssl "${TESTSSL_ARGS[@]}"
    TESTSSL_EXIT=$?
elif command -v testssl.sh &>/dev/null; then
    testssl.sh "${TESTSSL_ARGS[@]}"
    TESTSSL_EXIT=$?
else
    docker run --rm \
        --add-host=host.docker.internal:host-gateway \
        -v "$RESULTS_DIR:/results" \
        drwetter/testssl.sh \
        --protocols --ciphers --server-defaults --vulnerabilities \
        --quiet --jsonfile /results/testssl.json \
        "host.docker.internal:$PORT"
    TESTSSL_EXIT=$?
fi

kill "$SNEK_PID" 2>/dev/null || true
wait "$SNEK_PID" 2>/dev/null || true

if [ "$TESTSSL_EXIT" -ne 0 ]; then
    echo "FAIL: testssl.sh reported issues."
    echo "See $RESULTS_DIR/testssl.json for details."
    exit 1
fi

echo "PASS: TLS conformance checks passed."
