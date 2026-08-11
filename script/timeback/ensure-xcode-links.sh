#!/usr/bin/env bash
# Recreate out/*/xcode_links after an out-cache restore.
#
# The symlink tree is excluded from S3. Restored build.ninja still references
# xcode_links/electron/MacOSX*.sdk — the link MUST resolve to that exact SDK
# version. Pointing MacOSX26.4.sdk at the runner's default MacOSX.sdk (26.5)
# recompiles objects with SDK 26.5 module flags; ThinLTO then fails when mixed
# with cached 26.4 objects ("SDK Version conflicting values").
#
# Preference order for the real SDK directory:
#   1) Electron hermetic SDK (~/.electron_build_tools/third_party/SDKs/)
#   2) Exact MacOSX<ver>.sdk under any installed Xcode
#   3) Fail (never silently substitute a different major.minor)
#
# Usage: ensure-xcode-links.sh <out_dir>
set -euo pipefail

OUT_DIR="${1:?out_dir required}"
ARGS_GN="${OUT_DIR}/args.gn"
LINK_DIR="${OUT_DIR}/xcode_links/electron"

if [ ! -d "$OUT_DIR" ]; then
  echo "ensure-xcode-links: missing $OUT_DIR" >&2
  exit 1
fi

SDK_NAME="MacOSX.sdk"
if [ -f "$ARGS_GN" ]; then
  # mac_sdk_path = "//out/Release/xcode_links/electron/MacOSX26.4.sdk"
  extracted="$(sed -n 's/.*xcode_links\/electron\/\([^"/]*\)".*/\1/p' "$ARGS_GN" | head -1 || true)"
  if [ -n "$extracted" ]; then
    SDK_NAME="$extracted"
  fi
fi

# MacOSX26.4.sdk → 26.4
SDK_VER="$(printf '%s' "$SDK_NAME" | sed -n 's/^MacOSX\([0-9][0-9]*\.[0-9][0-9]*\)\.sdk$/\1/p')"

resolve_sdk_root() {
  local candidate
  # Hermetic SDK downloaded by @electron/build-tools (see e init logs).
  candidate="${HOME}/.electron_build_tools/third_party/SDKs/${SDK_NAME}"
  if [ -d "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  candidate="${HOME}/.electron_build_tools/third_party/SDKs/MacOSX.sdk"
  if [ -n "$SDK_VER" ] && [ -d "$candidate" ]; then
    # Some extractions use MacOSX.sdk; verify SDKSettings version if present.
    if [ -f "$candidate/SDKSettings.plist" ] \
      && plutil -extract CanonicalName raw "$candidate/SDKSettings.plist" 2>/dev/null \
        | grep -q "$SDK_VER"; then
      printf '%s' "$candidate"
      return 0
    fi
  fi

  # Exact versioned SDK inside any Xcode.app on the machine.
  local found
  found="$(find /Applications -path '*/Platforms/MacOSX.platform/Developer/SDKs/'"${SDK_NAME}" \
    -type d 2>/dev/null | head -1 || true)"
  if [ -n "$found" ]; then
    printf '%s' "$found"
    return 0
  fi

  return 1
}

if ! SDK_ROOT="$(resolve_sdk_root)"; then
  echo "ensure-xcode-links: cannot find exact SDK ${SDK_NAME}" >&2
  echo "Refusing to link a different SDK version (causes ThinLTO SDK Version conflicts)." >&2
  echo "Looked under ~/.electron_build_tools/third_party/SDKs and /Applications/*/SDKs/" >&2
  ls -la "${HOME}/.electron_build_tools/third_party/SDKs" 2>/dev/null || true
  exit 1
fi

# Guard: resolved path must not be a different versioned SDK dir.
case "$(basename "$SDK_ROOT")" in
  MacOSX.sdk|"$SDK_NAME") ;;
  *)
    echo "ensure-xcode-links: refused unexpected SDK path $SDK_ROOT" >&2
    exit 1
    ;;
esac

mkdir -p "$LINK_DIR"
ln -sfn "$SDK_ROOT" "${LINK_DIR}/${SDK_NAME}"

DEFS="${LINK_DIR}/${SDK_NAME}/usr/include/mach/exc.defs"
if [ ! -f "$DEFS" ]; then
  echo "ensure-xcode-links: missing $DEFS (link target $SDK_ROOT)" >&2
  ls -la "$LINK_DIR" >&2 || true
  exit 1
fi

# Confirm we did not accidentally point at the live 26.5 system SDK.
LIVE="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [ -n "$LIVE" ] && [ "$(stat -f '%i' "$SDK_ROOT" 2>/dev/null || echo a)" = \
     "$(stat -f '%i' "$LIVE" 2>/dev/null || echo b)" ] \
   && [ -n "$SDK_VER" ] && [ "$SDK_VER" != "$(xcrun --show-sdk-version 2>/dev/null || true)" ]; then
  echo "ensure-xcode-links: ERROR linked SDK inode matches live SDKROOT but versions differ" >&2
  echo "  linked=$SDK_ROOT live=$LIVE live_ver=$(xcrun --show-sdk-version)" >&2
  exit 1
fi

echo "xcode_links: ${LINK_DIR}/${SDK_NAME} -> ${SDK_ROOT}"
