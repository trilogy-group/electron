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
  # Marker (or intact build.ninja) means a prior restore/sync already populated
  # this workspace. Re-touch so any later src-cache extract cannot win on mtime.
  if [ -f "$OUT_DIR/.timeback-out-restored" ] || [ -f "$OUT_DIR/$SANITY_FILE" ]; then
    echo "out dir already present locally; re-touching outputs for incremental resume"
    find "$OUT_DIR" -type f -exec touch {} + 2>/dev/null || true
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

    # CRITICAL: src-cache tarball extract sets source mtimes to "now". S3 sync
    # preserves older compile mtimes on .o/.a outputs. Ninja then sees every
    # header/source as newer than every object and rebuilds the entire ~80k
    # graph — looking like a cache miss even when the objects are present.
    # Bump all restored outputs to now so they are newer than the extracted src.
    echo "touching restored outputs so src-cache mtimes do not invalidate the tree"
    find "$OUT_DIR" -type f -exec touch {} +
    touch "$OUT_DIR/.timeback-out-restored"

    # xcode_links is excluded from the mirror, so a checkpoint can leave
    # build.ninja referencing SDK paths gn must regenerate locally. Drop the
    # ninja files so the next build pass reruns gn; objects stay (and are now
    # mtime-fresh) so compile remains incremental after gn gen.
    rm -f "$OUT_DIR/build.ninja" "$OUT_DIR/build.ninja.stamp" "$OUT_DIR/toolchain.ninja"
    echo "invalidated ninja files for xcode_links regen (objects retained)"
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
