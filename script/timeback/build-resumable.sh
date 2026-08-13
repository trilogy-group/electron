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
  # save() removes xcode_links so aws s3 sync will not traverse the SDK tree.
  # Recreate the hermetic pin before the next ninja pass or crashpad mig fails
  # with missing xcode_links/.../exc.defs.
  local out="${OUT_DIR:-src/out/Release}"
  if [ -d "$out" ]; then
    bash "$SCRIPT_DIR/ensure-xcode-links.sh" "$out" \
      || echo "ensure-xcode-links after checkpoint failed; next pass may error"
  fi
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
#
# Helpers link with `-framework "Electron Framework"` via `:electron_framework+link`.
# That +link edge is TOC-based, so ninja can schedule Electron Helper in parallel
# with Framework SOLINK. SOLINK removes the old bundle at start → Helper fails with
# "framework not found for -framework Electron Framework" (seen at edges~489758).
# Finish the framework target before asking for the full electron build.
run_ninja_target() {
  local target="$1"
  local out="${OUT_DIR:-src/out/Release}"
  if [ -n "${NINJA_J:-}" ]; then
    ninja -C "$out" -j "$NINJA_J" "$target" 2>&1
  else
    ninja -C "$out" "$target" 2>&1
  fi
}

electron_framework_needs_work() {
  local out="${OUT_DIR:-src/out/Release}"
  local dry
  dry="$(mktemp)"
  if ! ninja -C "$out" -n electron:electron_framework >"$dry" 2>&1; then
    echo "electron_framework dry-run failed; will still attempt phase A"
    cat "$dry" || true
    rm -f "$dry"
    return 0
  fi
  if grep -q "no work to do" "$dry"; then
    rm -f "$dry"
    return 1
  fi
  if [ "$(wc -l < "$dry" | tr -d ' ')" -eq 0 ]; then
    rm -f "$dry"
    return 1
  fi
  echo "electron_framework dry-run: $(wc -l < "$dry" | tr -d ' ') lines"
  tail -n 5 "$dry" || true
  rm -f "$dry"
  return 0
}

