#!/usr/bin/env python3
"""
apply_review.py — apply delete flags exported from review.html.

After reviewing runs/<id>/review.html in the browser and clicking
"Export delete_list.txt", drop that file into runs/<id>/ and run:

    python apply_review.py --run runs/session_01

Removes the flagged frames from both images/ and labels/, updates
manifest.json with the new frame count, and writes a sibling
removed/ directory holding the deleted files in case you want to
recover any.
"""

import argparse
import json
import shutil
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--run", type=Path, required=True,
                   help="Run directory (the one containing manifest.json)")
    p.add_argument("--list", type=Path, default=None,
                   help="Path to delete_list.txt (default: <run>/delete_list.txt)")
    p.add_argument("--dry-run", action="store_true",
                   help="Report what would be removed without changing files")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    run = args.run
    delete_list = args.list or (run / "delete_list.txt")

    if not (run / "manifest.json").exists():
        sys.exit(f"No manifest.json at {run} — is this a valid run directory?")
    if not delete_list.exists():
        sys.exit(f"delete_list.txt not found at {delete_list}")

    flagged = {line.strip() for line in delete_list.read_text().splitlines() if line.strip()}
    if not flagged:
        print("delete_list.txt is empty — nothing to do.")
        return

    print(f"Flagged for removal: {len(flagged)} frames")
    if args.dry_run:
        for name in sorted(flagged):
            print(f"  would remove {name}")
        return

    removed_dir = run / "removed"
    (removed_dir / "images").mkdir(parents=True, exist_ok=True)
    (removed_dir / "labels").mkdir(parents=True, exist_ok=True)

    removed = 0
    for name in flagged:
        img = run / "images" / name
        lbl = run / "labels" / (Path(name).stem + ".txt")
        if img.exists():
            shutil.move(str(img), str(removed_dir / "images" / name))
            removed += 1
        if lbl.exists():
            shutil.move(str(lbl), str(removed_dir / "labels" / lbl.name))

    # Refresh manifest
    manifest_path = run / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    remaining = sum(1 for _ in (run / "images").iterdir())
    manifest["frame_count_after_review"] = remaining
    manifest["frames_removed"] = removed
    manifest_path.write_text(json.dumps(manifest, indent=2))

    print(f"Removed {removed} frames. {remaining} frames remain in {run}/images/")
    print(f"Backups: {removed_dir}")


if __name__ == "__main__":
    main()
