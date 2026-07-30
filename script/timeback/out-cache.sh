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
# Usage: out-cache.sh restore | save
#
# Env: CACHE_BUCKET, OUT_CACHE_PREFIX, OUT_DIR (default src/out/Release),
#      USE_OUT_CACHE (anything but "true" makes this a no-op).
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

restore() {
  if [ -f "$OUT_DIR/$SANITY_FILE" ]; then
    echo "out dir already present locally; keeping it"
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
    # xcode_links is excluded from the mirror, so a checkpoint saved before that
    # exclude (or on another runner) can leave build.ninja referencing SDK paths
    # gn must regenerate locally. Drop the ninja stamp files so the next build
    # pass reruns gn instead of dying on missing Mach .defs.
    rm -f "$OUT_DIR/build.ninja" "$OUT_DIR/build.ninja.stamp" "$OUT_DIR/toolchain.ninja"
    echo "restored $OUT_DIR ($(du -sh "$OUT_DIR" | cut -f1)); invalidated ninja files for xcode_links regen"
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

  # gn recreates xcode_links on the next pass; delete it before upload so aws s3
  # sync does not traverse the SDK's recursive/broken symlinks (which makes the
  # checkpoint fail even with --exclude).
  rm -rf "$OUT_DIR/xcode_links"

  # --delete keeps the mirror from accumulating outputs ninja has dropped, and
  # --exclude keeps the stamp itself out of the mirror.
  echo "checkpointing changed files in $OUT_DIR -> ${OUT_CACHE_PREFIX}"
  if ! aws s3 sync "$OUT_DIR" "$S3_URI" "${SYNC_FLAGS[@]}" \
       --delete "${CACHE_EXCLUDES[@]}" --exclude "$(basename "$stamp")"; then
    echo "checkpoint upload failed"
    return 1
  fi

  touch "$stamp"
  echo "checkpoint stored at ${OUT_CACHE_PREFIX}"
}

case "${1:-}" in
  restore) restore ;;
  save) save ;;
  *)
    echo "usage: $(basename "$0") restore|save" >&2
    exit 2
    ;;
esac
