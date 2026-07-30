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

# Checkpoints start close together and widen. Early on there is little compiled
# output, so a checkpoint is cheap and protects work that would otherwise be
# wholly unprotected; later checkpoints are deltas, so a wider spacing keeps the
# pause overhead down without ever risking more than MAX_CHECKPOINT_SECONDS.
readonly FIRST_CHECKPOINT_SECONDS="${FIRST_CHECKPOINT_SECONDS:-300}"
readonly MAX_CHECKPOINT_SECONDS="${MAX_CHECKPOINT_SECONDS:-900}"
readonly MAX_PASSES="${MAX_PASSES:-80}"
readonly POLL_SECONDS=15
# Measured: a pause plus delta upload costs about a minute, so checkpointing every
# 15 minutes trades ~7% of build time for a 15-minute worst case on a hard kill.
readonly HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-300}"
# Ninja prints a line per edge, which for ~100k edges overruns the log limits and
# leaves the Actions UI hours behind. Progress is thinned to one line per interval;
# diagnostics still come through in full.
readonly PROGRESS_INTERVAL_SECONDS="${PROGRESS_INTERVAL_SECONDS:-10}"
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

checkpoint_interval_for_pass() {
  local pass="$1" interval="$FIRST_CHECKPOINT_SECONDS"
  while [ "$pass" -gt 1 ] && [ "$interval" -lt "$MAX_CHECKPOINT_SECONDS" ]; do
    interval=$(( interval * 2 ))
    pass=$(( pass - 1 ))
  done
  if [ "$interval" -gt "$MAX_CHECKPOINT_SECONDS" ]; then
    interval="$MAX_CHECKPOINT_SECONDS"
  fi
  printf '%s' "$interval"
}

# Every edge ninja has ever completed in this build dir, across passes and runs.
edges_completed() {
  local log="${OUT_DIR:-src/out/Release}/.ninja_log"
  if [ -f "$log" ]; then
    wc -l < "$log" | tr -d ' '
  else
    echo 0
  fi
}

# Runs one pass, returning PAUSED_RC if the time budget expired first.
run_pass() {
  local budget="$1" pid deadline rc_file build_rc
  # The throttler is the tail of a pipeline, so the build's own status has to
  # travel out of band.
  rc_file="$(mktemp)"
  # Job control gives the pass its own process group, so the signal below
  # reaches ninja and its compiler children rather than just the `e` wrapper.
  set -m
  { CI=1 GN_EXTRA_ARGS="$(gn_extra_args)" e build --no-remote 2>&1; echo $? > "$rc_file"; } \
    | python3 "$SCRIPT_DIR/throttle-build-output.py" "$PROGRESS_INTERVAL_SECONDS" &
  pid=$!
  set +m

  deadline=$(( SECONDS + budget ))
  local next_heartbeat=$(( SECONDS + HEARTBEAT_SECONDS ))
  while kill -0 "$pid" 2>/dev/null; do
    # Ninja's own progress counter resets every pass and GitHub stops streaming
    # long-running step output, so report cumulative progress on our own clock.
    if (( SECONDS >= next_heartbeat )); then
      echo "still compiling: $(edges_completed) edges done, $(( (deadline - SECONDS) / 60 ))m until the next checkpoint"
      next_heartbeat=$(( SECONDS + HEARTBEAT_SECONDS ))
    fi
    if (( SECONDS >= deadline )); then
      echo "pass reached its ${budget}s budget; pausing ninja to checkpoint"
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      # Ninja sometimes ignores TERM while compiler children finish; a blocking
      # wait here has hung the job for 30+ minutes with no further log output.
      local term_deadline=$(( SECONDS + 120 ))
      while kill -0 "$pid" 2>/dev/null; do
        if (( SECONDS >= term_deadline )); then
          echo "ninja did not exit after TERM; sending KILL"
          kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
          break
        fi
        sleep 2
      done
      wait "$pid" 2>/dev/null || true
      rm -f "$rc_file"
      return "$PAUSED_RC"
    fi
    sleep "$POLL_SECONDS"
  done

  wait "$pid" 2>/dev/null || true
  # An empty file means the build died without recording a status, which is a
  # failure however the pipeline itself exited.
  build_rc="$(cat "$rc_file" 2>/dev/null)"
  rm -f "$rc_file"
  return "${build_rc:-1}"
}

"$SCRIPT_DIR/out-cache.sh" restore

rc=0
for pass in $(seq 1 "$MAX_PASSES"); do
  budget=$(checkpoint_interval_for_pass "$pass")
  # Deliberately not a ::group::; collapsed groups stop streaming in the UI, which
  # made a healthy multi-hour compile look frozen.
  echo "=== build pass ${pass}/${MAX_PASSES}: $(edges_completed) edges done, checkpoint after ${budget}s ==="
  run_pass "$budget"
  rc=$?

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
