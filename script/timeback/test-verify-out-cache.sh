#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/src/out/Release/obj/electron/electron_framework_shared_library"
printf '# ninja log\n' > "$TEMP_DIR/src/out/Release/.ninja_log"
printf 'deps\n' > "$TEMP_DIR/src/out/Release/.ninja_deps"
printf 'args\n' > "$TEMP_DIR/src/out/Release/args.gn"
printf 'framework\n' > "$TEMP_DIR/src/out/Release/obj/electron/electron_framework_shared_library/Electron Framework"

cat > "$TEMP_DIR/bin/e" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "d autoninja" ]; then
  # Before GN regeneration, the stale graph looks safe.
  if [ ! -f .gn-regenerated ]; then
    printf '[1/10000] stale graph\n'
  else
    printf '[1/25713] regenerated graph\n'
  fi
  exit 0
fi
if [ "$1 $2" = "d gn" ]; then
  test "${GN_EXTRA_ARGS:-}" = 'override_electron_version="43.2.0-timeback.1"' || exit 3
  touch .gn-regenerated
  exit 0
fi
exit 2
EOF
chmod +x "$TEMP_DIR/bin/e"

set +e
(
  cd "$TEMP_DIR"
  PATH="$TEMP_DIR/bin:$PATH" \
    GN_EXTRA_ARGS='override_electron_version="43.2.0-timeback.1"' \
    OUT_DIR=src/out/Release \
    MAX_PENDING_EDGES=20000 \
    "$SCRIPT_DIR/verify-out-cache.sh"
) > "$TEMP_DIR/output" 2>&1
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "FAIL: stale graph passed without GN regeneration"
  cat "$TEMP_DIR/output"
  exit 1
fi
if ! grep -q '25713' "$TEMP_DIR/output"; then
  echo "FAIL: preflight did not inspect the regenerated graph"
  cat "$TEMP_DIR/output"
  exit 1
fi

echo "PASS: regenerated 25713-edge graph is rejected"
