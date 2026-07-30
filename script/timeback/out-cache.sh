#!/usr/bin/env bash
# Store/restore the Chromium build directory in S3.
#
# Hybrid layout under OUT_CACHE_PREFIX:
#   baseline.tar.zst     full snapshot for fast cold restores (~10-20 min)
#   <mirror>/...         object-level mirror for cheap incremental checkpoints
#
# Restore: stream the baseline, then overlay only size-changed objects from the
# mirror. Save: always mirror deltas; refresh the baseline when missing or stale.
#
# Usage: out-cache.sh restore | save
#
# Env: CACHE_BUCKET, OUT_CACHE_PREFIX, OUT_DIR (default src/out/Release),
#      USE_OUT_CACHE, BASELINE_REFRESH_SECONDS (default 7200).
set -uo pipefail

readonly SANITY_FILE=build.ninja
readonly BASELINE_NAME=baseline.tar.zst
readonly S3_CONCURRENCY=32
readonly ZSTD_LEVEL=3
readonly ZSTD_LONG=30
readonly SYNC_FLAGS=(--only-show-errors --no-progress)
readonly BASELINE_REFRESH_SECONDS="${BASELINE_REFRESH_SECONDS:-7200}"
# xcode_links is a tree of symlinks gn regenerates from the local Xcode SDK on
# every runner. Tar and aws s3 sync cannot mirror it faithfully.
readonly XCODE_LINKS_EXCLUDE='Release/xcode_links'
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
readonly BASELINE_URI="${S3_URI}/${BASELINE_NAME}"
readonly OUT_PARENT="$(cd "$(dirname "$OUT_DIR")" && pwd)"
readonly OUT_BASENAME="$(basename "$OUT_DIR")"

aws configure set default.s3.max_concurrent_requests "$S3_CONCURRENCY" || true
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

baseline_exists() {
  aws s3api head-object --bucket "$CACHE_BUCKET" \
    --key "${OUT_CACHE_PREFIX%/}/${BASELINE_NAME}" >/dev/null 2>&1
}

baseline_age_seconds() {
  local modified
  modified=$(aws s3api head-object --bucket "$CACHE_BUCKET" \
    --key "${OUT_CACHE_PREFIX%/}/${BASELINE_NAME}" \
    --query 'LastModified' --output text)
  python3 - "$modified" <<'PY'
import datetime as dt
import sys

modified = dt.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
age = dt.datetime.now(dt.timezone.utc) - modified
print(int(age.total_seconds()))
PY
}

invalidate_ninja_for_xcode_links() {
  rm -f "$OUT_DIR/build.ninja" "$OUT_DIR/build.ninja.stamp" "$OUT_DIR/toolchain.ninja"
}

restore() {
  if [ -f "$OUT_DIR/$SANITY_FILE" ]; then
    echo "out dir already present locally; keeping it"
    return 0
  fi
  if ! aws s3 ls "${S3_URI}/${SANITY_FILE}" >/dev/null 2>&1 \
     && ! baseline_exists; then
    echo "out cache MISS: ${OUT_CACHE_PREFIX} (compiling from scratch)"
    return 0
  fi

  echo "out cache HIT: ${OUT_CACHE_PREFIX}"
  mkdir -p "$OUT_DIR"

  if baseline_exists; then
    echo "restoring baseline archive (fast path)"
    if ! aws s3 cp "$BASELINE_URI" - \
         | zstd -d --long="$ZSTD_LONG" -c \
         | tar -xf - -C "$OUT_PARENT"; then
      echo "baseline restore failed; falling back to object sync"
      find "$OUT_DIR" -mindepth 1 -delete 2>/dev/null || true
    elif [ -f "$OUT_DIR/$SANITY_FILE" ]; then
      echo "baseline extracted ($(du -sh "$OUT_DIR" | cut -f1)); overlaying mirror deltas"
      if aws s3 sync "$S3_URI" "$OUT_DIR" "${SYNC_FLAGS[@]}" --size-only \
           "${CACHE_EXCLUDES[@]}" \
         && [ -f "$OUT_DIR/$SANITY_FILE" ]; then
        invalidate_ninja_for_xcode_links
        echo "restored $OUT_DIR ($(du -sh "$OUT_DIR" | cut -f1)); invalidated ninja files for xcode_links regen"
        return 0
      fi
      echo "baseline + overlay incomplete; falling back to full object sync"
      find "$OUT_DIR" -mindepth 1 -delete 2>/dev/null || true
    else
      echo "baseline extract incomplete; falling back to full object sync"
      find "$OUT_DIR" -mindepth 1 -delete 2>/dev/null || true
    fi
  fi

  echo "restoring object mirror (slow path)"
  if aws s3 sync "$S3_URI" "$OUT_DIR" "${SYNC_FLAGS[@]}" "${CACHE_EXCLUDES[@]}" \
     && [ -f "$OUT_DIR/$SANITY_FILE" ]; then
    invalidate_ninja_for_xcode_links
    echo "restored $OUT_DIR ($(du -sh "$OUT_DIR" | cut -f1)); invalidated ninja files for xcode_links regen"
    return 0
  fi

  echo "out cache restore incomplete; discarding it and building from scratch"
  find "$OUT_DIR" -mindepth 1 -delete 2>/dev/null || true
}

