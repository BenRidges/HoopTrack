#!/usr/bin/env python3
"""
build_dataset.py: turn shared HoopTrack sessions into a YOLO training set.

Each shared session (Profile → Privacy → "Help improve shot tracking") leaves
a folder with manifest.json, frame_NNNN.jpg and detections.jsonl, both on the
phone (Documents/Telemetry/<session id>/) and in the telemetry-sessions
bucket. This script collects any number of them into:

    OUT/images/{train,val}/*.jpg
    OUT/labels/{train,val}/*.txt   YOLO: class cx cy w h, normalised
    OUT/data.yaml                  classes 0 ball, 1 basket, 2 person
    OUT/review.csv                 every frame, most worth checking first

The labels are the app's own detections, so on their own they would only
teach the model what it already believes. They are a starting point: open
OUT in CVAT or Label Studio (YOLO import), fix frames from the top of
review.csv down, and only then train. review.csv ranks frames by where the
app is known or likely to have gone wrong:

    corrected    near a shot the tracker called and the player corrected
    by_hand      near a shot logged by hand (the tracker didn't see it)
    undone       near a call the tracker made that was undone afterwards
    unsure       near a call flagged for review
    flicker      the ball detection dropped out for a few frames
    weak_box     a box under --min-confidence was dropped from the labels

Sessions are split into train and val whole (by a hash of the session id),
so near-identical frames from one session never land on both sides.

Standard library only. Python 3.9+.

    python3 Tools/dataset/build_dataset.py ~/telemetry-download --out ~/hooptrack-dataset
"""

import argparse
import csv
import hashlib
import json
import shutil
import sys
from pathlib import Path

CLASSES = ["ball", "basket", "person"]   # same order as the bundled model
NEAR_SHOT_SEC = 1.5                       # frames this close to a shot inherit its reasons
REASON_WEIGHT = {"corrected": 4, "undone": 3, "by_hand": 3, "unsure": 2, "flicker": 2, "weak_box": 1}


def find_sessions(roots):
    for root in roots:
        root = Path(root).expanduser()
        if (root / "manifest.json").is_file():
            yield root
        else:
            yield from sorted(p.parent for p in root.rglob("manifest.json"))


def read_log_calls(session_dir):
    """Times of the make/miss calls the app published, from detections.jsonl."""
    path = session_dir / "detections.jsonl"
    if not path.is_file():
        return []
    entries = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            try:
                entries.append(json.loads(line))
            except ValueError:
                continue
    # "cv" is the call as published (after the net check). Logs from before
    # the net check only have the tracker's "ev".
    key = "cv" if any("cv" in e for e in entries) else "ev"
    return [float(e["t"]) for e in entries if e.get(key) in ("make", "miss") and "t" in e]


def shot_marks(manifest, log_calls):
    """(time, reason) pairs around which frames are worth a look."""
    shots = manifest.get("shots", [])
    marks = []
    auto_times = []
    for shot in shots:
        t = float(shot["video_sec"])
        auto = shot.get("auto_confidence") is not None
        if auto:
            auto_times.append(t)
        if auto and shot.get("user_corrected"):
            marks.append((t, "corrected"))
        elif not auto:
            marks.append((t, "by_hand"))
        if shot.get("needs_review"):
            marks.append((t, "unsure"))
    # A call is published a second or two after the release it was timed
    # from. One with no saved auto shot just before it was undone.
    for t in log_calls:
        if not any(t - 4.0 <= s <= t + 0.1 for s in auto_times):
            marks.append((t - 1.0, "undone"))
    return marks


def yolo_lines(detections, min_confidence, review_band):
    lines, weak = [], 0
    for det in detections:
        if det.get("label") not in CLASSES:
            continue
        conf = float(det.get("confidence", 0))
        if conf < min_confidence:
            if conf >= review_band:
                weak += 1
            continue
        x, y, w, h = (float(v) for v in det["box"][:4])
        # Clip to the image, then centre form.
        x0, y0 = max(0.0, x), max(0.0, y)
        x1, y1 = min(1.0, x + w), min(1.0, y + h)
        if x1 <= x0 or y1 <= y0:
            continue
        cls = CLASSES.index(det["label"])
        lines.append(f"{cls} {(x0 + x1) / 2:.6f} {(y0 + y1) / 2:.6f} {x1 - x0:.6f} {y1 - y0:.6f}")
    return lines, weak


