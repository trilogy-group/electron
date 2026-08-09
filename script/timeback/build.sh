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
  local args="override_electron_version=\"${ELECTRON_VERSION}\""
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
