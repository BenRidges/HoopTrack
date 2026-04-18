#!/usr/bin/env python3
"""
export_coreml.py
Exports an already-trained YOLO .pt checkpoint to BallDetector.mlpackage
and drops it into HoopTrack/ML/.

Must be run on macOS or Linux (including WSL2) — CoreML export is blocked on
native Windows by ultralytics/coremltools.

Usage:
  # From the repo root, with the venv activated:
  python HoopTrack/scripts/export_coreml.py [path/to/best.pt]

If no path is given, defaults to C:\\tmp\\basketball_train\\run\\weights\\best.pt
(Windows host path) or /mnt/c/tmp/basketball_train/run/weights/best.pt (WSL).
"""

import sys, shutil, platform
from pathlib import Path

try:
    # Patch ultralytics' hard Windows block BEFORE importing YOLO so the
    # exporter sees WINDOWS=False. The block exists because coremltools'
    # BlobWriter isn't available on Windows for the modern .mlpackage
    # (MLProgram) format — but the legacy .mlmodel (NeuralNetwork) format
    # works fine, which is what we fall back to below.
    import ultralytics.engine.exporter as _exporter
    _exporter.WINDOWS = False
    from ultralytics import YOLO
except ImportError:
    sys.exit("ultralytics not installed. Run: pip install ultralytics coremltools")


def default_weights_path() -> Path:
    # WSL mounts the Windows C: drive at /mnt/c
    if platform.system() == "Linux" and Path("/mnt/c").exists():
        return Path("/mnt/c/tmp/basketball_train/run/weights/best.pt")
    # macOS / plain Linux: /tmp/basketball_train (same as the training script)
    return Path("/tmp/basketball_train/run/weights/best.pt")


def main():
    SCRIPT_DIR   = Path(__file__).resolve().parent
    PROJECT_ROOT = SCRIPT_DIR.parent
    DEST_DIR     = PROJECT_ROOT / "HoopTrack" / "ML"
    DEST_NAME    = "BallDetector"
    IMG_SIZE     = 640

    if len(sys.argv) > 1:
        best_weights = Path(sys.argv[1]).expanduser().resolve()
    else:
        best_weights = default_weights_path()

    if not best_weights.exists():
        sys.exit(f"Weights file not found: {best_weights}\n"
                 f"Pass the path explicitly: python export_coreml.py /path/to/best.pt")

    # On Windows, coremltools' BlobWriter isn't available, so .mlpackage export
    # fails. Use the legacy neuralnetwork backend (.mlmodel) which doesn't
    # require BlobWriter. Vision on iOS accepts both formats.
    use_mlmodel = platform.system() == "Windows"
    fmt = "mlmodel" if use_mlmodel else "coreml"
    ext = "mlmodel" if use_mlmodel else "mlpackage"

    print(f"📦  Exporting {best_weights} to CoreML ({ext}) …")
    trained = YOLO(str(best_weights))
    export_path = trained.export(format=fmt, nms=True, imgsz=IMG_SIZE)

    src = Path(str(best_weights).replace(".pt", f".{ext}"))
    if not src.exists():
        src = Path(str(export_path))

    print(f"    Exported to: {src}")

    dest = DEST_DIR / f"{DEST_NAME}.{ext}"
    if dest.exists():
        print(f"♻️  Removing existing model at {dest}")
        if dest.is_dir():
            shutil.rmtree(dest)
        else:
            dest.unlink()

    DEST_DIR.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        shutil.copytree(str(src), str(dest))
    else:
        shutil.copy2(str(src), str(dest))
    print(f"\n✅  BallDetector.{ext} installed at:\n    {dest}")


if __name__ == "__main__":
    main()