def is_val(session_id, fraction):
    digest = hashlib.sha1(session_id.encode("utf-8")).hexdigest()
    return int(digest[:8], 16) / 0xFFFFFFFF < fraction


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sessions", nargs="+", help="session folders, or folders containing them")
    parser.add_argument("--out", required=True, help="dataset folder to create")
    parser.add_argument("--val-fraction", type=float, default=0.2, help="share of sessions held out (default 0.2)")
    parser.add_argument("--min-confidence", type=float, default=0.5,
                        help="detections below this are left out of the labels (default 0.5)")
    parser.add_argument("--review-band", type=float, default=0.2,
                        help="dropped detections at or above this mark the frame for review (default 0.2)")
    args = parser.parse_args()

    out = Path(args.out).expanduser()
    if out.exists() and any(out.iterdir()):
        sys.exit(f"{out} isn't empty; pick a new folder so old labels aren't mixed in.")
    for split in ("train", "val"):
        (out / "images" / split).mkdir(parents=True, exist_ok=True)
        (out / "labels" / split).mkdir(parents=True, exist_ok=True)

    rows = []
    totals = {"sessions": 0, "skipped": 0, "train": 0, "val": 0}
    for session_dir in find_sessions(args.sessions):
        try:
            manifest = json.loads((session_dir / "manifest.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            print(f"skip {session_dir}: {error}")
            totals["skipped"] += 1
            continue
        if manifest.get("schema_version", 1) < 2:
            # Version 1 manifests carry no boxes: every frame would look empty.
            print(f"skip {session_dir.name}: manifest from before boxes were recorded")
            totals["skipped"] += 1
            continue

        session_id = manifest["session_id"]
        split = "val" if is_val(session_id, args.val_fraction) else "train"
        marks = shot_marks(manifest, read_log_calls(session_dir))
        totals["sessions"] += 1

        for frame in manifest["frames"]:
            image = session_dir / frame["file"]
            if not image.is_file():
                continue
            name = f"{session_id[:8]}_{Path(frame['file']).stem}"
            lines, weak = yolo_lines(frame.get("detections", []), args.min_confidence, args.review_band)

            t = float(frame["timestamp_sec"])
            reasons = sorted({reason for when, reason in marks if abs(when - t) <= NEAR_SHOT_SEC})
            if frame.get("trigger") == "flicker":
                reasons.append("flicker")
            if weak:
                reasons.append("weak_box")
            priority = sum(REASON_WEIGHT[r] for r in reasons)

            shutil.copy2(image, out / "images" / split / f"{name}.jpg")
            (out / "labels" / split / f"{name}.txt").write_text(
                "\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
            totals[split] += 1
            rows.append({
                "priority": priority,
                "image": f"images/{split}/{name}.jpg",
                "split": split,
                "reasons": " ".join(reasons),
                "balls": sum(1 for l in lines if l.startswith("0 ")),
                "baskets": sum(1 for l in lines if l.startswith("1 ")),
                "session": session_id,
                "video_sec": f"{t:.3f}",
                "model": manifest.get("model_version", ""),
            })

    rows.sort(key=lambda r: (-r["priority"], r["image"]))
    with (out / "review.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["priority", "image"])
        writer.writeheader()
        writer.writerows(rows)

    (out / "data.yaml").write_text(
        f"path: {out.resolve()}\ntrain: images/train\nval: images/val\nnames:\n"
        + "".join(f"  {i}: {name}\n" for i, name in enumerate(CLASSES)),
        encoding="utf-8")

    flagged = sum(1 for r in rows if r["priority"] >= 3)
    print(f"{totals['sessions']} sessions ({totals['skipped']} skipped): "
          f"{totals['train']} train frames, {totals['val']} val frames")
    print(f"{flagged} frames to check first (priority ≥ 3), listed at the top of {out / 'review.csv'}")


if __name__ == "__main__":
    main()
