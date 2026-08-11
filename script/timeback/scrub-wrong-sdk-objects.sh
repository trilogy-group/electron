#!/usr/bin/env bash
# Drop objects/caches compiled against the wrong Mac SDK so ThinLTO can link.
#
# Mixing SDK 26.4 and 26.5 bitcode fails with:
#   ld64.lld: linking module flags 'SDK Version': IDs have conflicting values
#
# Usage: scrub-wrong-sdk-objects.sh <out_dir> <major.minor>
set -euo pipefail

OUT_DIR="${1:?out_dir required}"
WANT_VER="${2:?sdk major.minor required}"

if [ ! -d "$OUT_DIR" ]; then
  echo "scrub-wrong-sdk-objects: missing $OUT_DIR" >&2
  exit 1
fi

echo "scrub-wrong-sdk-objects: want SDK ${WANT_VER} under ${OUT_DIR}"

# ThinLTO caches retain SDK-specific intermediates.
find "$OUT_DIR" -type d -name 'thinlto-cache' -prune -print 2>/dev/null \
  | while IFS= read -r d; do
      echo "removing $d"
      rm -rf "$d"
    done

# Host toolchains are cheap to rebuild relative to the target chrome/electron
# graph. The SDK conflict that stopped us was in clang_arm64_v8_x64 (host).
# Wipe host *outputs* but keep *.ninja — build.ninja includes
# clang_arm64/toolchain.ninja; deleting the whole tree breaks the graph.
host_scrubbed=0
host_files_deleted=0
for host in clang_arm64 clang_arm64_v8_x64 clang_arm64_for_rust_host_build_tools \
            clang_arm64_host_with_system_allocator clang_x64_with_system_allocator; do
  host_dir="${OUT_DIR}/${host}"
  if [ -d "$host_dir" ]; then
    echo "scrubbing host outs (keeping *.ninja): ${host}"
    while IFS= read -r -d '' f; do
      rm -f "$f"
      host_files_deleted=$((host_files_deleted + 1))
    done < <(find "$host_dir" -type f ! -name '*.ninja' -print0 2>/dev/null)
    host_scrubbed=$((host_scrubbed + 1))
  fi
done
echo "scrub-wrong-sdk-objects: scrubbed ${host_scrubbed} host trees (${host_files_deleted} non-ninja files)"

# Remaining (target) objects: drop any Mach-O that reports a different sdk
# in LC_BUILD_VERSION.
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

echo "scrub-wrong-sdk-objects: target checked=${checked} deleted=${deleted} (want ${WANT_VER})"
