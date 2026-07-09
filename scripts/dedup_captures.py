#!/usr/bin/env python3
"""dedup_captures.py — delete PNG captures whose file contents are identical.

Rationale: a batch iteration that fails to refresh the board view will
snapshot the previous position under the NEW hash — the on-disk PNG
looks fine, but its content matches the neighbours'. Two files with
identical bytes therefore mean at least one of them is training-data
poison: the SFEN in the filename disagrees with what's actually in the
image. Since we cannot tell WHICH one is the honest capture, we drop
every member of every dupe group, letting the batch runner recapture
them from scratch (its upfront filter will notice the missing files).

Usage
-----
Preview (default, no writes):

    python3 scripts/dedup_captures.py path/to/piyo_capture/screen

Actually delete duplicates:

    python3 scripts/dedup_captures.py path/to/piyo_capture/screen --delete

Run against the JB device via SSH (no Python needed on the phone —
scp the file over, or read+delete on the host after pulling):

    scp -P 2222 root@host.docker.internal:/var/mobile/.../piyo_capture/screen /tmp/screen-cap
    python3 scripts/dedup_captures.py /tmp/screen-cap --delete
    # then re-push whatever remains, or just let the runner recapture

Exit code 0 always; the report prints the groups + counts.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from collections import defaultdict
from pathlib import Path

BUF = 1 << 20  # 1 MiB streaming buffer


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(BUF), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dir", type=Path, help="Directory of PNGs to scan.")
    ap.add_argument(
        "--delete",
        action="store_true",
        help="Actually delete duplicate files (default is dry-run).",
    )
    ap.add_argument(
        "--pattern",
        default="*.png",
        help="Glob to match (default: *.png).",
    )
    args = ap.parse_args()

    root: Path = args.dir
    if not root.is_dir():
        print(f"error: {root} is not a directory", file=sys.stderr)
        return 2

    files = sorted(root.glob(args.pattern))
    print(f"scanning {len(files)} files under {root}")
    by_content: dict[str, list[Path]] = defaultdict(list)
    for i, p in enumerate(files, 1):
        by_content[sha256_of(p)].append(p)
        if i % 500 == 0 or i == len(files):
            print(f"  hashed {i}/{len(files)}")

    dups = {h: paths for h, paths in by_content.items() if len(paths) > 1}
    if not dups:
        print("no duplicate content found. clean.")
        return 0

    total_dup_files = sum(len(v) for v in dups.values())
    print(
        f"found {len(dups)} duplicate content-hashes, "
        f"{total_dup_files} files total across all groups"
    )
    print("top 5 largest duplicate groups:")
    top = sorted(dups.items(), key=lambda kv: -len(kv[1]))[:5]
    for content_hash, paths in top:
        print(f"  [{len(paths)} copies] {content_hash[:12]}…")
        for p in paths[:3]:
            print(f"      {p.name}")
        if len(paths) > 3:
            print(f"      … +{len(paths) - 3} more")

    if not args.delete:
        print(
            f"\ndry-run complete. re-run with --delete to remove all "
            f"{total_dup_files} files."
        )
        return 0

    removed = 0
    for paths in dups.values():
        for p in paths:
            try:
                p.unlink()
                removed += 1
            except OSError as e:
                print(f"  warning: could not delete {p}: {e}", file=sys.stderr)
    print(f"deleted {removed} duplicate files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
