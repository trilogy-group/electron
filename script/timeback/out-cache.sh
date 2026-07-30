#!/usr/bin/env bash
# Store/restore the Chromium build directory in S3.
#
# Hybrid layout under OUT_CACHE_PREFIX:
#   objects/...                          authoritative incremental mirror
#   archives/<generation>.tar.zst       immutable fast-restore snapshots
#   latest-baseline.txt                  atomically promoted archive key
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
readonly OBJECTS_PREFIX="${OUT_CACHE_PREFIX%/}/objects"
readonly ARCHIVES_PREFIX="${OUT_CACHE_PREFIX%/}/archives"
readonly BASELINE_POINTER_KEY="${OUT_CACHE_PREFIX%/}/latest-baseline.txt"
readonly WRITER_LOCK_KEY="${OUT_CACHE_PREFIX%/}/writer.lock"
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

readonly LEGACY_S3_URI="s3://${CACHE_BUCKET}/${OUT_CACHE_PREFIX%/}"
readonly S3_URI="s3://${CACHE_BUCKET}/${OBJECTS_PREFIX}"
readonly OUT_PARENT="$(cd "$(dirname "$OUT_DIR")" && pwd)"
readonly OUT_BASENAME="$(basename "$OUT_DIR")"

aws configure set default.s3.max_concurrent_requests "$S3_CONCURRENCY" || true
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

baseline_exists() {
  aws s3api head-object --bucket "$CACHE_BUCKET" --key "$BASELINE_POINTER_KEY" >/dev/null 2>&1
}

baseline_key() {
  aws s3 cp "s3://${CACHE_BUCKET}/${BASELINE_POINTER_KEY}" - --only-show-errors
}

baseline_age_seconds() {
  local key modified
  key=$(baseline_key)
  modified=$(aws s3api head-object --bucket "$CACHE_BUCKET" --key "$key" \
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

acquire_writer_lock() {
  local owner="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
  local existing
  if existing=$(aws s3 cp "s3://${CACHE_BUCKET}/${WRITER_LOCK_KEY}" - \
       --only-show-errors 2>/dev/null); then
    if [ "$existing" != "$owner" ]; then
      echo "cache writer lock held by $existing; refusing concurrent checkpoint" >&2
      return 1
    fi
    return 0
  fi
  printf '%s' "$owner" | aws s3 cp - "s3://${CACHE_BUCKET}/${WRITER_LOCK_KEY}" \
    --only-show-errors
  existing=$(aws s3 cp "s3://${CACHE_BUCKET}/${WRITER_LOCK_KEY}" - \
    --only-show-errors)
  [ "$existing" = "$owner" ] || {
    echo "lost cache writer lock to $existing" >&2
    return 1
  }
}

release_writer_lock() {
  local owner="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
  local existing
  existing=$(aws s3 cp "s3://${CACHE_BUCKET}/${WRITER_LOCK_KEY}" - \
    --only-show-errors 2>/dev/null) || return 0
  if [ "$existing" = "$owner" ]; then
    aws s3 rm "s3://${CACHE_BUCKET}/${WRITER_LOCK_KEY}" --only-show-errors
  fi
}

restore() {
  if [ -f "$OUT_DIR/$SANITY_FILE" ]; then
    echo "out dir already present locally; keeping it"
    return 0
  fi
  if ! aws s3 ls "${S3_URI}/${SANITY_FILE}" >/dev/null 2>&1 \
     && ! aws s3 ls "${LEGACY_S3_URI}/${SANITY_FILE}" >/dev/null 2>&1 \
     && ! baseline_exists; then
    echo "out cache MISS: ${OUT_CACHE_PREFIX} (compiling from scratch)"
    return 0
  fi

  echo "out cache HIT: ${OUT_CACHE_PREFIX}"
  mkdir -p "$OUT_DIR"

  if baseline_exists; then
    local baseline
    baseline=$(baseline_key)
    echo "restoring baseline archive (fast path)"
    if ! aws s3 cp "s3://${CACHE_BUCKET}/${baseline}" - \
         | zstd -d --long="$ZSTD_LONG" -c \
         | tar -xf - -C "$OUT_PARENT"; then
      echo "baseline restore failed; falling back to object sync"
      find "$OUT_DIR" -mindepth 1 -delete 2>/dev/null || true
    elif [ -f "$OUT_DIR/$SANITY_FILE" ]; then
      # The archive is a complete immutable checkpoint. Do not combine it with
      # an unversioned mutable mirror; that could create a state that never
      # existed. Ninja resumes from the archive's internally consistent state.
      invalidate_ninja_for_xcode_links
      echo "restored immutable baseline $baseline ($(du -sh "$OUT_DIR" | cut -f1)); invalidated ninja files for xcode_links regen"
      return 0
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
  # Backward-compatible restore for the cache produced before objects/ and
  # archives/ were separated.
  if aws s3 sync "$LEGACY_S3_URI" "$OUT_DIR" "${SYNC_FLAGS[@]}" \
       "${CACHE_EXCLUDES[@]}" --exclude "baseline.tar.zst" \
       --exclude "baseline.tar.zst.upload-*" \
     && [ -f "$OUT_DIR/$SANITY_FILE" ]; then
    invalidate_ninja_for_xcode_links
    echo "restored legacy object mirror; invalidated ninja files for xcode_links regen"
    return 0
  fi

  echo "out cache restore incomplete; discarding it and building from scratch"
  find "$OUT_DIR" -mindepth 1 -delete 2>/dev/null || true
}

save_baseline() {
  local size_kb expected_bytes generation archive_key tmp_key pointer_tmp
  rm -rf "$OUT_DIR/xcode_links"

  size_kb=$(du -sk "$OUT_DIR" | cut -f1)
  expected_bytes=$(( size_kb * 1024 ))
  generation="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$(date -u +%Y%m%dT%H%M%SZ)"
  archive_key="${ARCHIVES_PREFIX}/${generation}.tar.zst"
  tmp_key="${ARCHIVES_PREFIX}/.upload-${generation}.tar.zst"
  pointer_tmp="${BASELINE_POINTER_KEY}.upload-${generation}"

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

  aws s3 mv "s3://${CACHE_BUCKET}/${tmp_key}" "s3://${CACHE_BUCKET}/${archive_key}"
  printf '%s\n' "$archive_key" | aws s3 cp - "s3://${CACHE_BUCKET}/${pointer_tmp}" --only-show-errors
  aws s3 mv "s3://${CACHE_BUCKET}/${pointer_tmp}" "s3://${CACHE_BUCKET}/${BASELINE_POINTER_KEY}"
  echo "baseline stored at $archive_key"
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

  acquire_writer_lock || return 1
  trap release_writer_lock RETURN

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

  release_writer_lock
  trap - RETURN
}

case "${1:-}" in
  restore) restore ;;
  save) save ;;
  *)
    echo "usage: $(basename "$0") restore|save" >&2
    exit 2
    ;;
esac
