#!/usr/bin/env bash
# Local end-to-end test of the npm publish path — no CI, no Chromium compile.
#
# Exercises everything the publish workflow does except talking to GitHub:
#   stub dist zips -> checksums.json -> prepare-npm-package.js -> npm pack
#   -> npm install the tarball -> require() -> assert the binary is on disk
#
# The mirror is a throwaway local HTTP server, so @electron/get performs a real
# download and a real checksum verification against a real URL layout
# (<mirror>/v<version>/electron-v<version>-<platform>-<arch>.zip).
#
# Run this before pushing changes to the publish pipeline:
#   bash script/timeback/test-prepare-npm-package.sh
#
# Exits non-zero on the first failure and prints what broke.

set -euo pipefail

# Must stay semver->=1.3.2: @electron/get skips checksum verification entirely for
# anything below that, so a 0.0.0-* test version would silently not test checksums.
VERSION="${VERSION:-43.2.0-localtest.1}"
PLATFORMS="${PLATFORMS:-darwin-arm64 win32-x64}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "workdir: $WORK"
echo "version: $VERSION"
echo "repo:    $REPO_ROOT"
echo

# ---------------------------------------------------------------- stub dist zips
mkdir -p "$WORK/mirror/v$VERSION"
for target in $PLATFORMS; do
  platform="${target%-*}"
  arch="${target##*-}"
  stage="$WORK/stage-$target"
  mkdir -p "$stage"

  if [ "$platform" = "darwin" ]; then
    bin="$stage/Electron.app/Contents/MacOS/Electron"
  else
    bin="$stage/electron.exe"
  fi
  mkdir -p "$(dirname "$bin")"
  printf '#!/bin/sh\necho "stub electron %s (%s)"\n' "$VERSION" "$target" > "$bin"
  chmod +x "$bin"
  echo "v$VERSION" > "$stage/version"

  zip_name="electron-v$VERSION-$platform-$arch.zip"
  ( cd "$stage" && zip -qr "$WORK/mirror/v$VERSION/$zip_name" . )
  echo "built $zip_name"
done
echo

# ---------------------------------------------------------------- checksums.json
python3 - "$WORK/mirror/v$VERSION" "$WORK/checksums.json" <<'PY'
import hashlib, json, pathlib, sys
src = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
checksums = {}
for path in sorted(src.glob("*.zip")):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    checksums[path.name] = h.hexdigest()
out.write_text(json.dumps(checksums, indent=2) + "\n")
print("checksums:", json.dumps(checksums, indent=2))
PY
echo

# ---------------------------------------------------------------- serve mirror
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
( cd "$WORK/mirror" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >"$WORK/http.log" 2>&1 ) &
SERVER_PID=$!
MIRROR="http://127.0.0.1:$PORT/"

for _ in $(seq 1 40); do
  if curl -sfI "${MIRROR}v$VERSION/" -o /dev/null 2>/dev/null; then break; fi
  sleep 0.25
done
curl -sfI "${MIRROR}v$VERSION/" -o /dev/null || fail "local mirror never came up (see $WORK/http.log)"
echo "mirror: $MIRROR"
echo

# ---------------------------------------------------------------- stage package
STAGING="$WORK/npm-publish"
mkdir -p "$STAGING"
cp -R "$REPO_ROOT/npm/." "$STAGING/"
cp "$WORK/checksums.json" "$STAGING/checksums.json"
[ -f "$STAGING/electron.d.ts" ] || echo '// stub types' > "$STAGING/electron.d.ts"
[ -f "$STAGING/abi_version" ] || echo '0' > "$STAGING/abi_version"

ELECTRON_VERSION="$VERSION" TIMEBACK_ELECTRON_MIRROR="$MIRROR" \
  node "$REPO_ROOT/script/timeback/prepare-npm-package.js" "$STAGING" \
  || fail "prepare-npm-package.js rejected the staging dir"
echo

