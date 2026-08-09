#!/usr/bin/env bash
# Unzip a freshly packaged Electron dist zip and prove it is a good binary before
# it can be published: it must report our version and carry the fetch-intercept
# patch set. A bad binary fails the same run instead of shipping.
#
# Usage: smoke-test.sh <artifact-zip> <macos|windows> <expected-version>
set -euo pipefail

ARTIFACT="${1:?artifact zip path required}"
PLATFORM="${2:?platform required (macos|windows)}"
EXPECTED_VERSION="${3:?expected version required}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== smoke: unpacking $ARTIFACT ==="
unzip -q "$ARTIFACT" -d "$WORK/app"

case "$PLATFORM" in
  macos)
    BIN="$(find "$WORK/app" -type f -path '*/Electron.app/Contents/MacOS/Electron' | head -1)"
    ;;
  windows)
    BIN="$(find "$WORK/app" -maxdepth 2 -type f -iname 'electron.exe' | head -1)"
    ;;
  *)
    echo "smoke: unknown platform '$PLATFORM'" >&2; exit 2 ;;
esac

if [ -z "${BIN:-}" ] || [ ! -f "$BIN" ]; then
  echo "smoke: could not find the Electron binary under $WORK/app" >&2
  find "$WORK/app" -maxdepth 3 -iname 'electron*' >&2 || true
  exit 2
fi
chmod +x "$BIN" 2>/dev/null || true
echo "=== smoke: binary $BIN ==="

echo "=== smoke: --version ==="
VERSION_OUT="$("$BIN" --version)"
echo "$VERSION_OUT"
case "$VERSION_OUT" in
  *"$EXPECTED_VERSION"*) : ;;
  *) echo "smoke: --version '$VERSION_OUT' does not contain '$EXPECTED_VERSION'" >&2; exit 1 ;;
esac

echo "=== smoke: patched-behaviour probe (headless main process) ==="
SMOKE_APP="$WORK/smoke-app"
mkdir -p "$SMOKE_APP"
printf '{"name":"tb-smoke","version":"1.0.0","main":"main.js"}\n' > "$SMOKE_APP/package.json"
cp "$(dirname "$0")/smoke-test-binary.js" "$SMOKE_APP/main.js"

SMOKE_EXPECTED_VERSION="$EXPECTED_VERSION" \
  "$BIN" "$SMOKE_APP" --no-sandbox

echo "=== smoke: OK ==="
