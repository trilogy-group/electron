#!/usr/bin/env bash
# Straight Electron release compile (no out-dir checkpoint / resume).
#
# Env:
#   ELECTRON_VERSION  required (override_electron_version)
#   NINJA_J           optional; forwarded as `e build -j N`
#   GN_CC_WRAPPER     optional sccache path
set -euo pipefail

: "${ELECTRON_VERSION:?ELECTRON_VERSION is required}"

gn_extra_args() {
  # override_electron_version stamps our npm/release version.
  # symbol_level=0 + chrome_pgo_phase=0 shave substantial compile/link time so
  # macOS larger-runner jobs can fit under GitHub's hard 6h cap (cross x64 was
  # ~2h short at 59k/79k). Crash-fix semantics are unchanged; re-enable PGO
  # later if we need official-perf parity.
  local args="override_electron_version=\"${ELECTRON_VERSION}\" symbol_level=0 blink_symbol_level=0 v8_symbol_level=0 chrome_pgo_phase=0"
  if [ -n "${GN_CC_WRAPPER:-}" ]; then
    args="$args cc_wrapper=\"${GN_CC_WRAPPER}\""
  fi
  printf '%s' "$args"
}

echo "Building Electron ${ELECTRON_VERSION} (NINJA_J=${NINJA_J:-default})"
if [ -n "${NINJA_J:-}" ]; then
  CI=1 GN_EXTRA_ARGS="$(gn_extra_args)" e build --no-remote -j "$NINJA_J"
else
  CI=1 GN_EXTRA_ARGS="$(gn_extra_args)" e build --no-remote
fi
