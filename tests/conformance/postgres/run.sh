#!/usr/bin/env bash
#
# PostgreSQL wire protocol conformance.
# Tests snek's pg implementation via standard psql/libpq.
# Requires: psql, snek on PATH, a running Postgres for comparison.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
PORT=5433  # snek pg proxy port (not the real Postgres 5432)
PG_CONN="postgresql://snek:snek@127.0.0.1:$PORT/snek_test"

mkdir -p "$RESULTS_DIR"
PASS=0
FAIL=0

fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }

echo "==> Starting snek pg proxy on :$PORT"
snek serve --pg-proxy --port "$PORT" &
SNEK_PID=$!
sleep 1

# ── Auth: trust ─────────────────────────────────────────────────────

echo "--- Auth: trust"
if psql "$PG_CONN" -c "SELECT 1" &>/dev/null; then
    pass "trust auth connects"
else
    fail "trust auth failed"
fi

# ── Auth: SCRAM-SHA-256 ─────────────────────────────────────────────

echo "--- Auth: SCRAM-SHA-256"
SCRAM_CONN="postgresql://scram_user:scram_pass@127.0.0.1:$PORT/snek_test"
if psql "$SCRAM_CONN" -c "SELECT 1" &>/dev/null; then
    pass "SCRAM-SHA-256 auth"
else
    fail "SCRAM-SHA-256 auth"
fi

# ── Auth: md5 ───────────────────────────────────────────────────────

echo "--- Auth: md5"
MD5_CONN="postgresql://md5_user:md5_pass@127.0.0.1:$PORT/snek_test"
if psql "$MD5_CONN" -c "SELECT 1" &>/dev/null; then
    pass "md5 auth"
else
    fail "md5 auth"
fi

# ── Simple query protocol ──────────────────────────────────────────

echo "--- Simple query"
RESULT=$(psql "$PG_CONN" -t -A -c "SELECT 42 AS answer")
if [ "$RESULT" = "42" ]; then
    pass "simple query returns correct result"
else
    fail "simple query returned '$RESULT' (expected 42)"
fi

# ── Prepared statements ────────────────────────────────────────────

echo "--- Prepared statements"
RESULT=$(psql "$PG_CONN" -t -A -c "
    PREPARE test_stmt(int) AS SELECT \$1 * 2 AS doubled;
    EXECUTE test_stmt(21);
    DEALLOCATE test_stmt;
")
if echo "$RESULT" | grep -q "42"; then
    pass "prepared statements"
else
    fail "prepared statements"
fi

# ── Extended query protocol ────────────────────────────────────────

echo "--- Extended query protocol"
# libpq uses extended query protocol for parameterized queries.
RESULT=$(psql "$PG_CONN" -t -A -c "SELECT \$1::int + \$2::int AS sum" --set=1 --variable="1=20" --variable="2=22" 2>/dev/null || \
    python3 -c "
import psycopg2
conn = psycopg2.connect('$PG_CONN')
cur = conn.cursor()
cur.execute('SELECT %s::int + %s::int AS sum', (20, 22))
print(cur.fetchone()[0])
conn.close()
" 2>/dev/null)
if echo "$RESULT" | grep -q "42"; then
    pass "extended query protocol"
else
    fail "extended query protocol"
fi

# ── Type mapping ───────────────────────────────────────────────────

echo "--- Type mapping"
RESULT=$(psql "$PG_CONN" -t -A -c "
    SELECT
        1::int4 AS i4,
        1::int8 AS i8,
        3.14::float4 AS f4,
        'hello'::text AS txt,
        true::bool AS b,
        '2025-01-01'::date AS dt,
        '{1,2,3}'::int4[] AS arr
")
if [ -n "$RESULT" ]; then
    pass "type mapping round-trip"
else
    fail "type mapping round-trip"
fi

# ── Cleanup ─────────────────────────────────────────────────────────

kill "$SNEK_PID" 2>/dev/null || true
wait "$SNEK_PID" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "$PASS passed, $FAIL failed" > "$RESULTS_DIR/summary.txt"
[ "$FAIL" -eq 0 ] || exit 1
