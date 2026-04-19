#!/usr/bin/env python3
"""
autolabel.py — run Grounding DINO over a directory of frames and emit
YOLO-format labels plus an offline review gallery.

Usage:
    python autolabel.py --images /path/to/frames --output runs/session_01
"""

import argparse
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import torch
from PIL import Image
from tqdm import tqdm
from transformers import AutoModelForZeroShotObjectDetection, AutoProcessor

import config
from gallery import build_review_gallery


IMAGE_EXTS = {".jpg", ".jpeg", ".png"}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--images", type=Path, required=True,
                   help="Directory of .jpg/.png frames to label")
    p.add_argument("--output", type=Path, required=True,
                   help="Output directory for labels + review gallery")
    p.add_argument("--device", default=None,
                   help="Override torch device (e.g. cuda:0, cpu). "
                        "Auto-detects CUDA if available.")
    p.add_argument("--limit", type=int, default=None,
                   help="Label only the first N frames (useful for quick sanity runs)")
    return p.parse_args()


def pick_device(override: str | None) -> str:
    if override:
        return override
    if torch.cuda.is_available():
        return "cuda:0"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def collect_frames(images_dir: Path, limit: int | None) -> list[Path]:
    if not images_dir.is_dir():
        sys.exit(f"--images must be a directory: {images_dir}")
    frames = sorted(
        p for p in images_dir.iterdir()
        if p.suffix.lower() in IMAGE_EXTS and p.is_file()
    )
    if not frames:
        sys.exit(f"No .jpg/.png files found in {images_dir}")
    if limit:
        frames = frames[:limit]
    return frames


def git_sha() -> str:
    """Short SHA of this labeling repo (not HoopTrack) — for manifest."""
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=Path(__file__).parent,
            stderr=subprocess.DEVNULL,
        )
        return out.decode().strip()
    except Exception:
        return "unknown"


def clamp(v: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, v))


def box_to_yolo(box: tuple[float, float, float, float],
                img_w: int, img_h: int) -> tuple[float, float, float, float]:
    """Convert (x1, y1, x2, y2) in pixels → YOLO (cx, cy, w, h) normalised."""
    x1, y1, x2, y2 = box
    cx = clamp((x1 + x2) / 2 / img_w)
    cy = clamp((y1 + y2) / 2 / img_h)
    w  = clamp((x2 - x1) / img_w)
    h  = clamp((y2 - y1) / img_h)
    return cx, cy, w, h


def label_frame(
    image: Image.Image,
    model,
    processor,
    device: str,
) -> tuple[list[dict], int]:
    """Run one frame through Grounding DINO. Returns (detections, drops).

    Each detection dict: {class_id, score, box_px: (x1,y1,x2,y2), raw_label}
    """
    inputs = processor(images=image, text=config.PROMPT, return_tensors="pt").to(device)
    with torch.no_grad():
        outputs = model(**inputs)

    results = processor.post_process_grounded_object_detection(
        outputs,
        inputs.input_ids,
        box_threshold=config.CONFIDENCE_THRESHOLD,
        text_threshold=config.TEXT_THRESHOLD,
        target_sizes=[image.size[::-1]],  # (h, w)
    )[0]

    detections: list[dict] = []
    drops = 0
    # Per-class counters for MAX_PER_CLASS enforcement
    per_class: dict[int, int] = {}

    # Sort by score descending so MAX_PER_CLASS keeps the best boxes
    order = sorted(range(len(results["scores"])),
                   key=lambda i: float(results["scores"][i]), reverse=True)

    for i in order:
        raw = str(results["labels"][i]).strip().lower()
        cls = config.LABEL_MAP.get(raw)
        if cls is None:
            drops += 1
            continue

        cap = config.MAX_PER_CLASS.get(cls, 999)
        if per_class.get(cls, 0) >= cap:
            continue
        per_class[cls] = per_class.get(cls, 0) + 1

        box = tuple(float(v) for v in results["boxes"][i].tolist())
        detections.append({
            "class_id": cls,
            "score": float(results["scores"][i]),
            "box_px": box,
            "raw_label": raw,
        })

    return detections, drops


def main() -> None:
    args = parse_args()
    device = pick_device(args.device)
    print(f"Device: {device}")

    frames = collect_frames(args.images, args.limit)
    print(f"Frames: {len(frames)}")

    out_dir = args.output
    (out_dir / "images").mkdir(parents=True, exist_ok=True)
    (out_dir / "labels").mkdir(parents=True, exist_ok=True)

    print(f"Loading {config.MODEL_ID} …")
    processor = AutoProcessor.from_pretrained(config.MODEL_ID)
    model = AutoModelForZeroShotObjectDetection.from_pretrained(config.MODEL_ID).to(device)
    model.eval()

    total_detections = 0
    total_drops = 0
    per_frame_records: list[dict] = []

    for frame_path in tqdm(frames, desc="Labeling"):
        try:
            image = Image.open(frame_path).convert("RGB")
        except Exception as exc:
            print(f"Skipping {frame_path.name}: {exc}")
            continue

        detections, drops = label_frame(image, model, processor, device)
        total_detections += len(detections)
        total_drops += drops

        img_w, img_h = image.size

        # Copy image into output
        dest_img = out_dir / "images" / frame_path.name
        if not dest_img.exists():
            shutil.copy2(frame_path, dest_img)

        # Write YOLO label file
        label_path = out_dir / "labels" / (frame_path.stem + ".txt")
        with label_path.open("w") as fh:
            for det in detections:
                cx, cy, w, h = box_to_yolo(det["box_px"], img_w, img_h)
                fh.write(f"{det['class_id']} {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}\n")

        per_frame_records.append({
            "image": frame_path.name,
            "width": img_w,
            "height": img_h,
            "detections": detections,
        })

    manifest = {
        "run_id": out_dir.name,
        "git_sha": git_sha(),
        "config_hash": config.config_hash(),
        "model": config.MODEL_ID,
        "prompt": config.PROMPT,
        "confidence_threshold": config.CONFIDENCE_THRESHOLD,
        "text_threshold": config.TEXT_THRESHOLD,
        "class_names": config.CLASS_NAMES,
        "input_dir": str(args.images.resolve()),
        "frame_count": len(per_frame_records),
        "detections_total": total_detections,
        "label_drops_unmapped": total_drops,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))

    print(f"\nLabeled {len(per_frame_records)} frames, "
          f"{total_detections} detections ({total_drops} unmapped drops).")

    print("Building review gallery …")
    build_review_gallery(out_dir, manifest, per_frame_records)
    print(f"Open: {out_dir / 'review.html'}")


if __name__ == "__main__":
    main()
