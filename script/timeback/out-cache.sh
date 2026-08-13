#!/usr/bin/env bash
# Store/restore the Chromium build directory in S3.
#
# A release Electron compile is ~42k ninja targets over several hours. Ninja is
# incremental, so keeping out/Release across runs means a failure (or a runner
# timeout) at target 41k costs one pass, not the whole build.
#
# The directory is mirrored object-for-object rather than as one tarball, so a
# mid-build checkpoint uploads only the objects that were compiled since the
# previous one instead of tens of GB every time.
#
# Usage: out-cache.sh restore | save | touch-outputs
#
# Env: CACHE_BUCKET, OUT_CACHE_PREFIX, OUT_DIR (default src/out/Release),
#      USE_OUT_CACHE (anything but "true" makes this a no-op).
#
# Resume requires clamp-src-mtimes.sh on the source tree BEFORE ninja: tar
# extract mtimes otherwise force a full rebuild even with a warm out-cache.
set -uo pipefail

readonly SANITY_FILE=build.ninja
readonly S3_CONCURRENCY=32
readonly SYNC_FLAGS=(--only-show-errors --no-progress)
# xcode_links is a tree of symlinks gn regenerates from the local Xcode SDK on
# every runner. aws s3 sync cannot mirror it faithfully (it follows links and
# chokes on the SDK's recursive/broken ones), so a restored copy leaves gn with
# dangling .defs inputs and the build dies at "Regenerating ninja files". Keep it
# out of the cache in both directions; gn recreates it locally.
readonly CACHE_EXCLUDES=(--exclude "xcode_links/*" --exclude "xcode_links/**")

OUT_DIR="${OUT_DIR:-src/out/Release}"
USE_OUT_CACHE="${USE_OUT_CACHE:-true}"

if [ "$USE_OUT_CACHE" != "true" ]; then
  echo "out cache disabled"
  exit 0
fi

: "${CACHE_BUCKET:?CACHE_BUCKET is required}"
: "${OUT_CACHE_PREFIX:?OUT_CACHE_PREFIX is required}"

readonly S3_URI="s3://${CACHE_BUCKET}/${OUT_CACHE_PREFIX%/}"

# Chromium's out dir is ~100k files; the CLI default of 10 parallel requests
# makes both directions needlessly slow.
aws configure set default.s3.max_concurrent_requests "$S3_CONCURRENCY" || true
# AWS CLI v2 defaults to mandatory checksums that need a seekable stream; s3 sync
# retries then fail with "Need to rewind the stream ... not seekable".
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

# Optional safety freshen of compile products (after src mtimes are clamped and
# xcode_links recreated). Prefer clamping sources; this is belt-and-suspenders.
touch_compile_outputs() {
  if [ ! -d "$OUT_DIR" ]; then
    return 0
  fi
  local count
  count="$(find "$OUT_DIR" -type f \( \
      -name '*.o' -o -name '*.obj' -o -name '*.a' -o -name '*.dylib' \
      -o -name '*.so' -o -name '*.bundle' -o -name '*.pch' -o -name '*.gch' \
    \) | wc -l | tr -d ' ')"
  echo "touching ${count} compile outputs under $OUT_DIR"
  find "$OUT_DIR" -type f \( \
      -name '*.o' -o -name '*.obj' -o -name '*.a' -o -name '*.dylib' \
      -o -name '*.so' -o -name '*.bundle' -o -name '*.pch' -o -name '*.gch' \
    \) -exec touch {} + 2>/dev/null || true
}

