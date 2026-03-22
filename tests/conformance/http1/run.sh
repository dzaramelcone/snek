#!/usr/bin/env bash
#
# HTTP/1.1 conformance tests (RFC 7230-7235).
# Requires: curl, snek on PATH.
# Optional: h2load (nghttp2), http-spec-tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
PORT=8080
BASE="http://127.0.0.1:$PORT"

mkdir -p "$RESULTS_DIR"
PASS=0
FAIL=0

fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }

echo "==> Starting snek on :$PORT"
snek serve --port "$PORT" &
SNEK_PID=$!
sleep 1

# ── Chunked transfer encoding ──────────────────────────────────────

echo "--- Chunked encoding"
RESP=$(curl -s -H "Transfer-Encoding: chunked" -d '{"x":1}' "$BASE/health")
if echo "$RESP" | grep -q "status"; then
    pass "chunked request accepted"
else
    fail "chunked request rejected"
fi

# ── Keep-alive ──────────────────────────────────────────────────────

echo "--- Keep-alive"
# Send two requests on the same connection.
STATUS=$(curl -s -o /dev/null -w "%{http_code}" --keepalive-time 2 "$BASE/health" "$BASE/health")
if [ "$STATUS" = "200" ]; then
    pass "keep-alive works"
else
    fail "keep-alive broken (status=$STATUS)"
fi

# ── Pipelining ──────────────────────────────────────────────────────

echo "--- Pipelining"
# Use raw TCP to send pipelined requests.
PIPELINED=$(printf "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\nGET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" \
    | nc -w 2 127.0.0.1 "$PORT" 2>/dev/null)
COUNT=$(echo "$PIPELINED" | grep -c "HTTP/1.1 200" || true)
if [ "$COUNT" -ge 2 ]; then
    pass "pipelining returns two responses"
else
    fail "pipelining returned $COUNT responses (expected 2)"
fi

# ── 100-continue ────────────────────────────────────────────────────

echo "--- 100-continue"
RESP=$(curl -s -H "Expect: 100-continue" -d '{"x":1}' -w "\n%{http_code}" "$BASE/health")
CODE=$(echo "$RESP" | tail -1)
if [ "$CODE" = "200" ]; then
    pass "100-continue handled"
else
    fail "100-continue failed (code=$CODE)"
fi

# ── Content-Length validation ───────────────────────────────────────

echo "--- Content-Length validation"
# Send a request where Content-Length disagrees with body size.
BAD=$(printf "POST /health HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 999\r\n\r\nsmall" \
    | nc -w 2 127.0.0.1 "$PORT" 2>/dev/null)
if echo "$BAD" | grep -qE "HTTP/1.1 (400|411)"; then
    pass "bad Content-Length rejected"
else
    fail "bad Content-Length not rejected"
fi

# ── h2load stress (optional) ───────────────────────────────────────

if command -v h2load &>/dev/null; then
    echo "--- h2load HTTP/1.1 stress"
    h2load -n 1000 -c 10 --h1 "$BASE/health" > "$RESULTS_DIR/h2load.txt" 2>&1
    pass "h2load completed (see results/h2load.txt)"
else
    echo "  SKIP: h2load not found"
fi

# ── Cleanup ─────────────────────────────────────────────────────────

kill "$SNEK_PID" 2>/dev/null || true
wait "$SNEK_PID" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
