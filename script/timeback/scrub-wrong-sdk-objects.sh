#!/usr/bin/env bash
# Drop objects/caches compiled against the wrong Mac SDK so ThinLTO can link.
#
# Mixing SDK 26.4 and 26.5 bitcode fails with:
#   ld64.lld: linking module flags 'SDK Version': IDs have conflicting values
#
# Host *.o wipe is ONE-SHOT when wrong-SDK objects are present (or stamped).
# Unconditionally wiping every resume re-planned ~46k steps after a 6h cap
# instead of the residual ~12k.
#
# Usage: scrub-wrong-sdk-objects.sh <out_dir> <major.minor>
set -euo pipefail

OUT_DIR="${1:?out_dir required}"
WANT_VER="${2:?sdk major.minor required}"
STAMP="${OUT_DIR}/.timeback-sdk-scrubbed-${WANT_VER}"

if [ ! -d "$OUT_DIR" ]; then
  echo "scrub-wrong-sdk-objects: missing $OUT_DIR" >&2
  exit 1
fi

echo "scrub-wrong-sdk-objects: want SDK ${WANT_VER} under ${OUT_DIR}"

# ThinLTO caches retain SDK-specific intermediates — always safe to drop.
find "$OUT_DIR" -type d -name 'thinlto-cache' -prune -print 2>/dev/null \
  | while IFS= read -r d; do
      echo "removing $d"
      rm -rf "$d"
    done

otool_sdk() {
  otool -l "$1" 2>/dev/null \
    | awk '/cmd LC_BUILD_VERSION/{p=1} p&&/^[[:space:]]*sdk/{print $2; exit}' \
    || true
}

scrub_wrong_o() {
  local deleted=0 checked=0
  while IFS= read -r -d '' f; do
    checked=$((checked + 1))
    sdk="$(otool_sdk "$f")"
    if [ -n "$sdk" ] && [ "$sdk" != "$WANT_VER" ]; then
      rm -f "$f"
      deleted=$((deleted + 1))
    fi
  done < <(find "$OUT_DIR" -type f -name '*.o' -print0 2>/dev/null)
  echo "scrub-wrong-sdk-objects: otool checked=${checked} deleted=${deleted} (want ${WANT_VER})"
}

write_stamp() {
  printf '%s\n' "want=${WANT_VER}" "at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STAMP"
  echo "scrub-wrong-sdk-objects: wrote ${STAMP}"
}

# Count host .o and how many report a wrong sdk (stop early on first wrong).
host_wrong=0
host_o_count=0
for host in clang_arm64 clang_arm64_v8_x64 clang_arm64_for_rust_host_build_tools \
            clang_arm64_host_with_system_allocator clang_x64_with_system_allocator; do
  host_dir="${OUT_DIR}/${host}"
  [ -d "$host_dir" ] || continue
  while IFS= read -r -d '' f; do
    host_o_count=$((host_o_count + 1))
    sdk="$(otool_sdk "$f")"
    if [ -n "$sdk" ] && [ "$sdk" != "$WANT_VER" ]; then
      host_wrong=$((host_wrong + 1))
      break 2
    fi
  done < <(find "$host_dir" -type f -name '*.o' -print0 2>/dev/null)
done

if [ -f "$STAMP" ] || { [ "$host_o_count" -gt 0 ] && [ "$host_wrong" -eq 0 ]; }; then
  if [ -f "$STAMP" ]; then
    echo "scrub-wrong-sdk-objects: stamp present — skip host wipe"
  else
    echo "scrub-wrong-sdk-objects: ${host_o_count} host .o look like SDK ${WANT_VER} — skip host wipe"
    write_stamp
  fi
  scrub_wrong_o
  exit 0
fi

echo "scrub-wrong-sdk-objects: host wipe needed (host_o=${host_o_count} wrong_seen=${host_wrong})"

host_scrubbed=0
host_objs_deleted=0
for host in clang_arm64 clang_arm64_v8_x64 clang_arm64_for_rust_host_build_tools \
            clang_arm64_host_with_system_allocator clang_x64_with_system_allocator; do
  host_dir="${OUT_DIR}/${host}"
  if [ -d "$host_dir" ]; then
    echo "scrubbing host objects (*.o/*.a only): ${host}"
    while IFS= read -r -d '' f; do
      rm -f "$f"
      host_objs_deleted=$((host_objs_deleted + 1))
    done < <(find "$host_dir" -type f \( -name '*.o' -o -name '*.a' \) -print0 2>/dev/null)
    host_scrubbed=$((host_scrubbed + 1))
  fi
done
echo "scrub-wrong-sdk-objects: scrubbed ${host_scrubbed} host trees (${host_objs_deleted} .o/.a)"

scrub_wrong_o
write_stamp
