#!/usr/bin/env bash
# Prove a restored out/Release will resume before spending hours compiling.
set -euo pipefail

# After restore we delete build.ninja so gn can regenerate xcode_links; the
# resulting dry-run often lists ~30-50k edges (mostly cheap COPY_BUNDLE_DATA)
# even when the heavy compile outputs are already present. 20k was rejecting
# healthy resumes. 100k still catches a true cold rebuild (~200k+ pending).
readonly MAX_PENDING_EDGES="${MAX_PENDING_EDGES:-100000}"
readonly OUT_DIR="${OUT_DIR:-src/out/Release}"
readonly REQUIRED_OUTPUTS=(
  ".ninja_log"
  ".ninja_deps"
  "args.gn"
  "obj/electron/electron_framework_shared_library/Electron Framework"
)

for output in "${REQUIRED_OUTPUTS[@]}"; do
  test -s "$OUT_DIR/$output" || {
    echo "resume preflight failed: missing $OUT_DIR/$output" >&2
    exit 1
  }
done

completed_edges=$(wc -l < "$OUT_DIR/.ninja_log" | tr -d ' ')
framework_bytes=$(stat -f '%z' "$OUT_DIR/obj/electron/electron_framework_shared_library/Electron Framework")

dry_run=$(mktemp)
trap 'rm -f "$dry_run"' EXIT

# `e build` regenerates GN before invoking ninja. Use the same entrypoint so
# cwd/root/.gn resolution matches the real compile (raw `e d gn gen src/out/...`
# fails with "Can't find source root" on macOS runners).
CI=1 e build --gen=only --no-remote

# Dry-run the regenerated graph. This executes no build edge.
# Workflow cwd is the repo root (parent of src/), so -C takes src/out/Release.
e d autoninja -C "$OUT_DIR" -n electron > "$dry_run" 2>&1 || {
  echo "resume preflight failed: ninja dry-run errored" >&2
  tail -100 "$dry_run" >&2
  exit 1
}

pending_edges=$(python3 - "$dry_run" <<'PY'
import re
import sys

maximum = 0
pattern = re.compile(r"^\[(\d+)/(\d+)\]")
with open(sys.argv[1], errors="replace") as stream:
    for line in stream:
        match = pattern.match(line)
        if match:
            maximum = max(maximum, int(match.group(2)))
print(maximum)
PY
)

echo "resume preflight:"
echo "  completed edges recorded: $completed_edges"
echo "  Electron Framework bytes: $framework_bytes"
echo "  pending dry-run edges:     $pending_edges"
echo "  allowed maximum:           $MAX_PENDING_EDGES"

if [ "$pending_edges" -eq 0 ]; then
  echo "cache is already build-complete"
elif [ "$pending_edges" -gt "$MAX_PENDING_EDGES" ]; then
  echo "resume preflight failed: cache would rebuild too much" >&2
  tail -100 "$dry_run" >&2
  exit 1
else
  echo "resume preflight passed: ninja will reuse the restored outputs"
fi
