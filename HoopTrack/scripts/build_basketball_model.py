#!/usr/bin/env python3
"""
build_basketball_model.py
Downloads a Roboflow basketball dataset, fine-tunes YOLO11m, and exports
BallDetector.mlpackage straight into HoopTrack/ML/ with NMS embedded so
Vision's VNRecognizedObjectObservation path parses it.

Requirements (auto-installed if missing):
  pip install ultralytics roboflow coremltools

Setup:
  export ROBOFLOW_API_KEY=your_key_here   # required

Usage:
  python3 scripts/build_basketball_model.py

At 100 epochs / yolo11m / imgsz=1280, expect ~4-8 hrs on a 3080 depending
on dataset size. Adjust EPOCHS, BASE_MODEL, or IMG_SIZE in the config
block below to trade accuracy for training time.
"""

import subprocess, sys, shutil, os, platform
from pathlib import Path

# ── 0. Install dependencies if needed ─────────────────────────────────────────
def pip_install(*packages):
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", *packages])

try:
    import ultralytics
    # YOLO11 support landed in 8.3.0. Upgrade if an older build is cached.
    from packaging.version import parse as _parse
    if _parse(ultralytics.__version__) < _parse("8.3.0"):
        print(f"Upgrading ultralytics from {ultralytics.__version__} (YOLO11 needs ≥8.3.0) …")
        pip_install("-U", "ultralytics")
except ImportError:
    print("Installing ultralytics …")
    pip_install("ultralytics")
    import ultralytics

try:
    import roboflow
except ImportError:
    print("Installing roboflow …")
    pip_install("roboflow")
    import roboflow

try:
    import coremltools
except ImportError:
    print("Installing coremltools …")
    pip_install("coremltools")

# Auto-load .env at the repo root so ROBOFLOW_API_KEY (and any future secrets)
# are picked up without the caller having to `export` them per-shell. Silent
# no-op if the file doesn't exist.
try:
    from dotenv import load_dotenv
except ImportError:
    print("Installing python-dotenv …")
    pip_install("python-dotenv")
    from dotenv import load_dotenv
_env_path = Path(__file__).resolve().parent.parent.parent / ".env"
if _env_path.exists():
    load_dotenv(_env_path)

from ultralytics import YOLO
import torch


