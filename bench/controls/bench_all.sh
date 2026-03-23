#!/usr/bin/env bash
# Comparative benchmark: run the same workload against all control servers
# Usage: bash bench_all.sh [results_dir]
set -euo pipefail

RESULTS="${1:-/results}"
mkdir -p "$RESULTS"

PORT=8080
CONCURRENCY_LEVELS="1 10 50 100 200 500"
DURATION=10
WARMUP=3

declare -a SERVERS=(
    "snek"
    "go"
    "rust"
    "fastapi"
)

echo "=== Comparative Benchmark Suite ==="
echo "Date: $(date)"
echo "Kernel: $(uname -r)"
echo "CPUs: $(nproc)"
echo "Duration: ${DURATION}s per level, warmup: ${WARMUP}s"
echo "Concurrency levels: ${CONCURRENCY_LEVELS}"
echo ""

start_snek() {
    export PYTHONPATH=/snek/python
    python3 -c "
from snek import App
app = App()

@app.get('/')
def hello(request):
    return {'message': 'hello'}

@app.get('/health')
def health(request):
    return {'status': 'ok'}

@app.get('/greet/{name}')
def greet(request):
    return {'message': 'hello ' + request['params']['name']}

app.run(port=$PORT)
" &
    SERVER_PID=$!
}

start_go() {
    /bench/controls/go/server "$PORT" &
    SERVER_PID=$!
}

start_rust() {
    /bench/controls/rust/server "$PORT" &
    SERVER_PID=$!
}

start_fastapi() {
    uvicorn bench.controls.fastapi.app:app --host 0.0.0.0 --port "$PORT" --workers 4 --log-level error &
    SERVER_PID=$!
}

stop_server() {
    kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null || true
    sleep 1
}

run_benchmark() {
    local name=$1
    local csv="$RESULTS/${name}_curve.csv"
    echo "concurrency,rps,latency_avg,latency_p50,latency_p99" > "$csv"

    for C in $CONCURRENCY_LEVELS; do
        local threads=$(( C < $(nproc) ? C : $(nproc) ))
        echo -n "  c=$C ... "

        OUTPUT=$(wrk -t"$threads" -c"$C" -d"${DURATION}s" --latency \
            "http://127.0.0.1:$PORT/" 2>&1)

        RPS=$(echo "$OUTPUT" | grep "Requests/sec" | awk '{print $2}')
        LAT_AVG=$(echo "$OUTPUT" | grep "Latency" | awk '{print $2}')
        LAT_50=$(echo "$OUTPUT" | sed -n '/Latency Distribution/,/^$/p' | grep "50%" | awk '{print $2}')
        LAT_99=$(echo "$OUTPUT" | sed -n '/Latency Distribution/,/^$/p' | grep "99%" | awk '{print $2}')

        echo "$C,$RPS,$LAT_AVG,$LAT_50,$LAT_99" >> "$csv"
        echo "${RPS} req/s, avg=${LAT_AVG}, p99=${LAT_99:-n/a}"

        echo "$OUTPUT" > "$RESULTS/${name}_wrk_c${C}.txt"
    done
}

for SERVER in "${SERVERS[@]}"; do
    echo ""
    echo "=== Benchmarking: $SERVER ==="

    case $SERVER in
        snek)    start_snek ;;
        go)      start_go ;;
        rust)    start_rust ;;
        fastapi) start_fastapi ;;
    esac

    sleep "$WARMUP"

    # Verify server is up
    if ! curl -s "http://127.0.0.1:$PORT/" > /dev/null 2>&1; then
        echo "  SKIP: $SERVER failed to start"
        stop_server
        continue
    fi

    run_benchmark "$SERVER"

    # Flamegraph for this server
    echo -n "  flamegraph ... "
    if perf record -F 999 -g -p $SERVER_PID -o "$RESULTS/${SERVER}_perf.data" -- sleep 10 2>/dev/null; then
        wrk -t4 -c50 -d9s "http://127.0.0.1:$PORT/" > /dev/null 2>&1 &
        wait
        perf script -i "$RESULTS/${SERVER}_perf.data" 2>/dev/null \
            | /opt/FlameGraph/stackcollapse-perf.pl 2>/dev/null \
            | /opt/FlameGraph/flamegraph.pl > "$RESULTS/${SERVER}_flamegraph.svg" 2>/dev/null \
            && echo "saved" || echo "failed"
    else
        echo "perf not available"
    fi

    stop_server
done

# --- Summary ---
echo ""
echo "=== Summary: req/s at each concurrency level ==="
echo ""
printf "%-12s" "concurrency"
for SERVER in "${SERVERS[@]}"; do
    printf "%-15s" "$SERVER"
done
echo ""

for C in $CONCURRENCY_LEVELS; do
    printf "%-12s" "$C"
    for SERVER in "${SERVERS[@]}"; do
        CSV="$RESULTS/${SERVER}_curve.csv"
        if [ -f "$CSV" ]; then
            RPS=$(grep "^$C," "$CSV" | cut -d',' -f2)
            printf "%-15s" "${RPS:-n/a}"
        else
            printf "%-15s" "n/a"
        fi
    done
    echo ""
done

echo ""
echo "Results in $RESULTS/"
ls "$RESULTS/"*.csv "$RESULTS/"*.svg 2>/dev/null