# Guard the two fields that silently break installs if the rewrite regresses.
node -e '
  const fs = require("fs");
  const pkg = JSON.parse(fs.readFileSync(process.argv[1] + "/package.json", "utf8"));
  if (pkg.name !== "@trilogy-group/electron") throw new Error("bad name: " + pkg.name);
  if (pkg.version !== process.argv[2]) throw new Error("bad version: " + pkg.version);
  if (!pkg.files.includes("checksums.json")) throw new Error("checksums.json not in files list");
  const install = fs.readFileSync(process.argv[1] + "/install.js", "utf8");
  if (!install.includes("TIMEBACK_MIRROR_INJECTED")) throw new Error("mirror not injected");
  console.log("package.json and install.js look right");
' "$STAGING" "$VERSION" || fail "staged package failed field checks"
echo

# ---------------------------------------------------------------- pack + install
TARBALL="$STAGING/$(cd "$STAGING" && npm pack --silent | tail -1)"
[ -f "$TARBALL" ] || fail "npm pack produced no tarball"
echo "packed: $(basename "$TARBALL") ($(du -h "$TARBALL" | cut -f1))"

tar -tzf "$TARBALL" | grep -q 'package/checksums.json' \
  || fail "checksums.json was not packed — install.js require() would throw"
echo

failures=0
for target in $PLATFORMS; do
  platform="${target%-*}"
  arch="${target##*-}"
  echo "=== install as $platform-$arch ==="

  consumer="$WORK/consumer-$target"
  mkdir -p "$consumer"
  ( cd "$consumer" && npm init -y >/dev/null 2>&1 )

  if ! ( cd "$consumer" \
         && ELECTRON_INSTALL_PLATFORM="$platform" \
            ELECTRON_INSTALL_ARCH="$arch" \
            electron_config_cache="$consumer/cache" \
            npm install "$TARBALL" --no-audit --no-fund --silent ); then
    echo "  npm install FAILED"
    failures=$((failures + 1))
    continue
  fi

  # First require() triggers the lazy download from the mirror above.
  if ( cd "$consumer" \
       && ELECTRON_INSTALL_PLATFORM="$platform" \
          ELECTRON_INSTALL_ARCH="$arch" \
          electron_config_cache="$consumer/cache" \
          node -e '
            const fs = require("fs");
            const p = require("@trilogy-group/electron");
            if (typeof p !== "string") throw new Error("module did not export a path: " + p);
            if (!fs.existsSync(p)) throw new Error("binary missing on disk: " + p);
            console.log("  resolved:", p);
          ' ); then
    echo "  OK"
  else
    echo "  require() FAILED"
    failures=$((failures + 1))
  fi
  echo
done

if [ "$failures" -ne 0 ]; then
  fail "$failures platform(s) failed — publish pipeline would break the same way"
fi

# ---------------------------------------------------------------- tamper check
# The install above succeeding proves the happy path. This proves checksums.json is
# actually enforced: without it, a truncated or swapped Release asset would install
# silently and only fail at runtime.
echo "=== tamper check (corrupted asset must be rejected) ==="
first_target="${PLATFORMS%% *}"
first_platform="${first_target%-*}"
first_arch="${first_target##*-}"
tampered_zip="$WORK/mirror/v$VERSION/electron-v$VERSION-$first_platform-$first_arch.zip"
printf 'corrupted' >> "$tampered_zip"

tamper_consumer="$WORK/consumer-tampered"
mkdir -p "$tamper_consumer"
( cd "$tamper_consumer" && npm init -y >/dev/null 2>&1 )
( cd "$tamper_consumer" \
  && ELECTRON_INSTALL_PLATFORM="$first_platform" \
     ELECTRON_INSTALL_ARCH="$first_arch" \
     electron_config_cache="$tamper_consumer/cache" \
     npm install "$TARBALL" --no-audit --no-fund --silent )

if ( cd "$tamper_consumer" \
     && ELECTRON_INSTALL_PLATFORM="$first_platform" \
        ELECTRON_INSTALL_ARCH="$first_arch" \
        electron_config_cache="$tamper_consumer/cache" \
        node -e 'require("@trilogy-group/electron")' >/dev/null 2>&1 ); then
  fail "a corrupted $first_target asset installed successfully — checksum verification is NOT active"
fi
echo "  corrupted asset correctly rejected"
echo

echo "PASS: publish path works end to end for: $PLATFORMS"
