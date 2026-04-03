#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <scenario-module> [path]" >&2
    echo "example: $0 hello_min" >&2
    echo "example: CONCURRENCY=512 THREADS=7 $0 db_param_one" >&2
    exit 1
fi

SCENARIO="$1"
PATH_SUFFIX="${2:-/}"

PROJECT="${PROJECT:-compose}"
COMPOSE_FILE="${COMPOSE_FILE:-bench/compose/docker-compose.yml}"
THREADS="${THREADS:-1}"
CONCURRENCY="${CONCURRENCY:-256}"
DURATION="${DURATION:-10s}"
PORT="${PORT:-8080}"
STARTUP_TIMEOUT_S="${STARTUP_TIMEOUT_S:-30}"
TARGET_SERVICE="${TARGET_SERVICE:-bench}"

SCENARIO_FILE="bench/scenarios/${SCENARIO}.py"
if [[ ! -f "$SCENARIO_FILE" ]]; then
    echo "scenario not found: $SCENARIO_FILE" >&2
    exit 1
fi

compose() {
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"
}

echo "==> starting compose services"
compose up -d postgres bench >/dev/null

echo "==> waiting for postgres"
until compose exec -T postgres pg_isready -U snek >/dev/null 2>&1; do
    sleep 1
done

echo "==> restarting bench service for a clean app process"
compose restart bench >/dev/null

APP_LOG="/tmp/${SCENARIO}.log"

echo "==> starting scenario ${SCENARIO} (threads=${THREADS})"
compose exec -T bench sh -lc "cd /bench/scenarios && nohup env PYTHONPATH=/bench/snek_root:/bench/scenarios python3 -c 'import ${SCENARIO}; ${SCENARIO}.app.run(host=\"0.0.0.0\", port=${PORT}, threads=${THREADS}, module_ref=\"${SCENARIO}:app\")' >${APP_LOG} 2>&1 &"

echo "==> waiting for app readiness"
deadline=$((SECONDS + STARTUP_TIMEOUT_S))
until compose exec -T bench python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:${PORT}${PATH_SUFFIX}', timeout=2).status)"; do
    if (( SECONDS >= deadline )); then
        echo "app failed to start; recent log follows:" >&2
        compose exec -T bench sh -lc "tail -100 ${APP_LOG} || true" >&2
        exit 1
    fi
    sleep 0.2
done

echo "==> running oha from a separate loadgen container on ${PROJECT}_default"
docker run --rm --network "${PROJECT}_default" "${PROJECT}-bench" \
    oha --no-tui -z "${DURATION}" -c "${CONCURRENCY}" "http://${TARGET_SERVICE}:${PORT}${PATH_SUFFIX}"

echo "==> app log: ${APP_LOG}"
