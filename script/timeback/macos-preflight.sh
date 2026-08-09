#!/usr/bin/env bash
# Non-compiling macOS toolchain + GN readiness check for TimeBack Electron builds.
#
# Verifies the runner can reach `electron:electron_dist_zip` without starting a
# multi-hour ninja compile. Catches missing SDKs, frameworks, PGO profiles, and
# broken link command generation before we burn runner hours.
#
# Required env:
#   ELECTRON_VERSION  override stamped into GN args
#   TARGET_ARCH       arm64 | x64
# Optional:
#   NINJA_J           expected parallelism (logged; compared to core count)
#   OUT_DIR           default src/out/Release
set -euo pipefail

: "${ELECTRON_VERSION:?ELECTRON_VERSION is required}"
: "${TARGET_ARCH:?TARGET_ARCH is required}"

OUT_DIR="${OUT_DIR:-src/out/Release}"
TARGET_PLATFORM="${TARGET_PLATFORM:-macos}"

echo "== Runner =="
echo "runner:    ${RUNNER_NAME:-local} (${RUNNER_OS:-$(uname -s)}/${RUNNER_ARCH:-$(uname -m)})"
echo "cpu:       $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
CORES="$(sysctl -n hw.ncpu)"
PHYS="$(sysctl -n hw.physicalcpu)"
MEM_GIB="$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))"
echo "cores:     ${CORES} logical, ${PHYS} physical"
echo "memory:    ${MEM_GIB} GiB"
echo "macos:     $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "NINJA_J:   ${NINJA_J:-unset}"
echo "arch:      ${TARGET_ARCH}"
df -h / "${RUNNER_TEMP:-/tmp}" 2>/dev/null || df -h

if [ -n "${NINJA_J:-}" ]; then
  if [ "$CORES" -lt "$NINJA_J" ]; then
    echo "ERROR: NINJA_J=${NINJA_J} exceeds logical cores (${CORES})"
    exit 1
  fi
fi

echo "== Xcode / SDK / linker =="
xcode-select -p
xcodebuild -version
SDKROOT="$(xcrun --show-sdk-path)"
SDK_VER="$(xcrun --show-sdk-version)"
echo "sdk:       ${SDK_VER}"
echo "sdkroot:   ${SDKROOT}"
test -d "$SDKROOT" || { echo "ERROR: SDKROOT missing"; exit 1; }

# GN/Electron use target_cpu=x64; Apple clang wants -arch x86_64.
case "${TARGET_ARCH}" in
  x64) CLANG_ARCH="x86_64" ;;
  arm64) CLANG_ARCH="arm64" ;;
  *)
    echo "ERROR: unsupported TARGET_ARCH=${TARGET_ARCH}"
    exit 1
    ;;
esac
echo "clang_arch: ${CLANG_ARCH} (from TARGET_ARCH=${TARGET_ARCH})"

CLANG="$(xcrun --find clang)"
LD="$(xcrun --find ld)"
echo "clang:     ${CLANG} ($(${CLANG} --version | head -1))"
echo "ld:        ${LD}"
# Prove the linker can resolve a trivial object against the macOS SDK.
TMPDIR_PROBE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PROBE"' EXIT
cat >"${TMPDIR_PROBE}/probe.c" <<'EOF'
int main(void) { return 0; }
EOF
"${CLANG}" -isysroot "$SDKROOT" -arch "${CLANG_ARCH}" \
  "${TMPDIR_PROBE}/probe.c" -o "${TMPDIR_PROBE}/probe" \
  -framework Foundation -framework AppKit -framework Metal -framework WebKit
file "${TMPDIR_PROBE}/probe"
echo "link probe OK (Foundation/AppKit/Metal/WebKit + arch ${CLANG_ARCH})"

echo "== Framework presence =="
for fw in AppKit Foundation Metal WebKit CoreGraphics CoreMedia AVFoundation \
          Security IOKit QuartzCore Carbon Cocoa; do
  FW_PATH="${SDKROOT}/System/Library/Frameworks/${fw}.framework"
  if [ ! -d "$FW_PATH" ]; then
    echo "ERROR: missing framework ${fw} at ${FW_PATH}"
    exit 1
  fi
  echo "ok  ${fw}"
done

echo "== Chromium / Electron tree sanity =="
test -d src/third_party/blink || { echo "ERROR: src tree incomplete (no blink)"; exit 1; }
test -d src/electron || { echo "ERROR: src/electron missing"; exit 1; }
test -f src/electron/patches/chromium/.patches || { echo "ERROR: no chromium patches list"; exit 1; }
echo "HEAD electron: $(git -C src/electron rev-parse --short HEAD)"
echo "chromium_version pin:"
grep -A1 "'chromium_version'" src/electron/DEPS | head -3
echo "TimeBack crash patches present:"
grep -E 'fix_(devtools_fetch|httpcache_done|videocapture_host|win_videocapture)' \
  src/electron/patches/chromium/.patches

