#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/checkpoint-trigger.sh"

assert_trigger() {
  local expected="$1" start_edges="$2" current_edges="$3" elapsed="$4"
  local actual
  actual=$(checkpoint_trigger "$start_edges" "$current_edges" "$elapsed" 1000 900)
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: expected '$expected', got '$actual' for start=$start_edges current=$current_edges elapsed=$elapsed"
    exit 1
  fi
}

assert_trigger none 10000 10999 899
assert_trigger edges 10000 11000 899
assert_trigger time 10000 10999 900
# Coinciding thresholds must produce one combined trigger, not two events.
assert_trigger edges+time 10000 11000 900

echo "PASS: checkpoint trigger is single-shot at edges/time coincidence"
