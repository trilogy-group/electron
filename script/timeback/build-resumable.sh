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

# End each pass after 2,500 new unique outputs or 15 minutes, whichever happens
# first. One pass termination always produces exactly one checkpoint.
readonly CHECKPOINT_EDGE_INTERVAL="${CHECKPOINT_EDGE_INTERVAL:-2500}"
readonly MAX_CHECKPOINT_SECONDS="${MAX_CHECKPOINT_SECONDS:-900}"
readonly MAX_PASSES="${MAX_PASSES:-100}"
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
source "$SCRIPT_DIR/checkpoint-trigger.sh"

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
  local budget="$1" pid deadline rc_file build_rc start_seconds start_edges
  local current_edges trigger
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

  start_seconds=$SECONDS
  start_edges=$(edges_completed)
  deadline=$(( start_seconds + budget ))
  local next_heartbeat=$(( SECONDS + HEARTBEAT_SECONDS ))
  while kill -0 "$pid" 2>/dev/null; do
    # Ninja's own progress counter resets every pass and GitHub stops streaming
    # long-running step output, so report cumulative progress on our own clock.
    if (( SECONDS >= next_heartbeat )); then
      echo "still compiling: $(edges_completed) edges done, $(( (deadline - SECONDS) / 60 ))m until the next checkpoint"
      next_heartbeat=$(( SECONDS + HEARTBEAT_SECONDS ))
    fi
    current_edges=$(edges_completed)
    trigger=$(checkpoint_trigger \
      "$start_edges" "$current_edges" "$(( SECONDS - start_seconds ))" \
      "$CHECKPOINT_EDGE_INTERVAL" "$budget")
    if [ "$trigger" != none ]; then
      echo "checkpoint trigger=$trigger: $(( current_edges - start_edges )) new edges, $(( SECONDS - start_seconds ))s elapsed"
      echo "pausing ninja for one checkpoint"
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

if [ "$USE_OUT_CACHE" = "true" ] && [ -f "${OUT_DIR:-src/out/Release}/.ninja_log" ]; then
  GN_EXTRA_ARGS="$(gn_extra_args)" "$SCRIPT_DIR/verify-out-cache.sh"
fi

rc=0
for pass in $(seq 1 "$MAX_PASSES"); do
  budget="$MAX_CHECKPOINT_SECONDS"
  # Deliberately not a ::group::; collapsed groups stop streaming in the UI, which
  # made a healthy multi-hour compile look frozen.
  echo "=== build pass ${pass}/${MAX_PASSES}: $(edges_completed) edges done; checkpoint after ${CHECKPOINT_EDGE_INTERVAL} new edges or ${budget}s ==="
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
