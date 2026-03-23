#!/usr/bin/env bash
# snek vs controls: same workload, same machine, side by side
set -uo pipefail

RESULTS="/results"
mkdir -p "$RESULTS"
PORT=8080
DURATION=10
CONCURRENCY_LEVELS="1 10 50 100 200 500"
export PYTHONPATH=/snek/python

start() {
    case $1 in
        snek)
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
" &;;
        go)       bench-go $PORT &;;
        rust)     bench-rust $PORT &;;
        fastapi)  cd /snek/bench/controls/fastapi && uvicorn app:app --host 0.0.0.0 --port $PORT --workers 4 --log-level error &;;
    esac
    SERVER_PID=$!
    sleep 3
}

stop() {
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null || true
    sleep 1
}

bench_one() {
    local name=$1
    local csv="$RESULTS/${name}.csv"
    echo "concurrency,rps,latency_avg,p50,p99" > "$csv"

    for C in $CONCURRENCY_LEVELS; do
        local t=$(( C < $(nproc) ? C : $(nproc) ))
        OUT=$(wrk -t"$t" -c"$C" -d"${DURATION}s" --latency "http://127.0.0.1:$PORT/" 2>&1)
        RPS=$(echo "$OUT" | grep "Requests/sec" | awk '{print $2}')
        AVG=$(echo "$OUT" | grep "Latency" | head -1 | awk '{print $2}')
        P50=$(echo "$OUT" | sed -n '/Latency Distribution/,/^$/p' | grep "50%" | awk '{print $2}')
        P99=$(echo "$OUT" | sed -n '/Latency Distribution/,/^$/p' | grep "99%" | awk '{print $2}')
        echo "$C,$RPS,$AVG,$P50,$P99" >> "$csv"
        printf "    c=%-4s %10s req/s  p50=%-10s p99=%s\n" "$C" "$RPS" "$P50" "$P99"
        echo "$OUT" > "$RESULTS/${name}_c${C}.txt"
    done
}

echo "=== snek vs controls ==="
echo "$(date) | $(uname -r) | $(nproc) CPUs"
echo ""

for SERVER in snek go rust fastapi; do
    echo "--- $SERVER ---"
    start "$SERVER"

    if ! curl -s "http://127.0.0.1:$PORT/" > /dev/null 2>&1; then
        echo "    SKIP: failed to start"
        stop; continue
    fi

    bench_one "$SERVER"
    stop
done

# Summary table
echo ""
echo "=== Summary (req/s) ==="
printf "%-6s" "c"
for s in snek go rust fastapi; do printf "%12s" "$s"; done
echo ""

for C in $CONCURRENCY_LEVELS; do
    printf "%-6s" "$C"
    for s in snek go rust fastapi; do
        RPS=$(grep "^$C," "$RESULTS/${s}.csv" 2>/dev/null | cut -d, -f2)
        printf "%12s" "${RPS:-n/a}"
    done
    echo ""
done
