#!/usr/bin/env bash
# snek profiling suite — run inside Docker with --privileged
#
# Usage: docker run --privileged --rm -v $PWD/results:/results snek-profile
#
set -euo pipefail

RESULTS="/results"
mkdir -p "$RESULTS"

APP_PORT=8080
CONCURRENCY_LEVELS="1 10 50 100 200 500"
DURATION=10

export PYTHONPATH=/snek/python
echo "=== snek profiling suite ==="
echo "Date: $(date)"
echo "Kernel: $(uname -r)"
echo "CPUs: $(nproc)"
echo ""

start_server() {
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

app.run(port=$APP_PORT)
" &
    SERVER_PID=$!
    sleep 3
}

stop_server() {
    kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null || true
    sleep 1
}

# --- Phase 1: Load curve ---
echo "=== Phase 1: Load curve (wrk, ${DURATION}s per level) ==="
start_server

echo "concurrency,rps,avg_latency_us,transfer_per_sec" > "$RESULTS/load_curve.csv"

for C in $CONCURRENCY_LEVELS; do
    echo -n "  c=$C ... "
    OUTPUT=$(wrk -t"$(( C < $(nproc) ? C : $(nproc) ))" -c"$C" -d"${DURATION}s" \
        --latency "http://127.0.0.1:$APP_PORT/" 2>&1)

    RPS=$(echo "$OUTPUT" | grep "Requests/sec" | awk '{print $2}')
    LATENCY=$(echo "$OUTPUT" | grep "Latency" | awk '{print $2}')
    TRANSFER=$(echo "$OUTPUT" | grep "Transfer/sec" | awk '{print $2}')

    echo "$C,$RPS,$LATENCY,$TRANSFER" >> "$RESULTS/load_curve.csv"
    echo "${RPS} req/s, latency=${LATENCY}"

    echo "$OUTPUT" > "$RESULTS/wrk_c${C}.txt"
done

stop_server

# --- Phase 2: Flamegraph ---
echo ""
echo "=== Phase 2: Flamegraph (perf record under load) ==="
start_server

if perf record -F 999 -g -p $SERVER_PID -o "$RESULTS/perf.data" -- sleep 15 &
then
    PERF_PID=$!
    wrk -t4 -c50 -d14s "http://127.0.0.1:$APP_PORT/" > /dev/null 2>&1
    wait $PERF_PID 2>/dev/null || true

    perf script -i "$RESULTS/perf.data" > "$RESULTS/perf.script" 2>/dev/null || true
    /opt/FlameGraph/stackcollapse-perf.pl "$RESULTS/perf.script" > "$RESULTS/perf.folded" 2>/dev/null || true
    /opt/FlameGraph/flamegraph.pl "$RESULTS/perf.folded" > "$RESULTS/flamegraph.svg" 2>/dev/null || true

    [ -f "$RESULTS/flamegraph.svg" ] && echo "  Flamegraph: results/flamegraph.svg" || echo "  Flamegraph failed"
else
    echo "  perf not available, skipping"
fi

stop_server

# --- Phase 3: Callgrind ---
echo ""
echo "=== Phase 3: Callgrind (instruction-level, light load) ==="
valgrind --tool=callgrind --callgrind-out-file="$RESULTS/callgrind.out" \
    python3 -c "
from snek import App
app = App()

@app.get('/')
def hello(request):
    return {'message': 'hello'}

app.run(port=$APP_PORT)
" &
VALGRIND_PID=$!
sleep 10

wrk -t2 -c10 -d5s "http://127.0.0.1:$APP_PORT/" > "$RESULTS/wrk_callgrind.txt" 2>&1 || true
echo "  wrk under callgrind: $(grep 'Requests/sec' "$RESULTS/wrk_callgrind.txt" 2>/dev/null || echo 'n/a')"

kill $VALGRIND_PID 2>/dev/null; wait $VALGRIND_PID 2>/dev/null || true

[ -f "$RESULTS/callgrind.out" ] && echo "  Callgrind: results/callgrind.out" || echo "  Callgrind failed"

# --- Phase 4: Cachegrind ---
echo ""
echo "=== Phase 4: Cachegrind (cache miss analysis) ==="
valgrind --tool=cachegrind --cachegrind-out-file="$RESULTS/cachegrind.out" \
    python3 -c "
from snek import App
app = App()

@app.get('/')
def hello(request):
    return {'message': 'hello'}

app.run(port=$APP_PORT)
" &
VALGRIND_PID=$!
sleep 10

wrk -t1 -c5 -d3s "http://127.0.0.1:$APP_PORT/" > /dev/null 2>&1 || true

kill $VALGRIND_PID 2>/dev/null; wait $VALGRIND_PID 2>/dev/null || true

if [ -f "$RESULTS/cachegrind.out" ]; then
    cg_annotate "$RESULTS/cachegrind.out" 2>/dev/null | head -50 > "$RESULTS/cachegrind_summary.txt" || true
    echo "  Cachegrind: results/cachegrind_summary.txt"
else
    echo "  Cachegrind failed"
fi

echo ""
echo "=== Done ==="
cat "$RESULTS/load_curve.csv"
echo ""
ls -la "$RESULTS/"
