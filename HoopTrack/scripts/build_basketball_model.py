#!/usr/bin/env python3
"""
build_basketball_model.py
Downloads the Roboflow basketball-detection dataset, fine-tunes YOLOv8s,
and exports BallDetector.mlpackage straight into HoopTrack/ML/ with NMS
embedded so Vision's VNRecognizedObjectObservation path parses it.

Requirements (auto-installed if missing):
  pip install ultralytics roboflow coremltools

Setup:
  export ROBOFLOW_API_KEY=your_key_here   # required

Usage:
  python3 scripts/build_basketball_model.py

Takes ~60-90 min on Apple Silicon (M-series) at the current 40-epoch /
yolov8s config. Adjust EPOCHS and BASE_MODEL in the config block below
if training time is the main constraint.
"""

import subprocess, sys, shutil, os
from pathlib import Path

# ── 0. Install dependencies if needed ─────────────────────────────────────────
def pip_install(*packages):
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", *packages])

try:
    import ultralytics
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
    WORKSPACE        = "computer-vision-d5fjh"
    PROJECT_NAME     = "basketball-detection-dn6fg"
    VERSION          = 4

    # YOLOv8s — small model, noticeably better accuracy than nano at ~2× training
    # time. Swap to "yolov8n.pt" if training time is the bigger constraint.
    BASE_MODEL = "yolov8s.pt"
    EPOCHS     = 40          # 10 left the model underfit; 40 lands solid results
                             # on Apple Silicon in ~60-90 min for yolov8s.
    IMG_SIZE   = 640
    BATCH      = 8           # conservative — increase to 16 if you have 16 GB RAM+

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
    DATASET_DIR = Path("/tmp/basketball_dataset")

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

    if dest.exists():
        print(f"\n♻️  Removing existing model at {dest}")
        shutil.rmtree(dest)

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