run_build() {
  # Defensive: checkpoints delete xcode_links; ensure the hermetic SDK pin exists
  # before every ninja invocation (cheap if already linked).
  local out="${OUT_DIR:-src/out/Release}"
  if [ -d "$out" ]; then
    bash "$SCRIPT_DIR/ensure-xcode-links.sh" "$out" || return $?
  fi
  if electron_framework_needs_work; then
    echo "=== phase A: electron:electron_framework (before Helper links) ==="
    run_ninja_target electron:electron_framework || return $?
    echo "=== phase A complete ==="
  fi

  # Helpers link with -F. -framework "Electron Framework". If the bundle is
  # missing, fail here instead of racing into Helper.
  if [ ! -d "${out}/Electron Framework.framework" ]; then
    echo "ERROR: Electron Framework.framework missing after phase A at ${out}" >&2
    ls -la "$out" | head -50 >&2 || true
    return 1
  fi

  # Do NOT use `e build` for phase B: it re-detects the live macOS SDK and can
  # re-enter gn / dirty the framework, then Helper links in parallel while the
  # bundle is briefly absent ("framework not found for -framework Electron
  # Framework"). Drive ninja directly against the restored graph.
  local phase_b_j="${NINJA_J:-}"
  local remain_file remain
  remain_file="$(mktemp)"
  if ninja -C "$out" -n electron >"$remain_file" 2>&1; then
    remain="$(wc -l < "$remain_file" | tr -d ' ')"
    echo "phase B dry-run: ${remain} lines"
    # Final link cluster is small; -j1 prevents Helper/Framework TOC races.
    if [ "$remain" -gt 0 ] && [ "$remain" -lt 500 ]; then
      echo "phase B: serializing final links (-j1; ${remain} dry-run lines)"
      phase_b_j=1
    fi
  fi
  rm -f "$remain_file"

  echo "=== phase B: ninja electron (j=${phase_b_j:-default}) ==="
  if [ -n "$phase_b_j" ]; then
    ninja -C "$out" -j "$phase_b_j" electron 2>&1
  else
    ninja -C "$out" electron 2>&1
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
  local edges_at_start
  edges_at_start="$(edges_completed)"
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
      local edges_now
      edges_now="$(edges_completed)"
      # ThinLTO / dsymutil can run 20–40+ minutes as a single edge. Killing that
      # for a checkpoint restarts the link from zero every budget window (seen:
      # .ninja_log stuck at the same count across multiple passes near the end).
      if [ "$edges_now" -eq "$edges_at_start" ]; then
        echo "no .ninja_log progress this pass (still ${edges_now}); likely long link — skipping checkpoint kill, waiting for completion"
        deadline=$(( SECONDS + budget ))
        next_heartbeat=$(( SECONDS + HEARTBEAT_SECONDS ))
        continue
      fi
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
#   2) Recreate xcode_links (symlink only — do not gn gen; that fights the
#      restored build.ninja and was failing on missing SDK defs).
#   3) Restore each output's mtime from .ninja_deps (s3 sync makes objects
#      newer than the deps log → ninja invalidates every edge).
#   4) Never touch *.o afterward.
#   5) Fail fast if ninja -n still looks like a full rebuild.
if [ -d src ]; then
  bash "$SCRIPT_DIR/clamp-src-mtimes.sh" src
fi

"$SCRIPT_DIR/out-cache.sh" restore

# Otool-only scrub after an SDK mismatch; never bulk-wipe host *.o (that
# re-planned ~43k steps every 6h resume).
readonly RESUME_DRY_RUN_MAX="${RESUME_DRY_RUN_MAX:-70000}"
readonly OUT="${OUT_DIR:-src/out/Release}"
if [ -d "$OUT" ] && [ "${USE_OUT_CACHE:-true}" = "true" ]; then
  if [ -n "$(find "$OUT" -type f -name '*.o' -print -quit 2>/dev/null)" ]; then
    echo "=== resume prep: xcode_links, scrub wrong-SDK objs, deps mtimes, dry-run gate ==="

    bash "$SCRIPT_DIR/ensure-xcode-links.sh" "$OUT"

    # MacOSX26.4.sdk → 26.4 for scrubbing ThinLTO SDK mismatches.
    SDK_VER="$(sed -n 's/.*xcode_links\/electron\/MacOSX\([0-9][0-9]*\.[0-9][0-9]*\)\.sdk.*/\1/p' \
      "${OUT}/args.gn" 2>/dev/null | head -1 || true)"
    SDK_VER="${SDK_VER:-26.4}"
    bash "$SCRIPT_DIR/scrub-wrong-sdk-objects.sh" "$OUT" "$SDK_VER"

    # Generated headers under out/ also arrive with S3 LastModified; pin them
    # older than restored object mtimes so they do not dirty the graph.
    if [ -d "$OUT/gen" ]; then
      echo "clamping $OUT/gen mtimes for incremental resume"
      find "$OUT/gen" -type f -print0 | xargs -0 touch -t "${SRC_MTIME_STAMP:-202001010000}"
    fi

    python3 "$SCRIPT_DIR/restore-output-mtimes-from-deps.py" "$OUT"

    # Restore missing obj/**/*.ninja without rewriting Release's build.ninja.
    # In-place `gn gen` fails: manual xcode_links under //out look like undeclared
    # generated inputs (crashpad mig .defs). Side-gen with an absolute hermetic
    # mac_sdk_path avoids that; we only copy fragments that are absent.
    repair_missing_ninja_fragments() {
      local out="$1"
      local src_dir out_name hermetic fix_rel fix_dir args_src sdk_name copied
      src_dir="$(cd "$(dirname "$out")/.." && pwd)"
      out_name="$(basename "$out")"
      fix_rel="out/${out_name}__ninja_repair"
      fix_dir="${src_dir}/${fix_rel}"
      args_src="${out}/args.gn"
      if [ ! -f "$args_src" ]; then
        echo "repair: missing $args_src" >&2
        return 1
      fi
      if ! command -v gn >/dev/null 2>&1; then
        echo "gn not on PATH; cannot repair missing ninja fragments" >&2
        return 1
      fi

      sdk_name="$(sed -n 's/.*xcode_links\/electron\/\([^"/]*\)".*/\1/p' "$args_src" | head -1)"
      sdk_name="${sdk_name:-MacOSX26.4.sdk}"
      hermetic="${HOME}/.electron_build_tools/third_party/SDKs/${sdk_name}"
      if [ ! -d "$hermetic" ]; then
        echo "repair: hermetic SDK missing at $hermetic" >&2
        return 1
      fi

      echo "=== repairing missing ninja via side gn gen (${fix_rel}, sdk=${hermetic}) ==="
      rm -rf "$fix_dir"
      mkdir -p "$fix_dir"
      # Absolute SDK path (outside //out) so gn does not require xcode_links generators.
      sed "s|^mac_sdk_path = \".*\"|mac_sdk_path = \"${hermetic}\"|" "$args_src" >"${fix_dir}/args.gn"
      if ! grep -q "^mac_sdk_path = \"${hermetic}\"$" "${fix_dir}/args.gn"; then
        echo "mac_sdk_path = \"${hermetic}\"" >>"${fix_dir}/args.gn"
      fi

      if ! (cd "$src_dir" && gn gen "$fix_rel"); then
        echo "repair: side gn gen failed" >&2
        rm -rf "$fix_dir"
        return 1
      fi

      copied=0
      while IFS= read -r -d '' f; do
        rel="${f#${fix_dir}/}"
        case "$rel" in
          build.ninja|toolchain.ninja|build.ninja.stamp|*.ninja.d) continue ;;
        esac
        if [ ! -f "${out}/${rel}" ]; then
          mkdir -p "$(dirname "${out}/${rel}")"
          cp "$f" "${out}/${rel}"
          copied=$((copied + 1))
          echo "restored missing ${rel}"
        fi
      done < <(find "$fix_dir" -type f -name '*.ninja' -print0 2>/dev/null)

      echo "repair: restored ${copied} missing ninja fragments"
      rm -rf "$fix_dir"

      if [ "$copied" -eq 0 ]; then
        echo "repair: side gen produced no missing fragments to copy" >&2
        return 1
      fi

      bash "$SCRIPT_DIR/ensure-xcode-links.sh" "$out" || return 1
      if [ -d "$out/gen" ]; then
        find "$out/gen" -type f -print0 | xargs -0 touch -t "${SRC_MTIME_STAMP:-202001010000}"
      fi
      python3 "$SCRIPT_DIR/restore-output-mtimes-from-deps.py" "$out" || return 1
    }

    dry_file="$(mktemp)"
    if ! ninja -C "$OUT" -n electron >"$dry_file" 2>&1; then
      echo "ninja dry-run failed; dumping output"
      cat "$dry_file" || true
      if grep -q "loading '.*\\.ninja': No such file" "$dry_file"; then
        echo "missing subninja detected — attempting side-gn ninja fragment repair"
        if ! repair_missing_ninja_fragments "$OUT"; then
          echo "repair failed" >&2
          rm -f "$dry_file"
          exit 1
        fi
        if ninja -C "$OUT" -n electron >"$dry_file" 2>&1; then
          echo "ninja dry-run OK after ninja fragment repair"
        else
          echo "ninja dry-run still failing after repair"
          cat "$dry_file" || true
          rm -f "$dry_file"
          exit 1
        fi
      else
        rm -f "$dry_file"
        exit 1
      fi
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
