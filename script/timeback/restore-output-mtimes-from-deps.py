#!/usr/bin/env python3
"""Restore output mtimes from .ninja_deps so a restored out/ can resume.

Ninja records each compile output's mtime in .ninja_deps. On the next build it
trusts the deps list only if on-disk output mtime <= stored mtime
(graph.cc: output.mtime() > deps.mtime → "stored deps info out of date").

aws s3 sync sets local mtimes to S3 LastModified (checkpoint upload time),
which is newer than the compile-time mtime in the log — so every edge looks
dirty after a warm out-cache restore. touch(1) on *.o does the same.

This script parses .ninja_deps and sets each surviving output's mtime back to
the recorded value (nanoseconds). Pair with clamping *sources* older than
those outputs; do not touch the objects afterward.

Usage: restore-output-mtimes-from-deps.py <out_dir>
"""
from __future__ import annotations

import os
import struct
import sys

SIGNATURE = b"# ninjadeps\n"
VERSION = 4
MAX_RECORD = (1 << 19) - 1


def load_deps_log(path: str) -> dict[str, int]:
    """Return {relative_output_path: mtime_ns} for the latest record per output."""
    with open(path, "rb") as f:
        data = f.read()

    if not data.startswith(SIGNATURE):
        raise SystemExit(f"bad deps log signature: {path}")
    offset = len(SIGNATURE)
    (version,) = struct.unpack_from("<i", data, offset)
    offset += 4
    if version != VERSION:
        raise SystemExit(f"unsupported deps log version {version} (want {VERSION})")

    paths: list[str | None] = []
    # out_id -> mtime_ns ; last record wins
    deps: dict[int, int] = {}

    while offset + 4 <= len(data):
        (size_field,) = struct.unpack_from("<I", data, offset)
        offset += 4
        is_deps = (size_field >> 31) != 0
        size = size_field & 0x7FFFFFFF
        if size > MAX_RECORD or offset + size > len(data):
            break
        payload = data[offset : offset + size]
        offset += size

        if is_deps:
            if size % 4 != 0 or size < 12:
                break
            words = list(struct.unpack(f"<{size // 4}i", payload))
            out_id = words[0]
            mtime = ((words[2] & 0xFFFFFFFF) << 32) | (words[1] & 0xFFFFFFFF)
            input_ids = words[3:]
            if out_id < 0 or out_id >= len(paths) or paths[out_id] is None:
                continue
            if any(i < 0 or i >= len(paths) or paths[i] is None for i in input_ids):
                continue
            deps[out_id] = mtime
        else:
            if size < 4:
                break
            # payload: path + padding + checksum(4)
            path_bytes = payload[:-4]
            while path_bytes and path_bytes[-1] == 0:
                path_bytes = path_bytes[:-1]
            rel = path_bytes.decode("utf-8", errors="surrogateescape")
            paths.append(rel)

    out: dict[str, int] = {}
    for out_id, mtime in deps.items():
        p = paths[out_id]
        if p:
            out[p] = mtime
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <out_dir>", file=sys.stderr)
        return 2
    out_dir = sys.argv[1]
    deps_path = os.path.join(out_dir, ".ninja_deps")
    if not os.path.isfile(deps_path):
        print(f"no {deps_path}; nothing to restore")
        return 0

    entries = load_deps_log(deps_path)
    updated = 0
    missing = 0
    for rel, mtime_ns in entries.items():
        path = os.path.join(out_dir, rel)
        if not os.path.isfile(path):
            missing += 1
            continue
        # Match ninja's equality window: output mtime must not exceed stored.
        os.utime(path, ns=(mtime_ns, mtime_ns))
        updated += 1

    print(
        f"restored mtimes on {updated} outputs from .ninja_deps "
        f"({missing} missing, {len(entries)} deps entries)"
    )
    if entries and updated == 0:
        print(
            "ERROR: deps log has entries but no output mtimes were restored "
            "(wrong out_dir or empty tree?)",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
