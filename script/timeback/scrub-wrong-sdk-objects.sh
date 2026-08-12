#!/usr/bin/env bash
# Drop objects/caches compiled against the wrong Mac SDK so ThinLTO can link.
#
# Mixing SDK 26.4 and 26.5 bitcode fails with:
#   ld64.lld: linking module flags 'SDK Version': IDs have conflicting values
#
# ONLY delete *.o that otool reports with the wrong sdk. Never bulk-wipe host
# trees — that re-planned ~43k steps every resume and aws s3 sync --delete then
# purged rebuilt host objects from the out-cache.
#
# Usage: scrub-wrong-sdk-objects.sh <out_dir> <major.minor>
set -euo pipefail

OUT_DIR="${1:?out_dir required}"
WANT_VER="${2:?sdk major.minor required}"

if [ ! -d "$OUT_DIR" ]; then
  echo "scrub-wrong-sdk-objects: missing $OUT_DIR" >&2
  exit 1
fi

echo "scrub-wrong-sdk-objects: want SDK ${WANT_VER} under ${OUT_DIR} (otool-only, no host wipe)"

# ThinLTO caches retain SDK-specific intermediates.
find "$OUT_DIR" -type d -name 'thinlto-cache' -prune -print 2>/dev/null \
  | while IFS= read -r d; do
      echo "removing $d"
      rm -rf "$d"
    done

deleted=0
checked=0
while IFS= read -r -d '' f; do
  checked=$((checked + 1))
  sdk="$(otool -l "$f" 2>/dev/null | awk '/cmd LC_BUILD_VERSION/{p=1} p&&/^[[:space:]]*sdk/{print $2; exit}')" || sdk=""
  if [ -n "$sdk" ] && [ "$sdk" != "$WANT_VER" ]; then
    rm -f "$f"
    deleted=$((deleted + 1))
  fi
done < <(find "$OUT_DIR" -type f -name '*.o' -print0 2>/dev/null)

echo "scrub-wrong-sdk-objects: otool checked=${checked} deleted=${deleted} (want ${WANT_VER})"
