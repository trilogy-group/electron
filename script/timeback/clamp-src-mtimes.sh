#!/usr/bin/env bash
# Pin source-tree mtimes so a restored out/Release can resume incrementally.
#
# src-cache is a tar extract: every file gets mtime=now. Ninja then treats the
# whole graph as dirty (outputs from S3 are older), and build.ninja.d makes gn
# regenerate on every start — undoing any post-restore touch of *.o files.
# Observed: out-cache HIT 76G / 51k objects, then still [~3k/77k] CXX.
#
# Usage: clamp-src-mtimes.sh [src_dir]
# Env: SRC_MTIME_STAMP (touch -t format, default 202001010000)
set -euo pipefail

SRC_DIR="${1:-src}"
# Fixed past stamp; must stay older than any out-cache object LastModified.
readonly STAMP="${SRC_MTIME_STAMP:-202001010000}"

if [ ! -d "$SRC_DIR" ]; then
  echo "clamp-src-mtimes: $SRC_DIR missing" >&2
  exit 1
fi

echo "clamping mtimes under $SRC_DIR to ${STAMP} (out-cache resume)"
# xargs batches; -exec touch {} + also works but is slower to spawn on ~1M files.
find "$SRC_DIR" -type f -print0 | xargs -0 touch -t "$STAMP"
echo "clamped $(find "$SRC_DIR" -type f | wc -l | tr -d ' ') files"
