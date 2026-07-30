#!/usr/bin/env python3
"""Thin out ninja's per-edge progress lines without losing anything else.

A release build emits one line per edge across ~100k edges, which buries the
interesting output and hits the log limits that leave the Actions UI frozen
hours behind the build. Progress lines are reduced to one every INTERVAL
seconds; everything else -- compiler diagnostics, FAILED blocks, ninja's own
messages -- is passed through untouched and immediately.

Usage: <build command> 2>&1 | throttle-build-output.py [interval_seconds]
"""

import re
import sys
import time

DEFAULT_INTERVAL_SECONDS = 10.0

PROGRESS = re.compile(r"^\[(\d+)/(\d+)\]")


def main() -> int:
    interval = DEFAULT_INTERVAL_SECONDS
    if len(sys.argv) > 1:
        interval = float(sys.argv[1])

    last_emit = 0.0
    pending = None
    suppressed = 0

    for line in sys.stdin:
        if not PROGRESS.match(line):
            # Flush the newest progress line first so diagnostics keep their
            # position in the build, then pass the line through verbatim.
            if pending is not None:
                sys.stdout.write(pending)
                pending = None
                suppressed = 0
            sys.stdout.write(line)
            sys.stdout.flush()
            continue

        pending = line
        suppressed += 1
        now = time.monotonic()
        if now - last_emit >= interval:
            sys.stdout.write(line.rstrip("\n") + f"  (+{suppressed - 1} since last update)\n")
            sys.stdout.flush()
            last_emit = now
            pending = None
            suppressed = 0

    if pending is not None:
        sys.stdout.write(pending)
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
