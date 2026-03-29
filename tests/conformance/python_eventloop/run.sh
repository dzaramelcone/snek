#!/usr/bin/env bash
#
# Python event-loop conformance tests.
# Uses upstream uvloop and CPython test bodies adapted to the planned
# snek.loop API surface.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
VENV_DIR="$SCRIPT_DIR/.venv"

mkdir -p "$RESULTS_DIR"

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"

python -m pip install --quiet --upgrade pip setuptools wheel
python -m pip install --quiet -e "$ROOT_DIR"

set +e
python -m unittest discover -s "$SCRIPT_DIR" -p 'test_*.py' \
    2>&1 | tee "$RESULTS_DIR/unittest.txt"
STATUS=${PIPESTATUS[0]}
set -e

if [ "$STATUS" -eq 0 ]; then
    echo "all tests passed" > "$RESULTS_DIR/summary.txt"
else
    echo "test failures present" > "$RESULTS_DIR/summary.txt"
fi

exit "$STATUS"
