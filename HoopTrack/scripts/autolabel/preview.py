#!/usr/bin/env python3
"""
preview.py — run Grounding DINO on a handful of sample frames and render
a 4-column grid with detections drawn. For iterating on prompts and
thresholds in config.py before committing to a full autolabel.py run.

Usage:
    python preview.py --images /path/to/frames --sample 12
    open preview.png
"""

import argparse
import random
import sys
from pathlib import Path

import torch
from PIL import Image, ImageDraw, ImageFont
from transformers import AutoModelForZeroShotObjectDetection, AutoProcessor

import config
from autolabel import collect_frames, label_frame, pick_device


CLASS_COLORS = [
    (255, 107, 53),    # ball — orange
    (61, 156, 255),    # human — blue
    (60, 220, 120),    # rim — green
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--images", type=Path, required=True)
    p.add_argument("--sample", type=int, default=12,
                   help="How many frames to run (default 12 — a 4×3 grid)")
    p.add_argument("--output", type=Path, default=Path("preview.png"))
    p.add_argument("--seed", type=int, default=None,
                   help="Seed for deterministic sampling")
    p.add_argument("--device", default=None)
    return p.parse_args()


def draw_detections(image: Image.Image, detections: list[dict]) -> Image.Image:
    out = image.copy()
    draw = ImageDraw.Draw(out)

    try:
        font = ImageFont.truetype(
            "/System/Library/Fonts/Helvetica.ttc", size=max(14, image.height // 40)
        )
    except Exception:
        font = ImageFont.load_default()

    for det in detections:
        cls = det["class_id"]
        color = CLASS_COLORS[cls % len(CLASS_COLORS)]
        x1, y1, x2, y2 = det["box_px"]
        draw.rectangle([x1, y1, x2, y2], outline=color, width=3)

        label = f"{config.CLASS_NAMES[cls]} {det['score']:.2f}"
        text_w = draw.textlength(label, font=font)
        text_h = font.size + 4
        draw.rectangle(
            [x1, y1 - text_h, x1 + text_w + 6, y1],
            fill=color,
        )
        draw.text((x1 + 3, y1 - text_h + 1), label, fill=(0, 0, 0), font=font)

    return out


def build_grid(cells: list[Image.Image], cols: int = 4) -> Image.Image:
    if not cells:
        sys.exit("Nothing to render — no frames sampled.")

    cell_w = max(c.width for c in cells)
    cell_h = max(c.height for c in cells)
    rows = (len(cells) + cols - 1) // cols

    grid = Image.new("RGB", (cell_w * cols, cell_h * rows), (20, 20, 20))
    for i, cell in enumerate(cells):
        r, c = divmod(i, cols)
        # Centre the cell if it's smaller than the grid cell
        ox = c * cell_w + (cell_w - cell.width) // 2
        oy = r * cell_h + (cell_h - cell.height) // 2
        grid.paste(cell, (ox, oy))
    return grid


def main() -> None:
    args = parse_args()
    device = pick_device(args.device)
    print(f"Device: {device}")

    frames = collect_frames(args.images, limit=None)
    if args.seed is not None:
        random.seed(args.seed)
    sample = random.sample(frames, k=min(args.sample, len(frames)))
    print(f"Sampling {len(sample)} of {len(frames)} frames")
    print(f"Prompt: {config.PROMPT}")
    print(f"Confidence threshold: {config.CONFIDENCE_THRESHOLD}")

    print(f"Loading {config.MODEL_ID} …")
    processor = AutoProcessor.from_pretrained(config.MODEL_ID)
    model = AutoModelForZeroShotObjectDetection.from_pretrained(config.MODEL_ID).to(device)
    model.eval()

    cells: list[Image.Image] = []
    for p in sample:
        image = Image.open(p).convert("RGB")
        detections, _drops = label_frame(image, model, processor, device)
        # Downscale very large frames before drawing so grid stays manageable
        if image.width > 1280:
            scale = 1280 / image.width
            image = image.resize((1280, int(image.height * scale)))
            for det in detections:
                det["box_px"] = tuple(v * scale for v in det["box_px"])
        cells.append(draw_detections(image, detections))

    grid = build_grid(cells, cols=4)
    grid.save(args.output)
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
