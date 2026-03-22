#!/usr/bin/env bash
# Benchmark comparison: snek vs Python, Go, and others
#
# Usage: ./bench/run_comparison.sh
# Requires: hey (brew install hey), go, python3
#
# Runs each server, benchmarks with hey, prints summary table.

set -euo pipefail

REQUESTS=50000
CONCURRENCY=50
PORT_SNEK=8090
PORT_PYTHON=8091
PORT_GO=8092

cleanup() {
    kill $SNEK_PID $PY_PID $GO_PID 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT

echo "=== snek HTTP Benchmark Comparison ==="
echo "Requests: $REQUESTS, Concurrency: $CONCURRENCY"
echo ""

# ── Build snek ──────────────────────────────────────────────────────
echo "Building snek..."
zig build-exe -OReleaseFast bench/hello_server.zig -femit-bin=bench/hello_server 2>/dev/null

# ── snek (single-threaded blocking) ─────────────────────────────────
PORT=$PORT_SNEK bench/hello_server &
SNEK_PID=$!
sleep 0.5

echo "▸ snek (single-threaded, blocking)"
SNEK_RESULT=$(hey -n $REQUESTS -c $CONCURRENCY http://127.0.0.1:$PORT_SNEK/ 2>&1)
SNEK_RPS=$(echo "$SNEK_RESULT" | grep "Requests/sec" | awk '{print $2}')
SNEK_AVG=$(echo "$SNEK_RESULT" | grep "Average" | awk '{print $2}')
echo "  $SNEK_RPS req/sec, avg latency ${SNEK_AVG}s"
kill $SNEK_PID 2>/dev/null; wait $SNEK_PID 2>/dev/null || true

# ── Python stdlib ───────────────────────────────────────────────────
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        body = json.dumps({'message':'hello from python'}).encode()
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
HTTPServer(('127.0.0.1', $PORT_PYTHON), H).serve_forever()
" &
PY_PID=$!
sleep 1

echo "▸ Python stdlib (single-threaded)"
PY_RESULT=$(hey -n $REQUESTS -c $CONCURRENCY http://127.0.0.1:$PORT_PYTHON/ 2>&1)
PY_RPS=$(echo "$PY_RESULT" | grep "Requests/sec" | awk '{print $2}')
PY_AVG=$(echo "$PY_RESULT" | grep "Average" | awk '{print $2}')
echo "  $PY_RPS req/sec, avg latency ${PY_AVG}s"
kill $PY_PID 2>/dev/null; wait $PY_PID 2>/dev/null || true

# ── Go net/http ─────────────────────────────────────────────────────
if command -v go &>/dev/null; then
    cat > /tmp/snek_bench_go.go << 'GOEOF'
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" { port = "8092" }
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"message":"hello from go"}`)
	})
	http.ListenAndServe(":"+port, nil)
}
GOEOF
    PORT=$PORT_GO go run /tmp/snek_bench_go.go &
    GO_PID=$!
    sleep 2

    echo "▸ Go net/http (multi-threaded, goroutines)"
    GO_RESULT=$(hey -n $REQUESTS -c $CONCURRENCY http://127.0.0.1:$PORT_GO/ 2>&1)
    GO_RPS=$(echo "$GO_RESULT" | grep "Requests/sec" | awk '{print $2}')
    GO_AVG=$(echo "$GO_RESULT" | grep "Average" | awk '{print $2}')
    echo "  $GO_RPS req/sec, avg latency ${GO_AVG}s"
    kill $GO_PID 2>/dev/null; wait $GO_PID 2>/dev/null || true
else
    echo "▸ Go: not installed, skipping"
    GO_RPS="N/A"
    GO_AVG="N/A"
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "┌──────────────────────────────┬────────────────┬──────────────┐"
echo "│ Server                       │ Req/sec        │ Avg Latency  │"
echo "├──────────────────────────────┼────────────────┼──────────────┤"
printf "│ %-28s │ %14s │ %12s │\n" "Python stdlib" "$PY_RPS" "${PY_AVG}s"
printf "│ %-28s │ %14s │ %12s │\n" "snek (blocking, 1 thread)" "$SNEK_RPS" "${SNEK_AVG}s"
printf "│ %-28s │ %14s │ %12s │\n" "Go net/http (goroutines)" "$GO_RPS" "${GO_AVG}s"
echo "└──────────────────────────────┴────────────────┴──────────────┘"
echo ""
echo "Note: snek is single-threaded blocking. Multi-threaded async will"
echo "close the gap with Go. Target: 100K+ req/sec with io_uring."