save_baseline() {
  local size_kb expected_bytes tmp_key
  rm -rf "$OUT_DIR/xcode_links"

  size_kb=$(du -sk "$OUT_DIR" | cut -f1)
  expected_bytes=$(( size_kb * 1024 ))
  tmp_key="${OUT_CACHE_PREFIX%/}/${BASELINE_NAME}.upload-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"

  echo "writing baseline archive (~$(( size_kb / 1024 )) MiB uncompressed)"
  if ! tar -cf - -C "$OUT_PARENT" \
       --exclude="$XCODE_LINKS_EXCLUDE" \
       "$OUT_BASENAME" \
       | zstd -T0 "-$ZSTD_LEVEL" --long="$ZSTD_LONG" -c \
       | aws s3 cp - "s3://${CACHE_BUCKET}/${tmp_key}" --expected-size "$expected_bytes"; then
    echo "baseline upload failed"
    aws s3 rm "s3://${CACHE_BUCKET}/${tmp_key}" >/dev/null 2>&1 || true
    return 1
  fi

  aws s3 mv "s3://${CACHE_BUCKET}/${tmp_key}" "$BASELINE_URI"
  echo "baseline stored at ${OUT_CACHE_PREFIX}${BASELINE_NAME}"
}

should_refresh_baseline() {
  if ! baseline_exists; then
    echo "no baseline yet"
    return 0
  fi
  local age
  age=$(baseline_age_seconds)
  if [ "$age" -ge "$BASELINE_REFRESH_SECONDS" ]; then
    echo "baseline is ${age}s old (refresh after ${BASELINE_REFRESH_SECONDS}s)"
    return 0
  fi
  echo "baseline is ${age}s old; skipping refresh"
  return 1
}

save() {
  if [ ! -d "$OUT_DIR" ]; then
    echo "no $OUT_DIR yet; nothing to checkpoint"
    return 0
  fi

  local stamp="${OUT_DIR}/.timeback-checkpoint-stamp"
  if [ -f "$stamp" ] && [ -z "$(find "$OUT_DIR" -type f -newer "$stamp" \
       -not -name "$(basename "$stamp")" -print -quit)" ]; then
    echo "nothing compiled since the last checkpoint; skipping upload"
    return 0
  fi

  rm -rf "$OUT_DIR/xcode_links"

  echo "checkpointing changed files in $OUT_DIR -> ${OUT_CACHE_PREFIX}"
  if ! aws s3 sync "$OUT_DIR" "$S3_URI" "${SYNC_FLAGS[@]}" \
       --delete "${CACHE_EXCLUDES[@]}" --exclude "$(basename "$stamp")"; then
    echo "checkpoint upload failed"
    return 1
  fi

  touch "$stamp"
  echo "checkpoint stored at ${OUT_CACHE_PREFIX}"

  if should_refresh_baseline; then
    save_baseline || echo "baseline refresh failed; mirror checkpoint is still valid"
  fi
}

case "${1:-}" in
  restore) restore ;;
  save) save ;;
  *)
    echo "usage: $(basename "$0") restore|save" >&2
    exit 2
    ;;
esac
