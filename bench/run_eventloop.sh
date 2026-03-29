#!/usr/bin/env bash
#
# Run event-loop benchmarks:
#   1. in-process loop microbenchmarks
#   2. oha HTTP benchmarks for async route chains
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$RESULTS_DIR/eventloop_$TIMESTAMP"
VENV_DIR="$SCRIPT_DIR/.venv-eventloop"
PYTHON_BIN="$VENV_DIR/bin/python"

MICRO_REPEATS="${EVENTLOOP_MICRO_REPEATS:-5}"
MICRO_WARMUP="${EVENTLOOP_MICRO_WARMUP:-1}"
MICRO_CALLBACKS="${EVENTLOOP_MICRO_CALLBACKS:-100000}"
MICRO_TIMERS="${EVENTLOOP_MICRO_TIMERS:-50000}"
MICRO_YIELDS="${EVENTLOOP_MICRO_YIELDS:-100000}"
MICRO_TASKS="${EVENTLOOP_MICRO_TASKS:-10000}"
MICRO_PROVIDERS="${EVENTLOOP_MICRO_PROVIDERS:-snek,uvloop,asyncio}"

HTTP_DURATION="${EVENTLOOP_HTTP_DURATION:-15s}"
HTTP_CONNECTIONS="${EVENTLOOP_HTTP_CONNECTIONS:-256}"
HTTP_PORT="${EVENTLOOP_HTTP_PORT:-9081}"
HTTP_PROVIDERS="${EVENTLOOP_HTTP_PROVIDERS:-snek,uvloop,asyncio}"

ECHO_DURATION="${EVENTLOOP_ECHO_DURATION:-5s}"
ECHO_CONNECTIONS="${EVENTLOOP_ECHO_CONNECTIONS:-32}"
ECHO_PORT="${EVENTLOOP_ECHO_PORT:-9098}"
ECHO_PROVIDERS="${EVENTLOOP_ECHO_PROVIDERS:-uvloop,asyncio}"
ECHO_MODES="${EVENTLOOP_ECHO_MODES:-streams,protocol,sockets}"
ECHO_MESSAGE_SIZES="${EVENTLOOP_ECHO_MESSAGE_SIZES:-64,1024,16384}"

mkdir -p "$RUN_DIR"

if [ ! -x "$PYTHON_BIN" ]; then
  python3 -m venv "$VENV_DIR"
fi

"$PYTHON_BIN" -m pip install -U pip setuptools wheel >/dev/null
if ! "$PYTHON_BIN" -c 'import uvloop' >/dev/null 2>&1; then
  "$PYTHON_BIN" -m pip install uvloop >/dev/null
fi

zig build pyext -Doptimize=ReleaseFast >/dev/null

ext_suffix="$("$PYTHON_BIN" - <<'PY'
import sysconfig
print(sysconfig.get_config_var("EXT_SUFFIX"))
PY
)"

lib_snek=""
for candidate in "$ROOT_DIR/zig-out/lib/lib_snek.dylib" "$ROOT_DIR/zig-out/lib/lib_snek.so"; do
  if [ -f "$candidate" ]; then
    lib_snek="$candidate"
    break
  fi
done

if [ -z "$lib_snek" ]; then
  echo "failed to find built lib_snek shared library" >&2
  exit 1
fi

cp "$lib_snek" "$ROOT_DIR/python/snek/_snek$ext_suffix"

echo "==> Event-loop microbench"
"$PYTHON_BIN" "$SCRIPT_DIR/eventloop_microbench.py" \
  --repeats "$MICRO_REPEATS" \
  --warmup "$MICRO_WARMUP" \
  --callbacks "$MICRO_CALLBACKS" \
  --timers "$MICRO_TIMERS" \
  --yields "$MICRO_YIELDS" \
  --tasks "$MICRO_TASKS" \
  --providers "$MICRO_PROVIDERS" \
  --json-out "$RUN_DIR/microbench.json"

if command -v oha >/dev/null 2>&1; then
  echo ""
  echo "==> Event-loop HTTP bench (oha)"
  "$PYTHON_BIN" "$SCRIPT_DIR/eventloop_http_bench.py" \
    --duration "$HTTP_DURATION" \
    --connections "$HTTP_CONNECTIONS" \
    --port "$HTTP_PORT" \
    --providers "$HTTP_PROVIDERS" \
    --raw-dir "$RUN_DIR/oha_raw" \
    --json-out "$RUN_DIR/oha_summary.json"
else
  echo ""
  echo "==> oha not found; skipping HTTP benchmark"
fi

echo ""
echo "==> Event-loop echo bench"
"$PYTHON_BIN" "$SCRIPT_DIR/eventloop_echo_bench.py" \
  --duration "$ECHO_DURATION" \
  --connections "$ECHO_CONNECTIONS" \
  --port "$ECHO_PORT" \
  --providers "$ECHO_PROVIDERS" \
  --modes "$ECHO_MODES" \
  --message-sizes "$ECHO_MESSAGE_SIZES" \
  --raw-dir "$RUN_DIR/echo_raw" \
  --json-out "$RUN_DIR/echo_summary.json"

ln -sfn "$RUN_DIR" "$RESULTS_DIR/eventloop_latest"

echo ""
echo "==> Results written to $RUN_DIR"
