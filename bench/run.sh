#!/usr/bin/env bash
#
# Run all snek benchmarks and collect results.
# Requires: wrk (or rewrk), snek on PATH.
# Optional: uvicorn, blacksheep for comparison.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="$RESULTS_DIR/$TIMESTAMP.json"
LATEST_LINK="$RESULTS_DIR/latest.json"

# Configurable parameters.
DURATION="${BENCH_DURATION:-30s}"
THREADS="${BENCH_THREADS:-4}"
CONNECTIONS="${BENCH_CONNECTIONS:-256}"
PORT=8080

mkdir -p "$RESULTS_DIR"

echo "==> Benchmark config: duration=$DURATION threads=$THREADS connections=$CONNECTIONS"
echo '{"meta":{},"results":[]}' > "$RESULT_FILE"

# ── Helper: run one scenario ───────────────────────────────────────

run_scenario() {
    local name="$1"
    local module="$2"
    local server_cmd="$3"
    local url="${4:-http://127.0.0.1:$PORT/}"

    echo ""
    echo "--- $name"

    # Start server.
    eval "$server_cmd" &
    local pid=$!
    sleep 2

    # Run wrk.
    local wrk_out
    wrk_out=$(wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" -s "$SCRIPT_DIR/wrk_json.lua" "$url" 2>&1 || true)

    # Extract metrics.
    local rps latency_avg latency_p99
    rps=$(echo "$wrk_out" | grep "Requests/sec" | awk '{print $2}' || echo "0")
    latency_avg=$(echo "$wrk_out" | grep "Latency" | awk '{print $2}' || echo "0")
    latency_p99=$(echo "$wrk_out" | grep "99%" | awk '{print $2}' || echo "0")

    # Append to results JSON.
    python3 -c "
import json
with open('$RESULT_FILE') as f:
    data = json.load(f)
data['results'].append({
    'scenario': '$name',
    'module': '$module',
    'rps': '$rps',
    'latency_avg': '$latency_avg',
    'latency_p99': '$latency_p99',
    'duration': '$DURATION',
    'threads': $THREADS,
    'connections': $CONNECTIONS,
})
with open('$RESULT_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
    echo "  rps=$rps avg=$latency_avg p99=$latency_p99"

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# ── Snek scenarios ─────────────────────────────────────────────────

SCENARIOS=(
    "hello:scenarios/hello.py"
    "json_serialization:scenarios/json_serialization.py"
    "db_query:scenarios/db_query.py"
    "db_multi:scenarios/db_multi.py"
    "middleware_chain:scenarios/middleware_chain.py"
    "redis_cached:scenarios/redis_cached.py"
)

for entry in "${SCENARIOS[@]}"; do
    name="${entry%%:*}"
    module="${entry#*:}"
    run_scenario "snek/$name" "$module" "snek serve --module $SCRIPT_DIR/$module --port $PORT"
done

# ── Comparison: uvicorn + FastAPI ──────────────────────────────────

if command -v uvicorn &>/dev/null; then
    echo ""
    echo "==> Comparison: uvicorn + FastAPI"
    run_scenario "uvicorn/hello" "fastapi_hello" \
        "uvicorn bench.scenarios.hello_fastapi:app --host 127.0.0.1 --port $PORT --log-level warning"
fi

# ── Comparison: BlackSheep ─────────────────────────────────────────

if python3 -c "import blacksheep" 2>/dev/null; then
    echo ""
    echo "==> Comparison: BlackSheep"
    run_scenario "blacksheep/hello" "blacksheep_hello" \
        "uvicorn bench.scenarios.hello_blacksheep:app --host 127.0.0.1 --port $PORT --log-level warning"
fi

# ── Finalize ───────────────────────────────────────────────────────

# Add metadata.
python3 -c "
import json, platform, datetime
with open('$RESULT_FILE') as f:
    data = json.load(f)
data['meta'] = {
    'timestamp': '$TIMESTAMP',
    'platform': platform.platform(),
    'python': platform.python_version(),
    'duration': '$DURATION',
    'threads': $THREADS,
    'connections': $CONNECTIONS,
}
with open('$RESULT_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"

ln -sf "$RESULT_FILE" "$LATEST_LINK"

echo ""
echo "==> Results written to $RESULT_FILE"
echo "==> Compare with: python3 bench/compare.py $RESULT_FILE"

# ── Regression check ───────────────────────────────────────────────

PREVIOUS=$(ls -t "$RESULTS_DIR"/*.json 2>/dev/null | grep -v latest | head -2 | tail -1)
if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$RESULT_FILE" ]; then
    echo ""
    echo "==> Regression check vs $(basename "$PREVIOUS")"
    python3 "$SCRIPT_DIR/compare.py" "$PREVIOUS" "$RESULT_FILE" || true
fi
