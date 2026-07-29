#!/usr/bin/env bash
# Compile Electron in timed passes, snapshotting out/Release to S3 between them.
#
# Ninja resumes cleanly after an interrupt, so pausing it on a schedule turns one
# unrecoverable multi-hour compile into a series of checkpoints: a crash, a red
# target, or a job timeout replays only the work since the last snapshot.
#
# Env: ELECTRON_VERSION (required), GN_CC_WRAPPER, SNAPSHOT_INTERVAL_SECONDS,
#      MAX_PASSES, plus everything out-cache.sh needs.
set -uo pipefail

: "${ELECTRON_VERSION:?ELECTRON_VERSION is required}"

readonly SNAPSHOT_INTERVAL_SECONDS="${SNAPSHOT_INTERVAL_SECONDS:-4500}"
readonly MAX_PASSES="${MAX_PASSES:-8}"
readonly POLL_SECONDS=15
readonly PAUSED_RC=124
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

snapshot() {
  "$SCRIPT_DIR/out-cache.sh" save || echo "snapshot failed; continuing anyway"
}

gn_extra_args() {
  # override_electron_version makes the produced zip/npm version ours, not the
  # upstream tag the branch was cut from.
  local args="override_electron_version=\"${ELECTRON_VERSION}\""
  if [ -n "${GN_CC_WRAPPER:-}" ]; then
    args="$args cc_wrapper=\"${GN_CC_WRAPPER}\""
  fi
  printf '%s' "$args"
}

# Runs one pass, returning PAUSED_RC if the time budget expired first.
run_pass() {
  local pid deadline
  # Job control gives the pass its own process group, so the signal below
  # reaches ninja and its compiler children rather than just the `e` wrapper.
  set -m
  CI=1 GN_EXTRA_ARGS="$(gn_extra_args)" e build --no-remote &
  pid=$!
  set +m

  deadline=$(( SECONDS + SNAPSHOT_INTERVAL_SECONDS ))
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      echo "pass reached its ${SNAPSHOT_INTERVAL_SECONDS}s budget; pausing ninja to checkpoint"
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return "$PAUSED_RC"
    fi
    sleep "$POLL_SECONDS"
  done

  wait "$pid"
}

"$SCRIPT_DIR/out-cache.sh" restore

rc=0
for pass in $(seq 1 "$MAX_PASSES"); do
  echo "::group::build pass ${pass}/${MAX_PASSES}"
  run_pass
  rc=$?
  echo "::endgroup::"

  snapshot

  if [ "$rc" -eq 0 ]; then
    echo "build complete"
    break
  fi
  if [ "$rc" -ne "$PAUSED_RC" ]; then
    echo "build failed (exit $rc); progress up to this point is snapshotted, re-run to resume"
    break
  fi
done

if [ "$rc" -eq "$PAUSED_RC" ]; then
  echo "still compiling after $MAX_PASSES passes; re-run the workflow to continue from the snapshot"
fi

exit "$rc"
