#!/usr/bin/env bash
# Compile Electron in timed passes, snapshotting out/Release to S3 between them.
#
# Ninja resumes cleanly after an interrupt, so pausing it on a schedule turns one
# unrecoverable multi-hour compile into a series of checkpoints: a crash, a red
# target, or a job timeout replays only the work since the last snapshot.
#
# Env: ELECTRON_VERSION (required), GN_CC_WRAPPER, SNAPSHOT_INTERVAL_SECONDS,
#      MAX_PASSES, NINJA_J (optional; forwarded as `e build -j N`), plus
#      everything out-cache.sh needs.
set -uo pipefail

: "${ELECTRON_VERSION:?ELECTRON_VERSION is required}"

# Checkpoints start close together and widen. Early on there is little compiled
# output, so a checkpoint is cheap and protects work that would otherwise be
# wholly unprotected; later checkpoints are deltas, so a wider spacing keeps the
# pause overhead down without ever risking more than MAX_CHECKPOINT_SECONDS.
# Checkpoints: first at 10m, then widen up to 20m so a 6h hard kill loses at
# most one interval of compile (upload pause is ~1m).
readonly FIRST_CHECKPOINT_SECONDS="${FIRST_CHECKPOINT_SECONDS:-600}"
readonly MAX_CHECKPOINT_SECONDS="${MAX_CHECKPOINT_SECONDS:-1200}"
readonly MAX_PASSES="${MAX_PASSES:-80}"
readonly POLL_SECONDS=15
readonly HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-300}"
readonly PROGRESS_INTERVAL_SECONDS="${PROGRESS_INTERVAL_SECONDS:-10}"
readonly PAUSED_RC=124
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

snapshot() {
  "$SCRIPT_DIR/out-cache.sh" save || echo "snapshot failed; continuing anyway"
}

gn_extra_args() {
  # override_electron_version stamps our npm/release version.
  # Do NOT set symbol_level=0 — TimeBack crash reports need symbolication.
  # chrome_pgo_phase=0 skips PGO only (see build.sh).
  local args="override_electron_version=\"${ELECTRON_VERSION}\" chrome_pgo_phase=0"
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

# Left unset, ninja picks its own parallelism (cores + 2). NINJA_J overrides that,
# which is how the 32-vCPU Windows box gets oversubscribed. macOS bash is 3.2, where
# expanding an empty array under `set -u` is an error, so branch on the variable
# instead of building an args array.
run_build() {
  if [ -n "${NINJA_J:-}" ]; then
    CI=1 GN_EXTRA_ARGS="$(gn_extra_args)" e build --no-remote -j "$NINJA_J" 2>&1
  else
    CI=1 GN_EXTRA_ARGS="$(gn_extra_args)" e build --no-remote 2>&1
  fi
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
  { run_build; echo $? > "$rc_file"; } \
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

# Build duration is dominated by how many cores this box actually has, so record the
# parallelism in the log — otherwise a slow build is indistinguishable from a
# misconfigured one.
if command -v nproc >/dev/null 2>&1; then
  cores="$(nproc)"
else
  cores="$(sysctl -n hw.ncpu 2>/dev/null || echo unknown)"
fi
if [ -n "${NINJA_J:-}" ]; then
  echo "ninja parallelism: -j ${NINJA_J} (host reports ${cores} cores)"
else
  echo "ninja parallelism: ninja default, normally cores+2 (host reports ${cores} cores)"
fi

"$SCRIPT_DIR/out-cache.sh" restore

# Resume order matters:
#   1) restore objects (S3 mtimes are older than src-cache extract "now")
#   2) gn gen (rewrites build.ninja / xcode_links / some gen/ headers)
#   3) touch *.o/*.a only AFTER gen — otherwise freshly rewritten gen/ inputs
#      are newer than every object and ninja schedules a full ~80k rebuild
#      despite a 76G restore (seen as [~600/77655] after HIT).
if [ -d "${OUT_DIR:-src/out/Release}" ] && [ "${USE_OUT_CACHE:-true}" = "true" ]; then
  if [ -n "$(find "${OUT_DIR:-src/out/Release}" -type f -name '*.o' -print -quit 2>/dev/null)" ]; then
    echo "=== resume prep: gn gen only, then touch compile outputs ==="
    CI=1 GN_EXTRA_ARGS="$(gn_extra_args)" e build --no-remote --gen only
    "$SCRIPT_DIR/out-cache.sh" touch-outputs
  fi
fi

rc=0
for pass in $(seq 1 "$MAX_PASSES"); do
  budget=$(checkpoint_interval_for_pass "$pass")
  # Deliberately not a ::group::; collapsed groups stop streaming in the UI, which
  # made a healthy multi-hour compile look frozen.
  echo "=== build pass ${pass}/${MAX_PASSES}: $(edges_completed) edges recorded in .ninja_log, checkpoint after ${budget}s ==="
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