restore() {
  # Marker (or intact build.ninja) means a prior restore/sync already populated
  # this workspace. Do not re-sync.
  if [ -f "$OUT_DIR/.timeback-out-restored" ] || [ -f "$OUT_DIR/$SANITY_FILE" ]; then
    echo "out dir already present locally; skipping re-sync"
    return 0
  fi
  if ! aws s3 ls "${S3_URI}/${SANITY_FILE}" >/dev/null 2>&1; then
    echo "out cache MISS: ${OUT_CACHE_PREFIX} (compiling from scratch)"
    return 0
  fi

  echo "out cache HIT: ${OUT_CACHE_PREFIX}"
  mkdir -p "$OUT_DIR"
  if aws s3 sync "$S3_URI" "$OUT_DIR" "${SYNC_FLAGS[@]}" "${CACHE_EXCLUDES[@]}" \
     && [ -f "$OUT_DIR/$SANITY_FILE" ]; then
    local obj_count size
    obj_count="$(find "$OUT_DIR" -type f \( -name '*.o' -o -name '*.obj' \) | wc -l | tr -d ' ')"
    size="$(du -sh "$OUT_DIR" | cut -f1)"
    echo "restored $OUT_DIR ($size, ${obj_count} object files)"
    touch "$OUT_DIR/.timeback-out-restored"

    # Keep build.ninja / toolchain.ninja. Deleting them forced a full gn rewrite
    # and threw away command-line identity in .ninja_log. xcode_links is excluded
    # from the mirror; the caller recreates it with gn gen (commands stay the
    # same: -isysroot xcode_links/electron/MacOSX*.sdk is relative).
    if [ ! -e "$OUT_DIR/xcode_links" ]; then
      echo "xcode_links absent after restore (expected); recreate with gn gen before ninja"
    fi
    return 0
  fi

  # A half-restored out dir is worse than none: ninja would trust stale stamps.
  echo "out cache restore incomplete; discarding it and building from scratch"
  find "$OUT_DIR" -mindepth 1 -delete 2>/dev/null || true
}

save() {
  if [ ! -d "$OUT_DIR" ]; then
    echo "no $OUT_DIR yet; nothing to checkpoint"
    return 0
  fi

  local stamp="${OUT_DIR}/.timeback-checkpoint-stamp"
  # Files only: writing the stamp bumps the mtime of its own directory.
  if [ -f "$stamp" ] && [ -z "$(find "$OUT_DIR" -type f -newer "$stamp" \
       -not -name "$(basename "$stamp")" -print -quit)" ]; then
    echo "nothing compiled since the last checkpoint; skipping upload"
    return 0
  fi

  # Delete before upload so aws s3 sync will not traverse the SDK's recursive
  # symlinks (even with --exclude it can still follow them and hang/fail).
  # Caller / build-resumable MUST recreate via ensure-xcode-links.sh before the
  # next ninja — gn does not recreate this tree for us on resume.
  echo "removing xcode_links before S3 sync (recreate before next ninja)"
  command rm -rf "$OUT_DIR/xcode_links"

  # Default: do NOT --delete. A failed ninja pass can leave generated *.ninja
  # fragments briefly absent; sync --delete then permanently purged them from S3
  # (seen: obj/v8/v8_flags.ninja missing → next resume cannot load toolchain.ninja).
  # Opt in with OUT_CACHE_SYNC_DELETE=true only for intentional mirror pruning.
  local sync_args=("${SYNC_FLAGS[@]}" "${CACHE_EXCLUDES[@]}" --exclude "$(basename "$stamp")")
  if [ "${OUT_CACHE_SYNC_DELETE:-false}" = "true" ]; then
    echo "checkpointing with --delete (OUT_CACHE_SYNC_DELETE=true)"
    sync_args+=(--delete)
  else
    echo "checkpointing without --delete (set OUT_CACHE_SYNC_DELETE=true to prune remote)"
  fi
  echo "checkpointing changed files in $OUT_DIR -> ${OUT_CACHE_PREFIX}"
  if ! aws s3 sync "$OUT_DIR" "$S3_URI" "${sync_args[@]}"; then
    echo "checkpoint upload failed"
    return 1
  fi

  touch "$stamp"
  echo "checkpoint stored at ${OUT_CACHE_PREFIX}"
}

case "${1:-}" in
  restore) restore ;;
  save) save ;;
  touch-outputs) touch_compile_outputs ;;
  *)
    echo "usage: $(basename "$0") restore|save|touch-outputs" >&2
    exit 2
    ;;
esac