echo "== PGO profiles =="
# Electron stores release PGO under src/electron/build/pgo_profiles (state files +
# CDN blobs). Chromium's src/chrome/build/pgo_profiles is the wrong tree — the
# build resolves Electron state files via
# build_resolve_pgo_profiles_from_electron_state_files.patch.
PGO_DIR="src/electron/build/pgo_profiles"
python3 src/electron/script/pgo/download-profiles.py \
  --targets "${TARGET_PLATFORM}-${TARGET_ARCH},v8-builtins"
test -d "$PGO_DIR" || {
  echo "ERROR: PGO dir missing at ${PGO_DIR}"
  exit 1
}
ls -lh "$PGO_DIR" | head -30
# Require the arch state file and at least one downloaded profile blob.
test -f "${PGO_DIR}/${TARGET_PLATFORM}-${TARGET_ARCH}.pgo.txt" || {
  echo "ERROR: missing PGO state file for ${TARGET_PLATFORM}-${TARGET_ARCH}"
  exit 1
}
PROFILE_COUNT="$(find "$PGO_DIR" -maxdepth 1 \( -name '*.profdata' -o -name '*.profile' \) | wc -l | tr -d ' ')"
if [ "${PROFILE_COUNT}" -lt 1 ]; then
  echo "ERROR: no PGO profile blobs under ${PGO_DIR}"
  exit 1
fi
echo "PGO profile blobs: ${PROFILE_COUNT}"

echo "== GN generate (no compile) =="
export CHROMIUM_BUILDTOOLS_PATH="${CHROMIUM_BUILDTOOLS_PATH:-$(pwd)/src/buildtools}"
GN_EXTRA_ARGS="override_electron_version=\"${ELECTRON_VERSION}\""
# --gen only writes ninja files; does not compile.
CI=1 GN_EXTRA_ARGS="${GN_EXTRA_ARGS}" e build --no-remote --gen only

test -f "${OUT_DIR}/build.ninja" || { echo "ERROR: build.ninja not generated at ${OUT_DIR}"; exit 1; }
echo "generated: ${OUT_DIR}/build.ninja"
echo "args.gn:"
cat "${OUT_DIR}/args.gn"

# Confirm target_cpu matches the job.
if ! grep -q "target_cpu.*=.*\"${TARGET_ARCH}\"" "${OUT_DIR}/args.gn" \
  && ! gn args "${OUT_DIR}" --list=target_cpu 2>/dev/null | grep -q "${TARGET_ARCH}"; then
  # Host-native configs may omit target_cpu when it matches the host; verify via gn.
  ACTUAL_CPU="$(gn args "${OUT_DIR}" --list=target_cpu --short 2>/dev/null | awk '{print $NF}' | tr -d '"' || true)"
  echo "gn target_cpu: ${ACTUAL_CPU:-unknown}"
  if [ -n "${ACTUAL_CPU}" ] && [ "${ACTUAL_CPU}" != "${TARGET_ARCH}" ]; then
    echo "ERROR: GN target_cpu=${ACTUAL_CPU} != TARGET_ARCH=${TARGET_ARCH}"
    exit 1
  fi
fi

echo "== Ninja dry-run for electron:electron_dist_zip =="
if ! ninja -C "${OUT_DIR}" -t targets depth 1 2>/dev/null | grep -q 'electron:electron_dist_zip\|electron_dist_zip'; then
  # targets depth listing formats vary; fall back to asking ninja to resolve the edge.
  echo "(target list probe inconclusive; relying on dry-run resolve)"
fi

# -n: print commands, do not execute. Failure here means the graph cannot build
# the dist zip (missing deps / bad GN), not a compile error.
ninja -C "${OUT_DIR}" -n electron:electron_dist_zip >"${TMPDIR_PROBE}/dryrun.txt"
DRY_LINES="$(wc -l < "${TMPDIR_PROBE}/dryrun.txt" | tr -d ' ')"
echo "dry-run command lines: ${DRY_LINES}"
if [ "${DRY_LINES}" -lt 1 ]; then
  echo "ERROR: ninja dry-run produced no commands (nothing to do / missing target?)"
  exit 1
fi

# Surface the eventual Electron Framework / Helper link lines so a missing
# framework or sysroot shows up in the Actions log before the real compile.
echo "== Sample link / framework references from dry-run =="
grep -E 'Electron Framework|Electron Helper|ld64|framework WebKit|libchrome_dll' \
  "${TMPDIR_PROBE}/dryrun.txt" | head -40 || {
  echo "WARNING: no Electron Framework/Helper link lines in first-pass dry-run excerpt"
  echo "(first edges are often codegen; showing tail instead)"
  tail -40 "${TMPDIR_PROBE}/dryrun.txt"
}

echo "== Preflight PASSED for macos-${TARGET_ARCH} (NINJA_J=${NINJA_J:-default}) =="
