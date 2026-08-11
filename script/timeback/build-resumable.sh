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

# Resume after an S3 out-cache restore:
#   1) Clamp sources older than restored objects (tar extract mtimes = now).
#   2) Restore each output's mtime from .ninja_deps (s3 sync / touch make
#      objects newer than the deps log → ninja invalidates every edge).
#   3) Recreate xcode_links if needed; never touch *.o afterward.
#   4) Fail fast if ninja -n still looks like a full rebuild.
if [ -d src ]; then
  bash "$SCRIPT_DIR/clamp-src-mtimes.sh" src
fi

"$SCRIPT_DIR/out-cache.sh" restore

readonly RESUME_DRY_RUN_MAX="${RESUME_DRY_RUN_MAX:-35000}"
readonly OUT="${OUT_DIR:-src/out/Release}"
if [ -d "$OUT" ] && [ "${USE_OUT_CACHE:-true}" = "true" ]; then
  if [ -n "$(find "$OUT" -type f -name '*.o' -print -quit 2>/dev/null)" ]; then
    echo "=== resume prep: deps mtimes, xcode_links, dry-run gate ==="

    # Generated headers under out/ also arrive with S3 LastModified; pin them
    # older than restored object mtimes so they do not dirty the graph.
    if [ -d "$OUT/gen" ]; then
      echo "clamping $OUT/gen mtimes for incremental resume"
      find "$OUT/gen" -type f -print0 | xargs -0 touch -t "${SRC_MTIME_STAMP:-202001010000}"
    fi

    python3 "$SCRIPT_DIR/restore-output-mtimes-from-deps.py" "$OUT"

    if [ ! -e "$OUT/xcode_links" ]; then
      CI=1 GN_EXTRA_ARGS="$(gn_extra_args)" e build --no-remote --gen only
      bash "$SCRIPT_DIR/clamp-src-mtimes.sh" src
      if [ -d "$OUT/gen" ]; then
        find "$OUT/gen" -type f -print0 | xargs -0 touch -t "${SRC_MTIME_STAMP:-202001010000}"
      fi
      # gn must not leave objects newer than the deps log.
      python3 "$SCRIPT_DIR/restore-output-mtimes-from-deps.py" "$OUT"
    fi

    dry_file="$(mktemp)"
    if ! ninja -C "$OUT" -n electron >"$dry_file" 2>&1; then
      echo "ninja dry-run failed; dumping output"
      cat "$dry_file" || true
      rm -f "$dry_file"
      exit 1
    fi
    dry_lines="$(wc -l < "$dry_file" | tr -d ' ')"
    echo "ninja -n electron: $dry_lines planned steps (gate max ${RESUME_DRY_RUN_MAX})"
    tail -n 20 "$dry_file" || true
    if [ "$dry_lines" -gt "$RESUME_DRY_RUN_MAX" ]; then
      echo "::error::out-cache resume looks broken (${dry_lines} dry-run steps > ${RESUME_DRY_RUN_MAX}). Refusing to burn the runner. First explains:"
      ninja -C "$OUT" -d explain electron 2>&1 | head -n 80 || true
      rm -f "$dry_file"
      exit 1
    fi
    rm -f "$dry_file"
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