def main():
    # ── 1. Config ──────────────────────────────────────────────────────────────────
    SCRIPT_DIR   = Path(__file__).resolve().parent
    PROJECT_ROOT = SCRIPT_DIR.parent                  # HoopTrack project root
    DEST_DIR     = PROJECT_ROOT / "HoopTrack" / "ML"
    DEST_NAME    = "BallDetector"                     # final .mlpackage name (no ext)

    ROBOFLOW_API_KEY = os.environ.get("ROBOFLOW_API_KEY")
    if not ROBOFLOW_API_KEY:
        sys.exit(
            "ROBOFLOW_API_KEY is not set.\n"
            "Export it in your shell before running this script, e.g.:\n"
            "  export ROBOFLOW_API_KEY=your_key_here\n"
            "  python3 scripts/build_basketball_model.py"
        )
    WORKSPACE        = "cricket-qnb5l"
    PROJECT_NAME     = "basketball-xil7x"
    VERSION          = 1

    # YOLO11m — current Ultralytics SOTA for real-time detection, ~2% mAP over
    # yolov8 at same FLOPs. Medium size lands ~15-20ms on iPhone Neural Engine
    # at imgsz=1280, still comfortably under a 30fps budget. Swap to
    # "yolo11l.pt" for ~2 more mAP points and ~30ms inference.
    BASE_MODEL = "yolo11m.pt"
    EPOCHS     = 100         # training time no longer a constraint; diminishing
                             # returns past ~100 epochs with early-stopping patience.
    IMG_SIZE   = 1280        # 2x resolution — big gain on small-ball detection
                             # in wide-angle court footage. Memory-heavy; if the
                             # 3080 OOMs, drop to 960 before reducing batch.
    BATCH      = 8           # yolo11m @ 1280 on a 10GB 3080. AMP is on by default
                             # via ultralytics. Bump to 12-16 if VRAM allows.

    # ── 2. Auto-detect best device ────────────────────────────────────────────────
    if torch.backends.mps.is_available():
        device = "mps"
        print("✓ Apple Silicon (MPS) detected — training will be fast.")
    elif torch.cuda.is_available():
        device = "0"
        print("✓ CUDA GPU detected.")
    else:
        device = "cpu"
        print("⚠  No GPU detected — training on CPU. This will take a while.")

    # ── 3. Download dataset from Roboflow ─────────────────────────────────────────
    # Path keyed on project+version so swapping datasets forces a fresh download
    # (older cached dataset at /tmp/basketball_dataset from a prior run would
    # otherwise be reused silently with overwrite=False).
    DATASET_DIR = Path(f"/tmp/roboflow_{PROJECT_NAME}_v{VERSION}")

    print("\n📥  Downloading basketball dataset from Roboflow …")
    rf = roboflow.Roboflow(api_key=ROBOFLOW_API_KEY)
    project  = rf.workspace(WORKSPACE).project(PROJECT_NAME)
    version  = project.version(VERSION)
    dataset  = version.download("yolov8", location=str(DATASET_DIR), overwrite=False)
    data_yaml = Path(dataset.location) / "data.yaml"
    print(f"    Dataset saved to: {dataset.location}")

    # ── 4. Fine-tune YOLOv8n ──────────────────────────────────────────────────────
    TRAIN_DIR = Path("/tmp/basketball_train")

    print(f"\n🏋  Fine-tuning {BASE_MODEL} for {EPOCHS} epochs on device={device} …")
    model   = YOLO(BASE_MODEL)
    results = model.train(
        data    = str(data_yaml),
        epochs  = EPOCHS,
        imgsz   = IMG_SIZE,
        batch   = BATCH,
        device  = device,
        project = str(TRAIN_DIR),
        name    = "run",
        exist_ok= True,
        verbose = False,
    )
    best_weights = Path(results.save_dir) / "weights" / "best.pt"
    print(f"    Best weights: {best_weights}")

    # ── 5. Export to CoreML (.mlpackage) ──────────────────────────────────────────
    print("\n📦  Exporting to CoreML …")
    trained = YOLO(str(best_weights))
    export_path = trained.export(format="coreml", nms=True, imgsz=IMG_SIZE)
    # ultralytics saves it next to the weights file
    mlpackage_src = Path(str(best_weights).replace(".pt", ".mlpackage"))

    if not mlpackage_src.exists():
        # Fallback: ultralytics sometimes puts it in the cwd or export_path
        mlpackage_src = Path(str(export_path))

    print(f"    Exported to: {mlpackage_src}")

    # ── 6. Copy into HoopTrack/ML/ ────────────────────────────────────────────────
    dest = DEST_DIR / f"{DEST_NAME}.mlpackage"

    # Remove both possible artifact forms before installing the new one.
    # Xcode compiles .mlpackage and .mlmodel into the same
    # BallDetector.mlmodelc — having both in the source tree produces a
    # 'duplicate output file' build error.
    for stale in (DEST_DIR / f"{DEST_NAME}.mlpackage",
                  DEST_DIR / f"{DEST_NAME}.mlmodel"):
        if stale.exists():
            print(f"\n♻️  Removing existing model at {stale}")
            if stale.is_dir():
                shutil.rmtree(stale)
            else:
                stale.unlink()

    DEST_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copytree(str(mlpackage_src), str(dest))
    print(f"\n✅  BallDetector.mlpackage installed at:\n    {dest}")

    # ── 7. Print next step ────────────────────────────────────────────────────────
    print("""
─────────────────────────────────────────────────────────
Next: open Xcode, drag HoopTrack/ML/BallDetector.mlpackage
into the Project Navigator if it isn't there already,
make sure 'Add to target: HoopTrack' is checked, then
build in Release to exercise the bundled model path.

The class label 'ball' is already set in Constants.swift.
─────────────────────────────────────────────────────────
""")


if __name__ == "__main__":
    main()
