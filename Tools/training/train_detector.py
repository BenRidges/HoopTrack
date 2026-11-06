#!/usr/bin/env python3
"""
train_detector.py: train, check and export HoopTrack's ball/basket detector.

Replaces hooptrack-ball-detection/scripts/build_basketball_model.py and
export_coreml.py (see docs/training-review-2026-11.md for why):

  * one image size end to end (640): what it trains at is what ships
  * classes always [ball, basket, person], in that order, whatever the
    source datasets call them (rim/hoop → basket, human/player → person)
  * HoopTrack's own frames (Tools/dataset/build_dataset.py) are mixed in,
    and their val split is the test that matters
  * a gate: the new model must not do worse than the shipped one on
    HoopTrack frames, or nothing is installed
  * FP16 ML Program (.mlpackage) with NMS, not a 44 MB FP32 .mlmodel
  * no pip installs at run time: install requirements.txt into a venv

Licence: Ultralytics and the models it trains are AGPL-3.0. Shipping one in
a closed App Store app needs an Ultralytics Enterprise licence. See the
review doc for the alternatives before the next App Store build.

Run on a Mac (Core ML export needs macOS or Linux; Windows exports the old
format). Training is fine on any CUDA box; export there with --skip-export
and export on the Mac with --export-only.

    python3 -m venv .venv && .venv/bin/pip install -r Tools/training/requirements.txt
    .venv/bin/python Tools/training/train_detector.py \\
        --data ~/datasets/roboflow-basketball ~/hooptrack-dataset \\
        --hooptrack-val ~/hooptrack-dataset \\
        --baseline ~/models/ballDetector-2026-04.pt
"""

import argparse
import datetime
import json
import shutil
import sys
from pathlib import Path

CLASSES = ["ball", "basket", "person"]
SYNONYMS = {
    "ball": "ball", "basketball": "ball", "sports ball": "ball",
    "basket": "basket", "rim": "basket", "hoop": "basket", "basketball hoop": "basket", "net": "basket",
    "person": "person", "human": "person", "player": "person",
}
IMAGE_SIZE = 640
REPO = Path(__file__).resolve().parents[2]
APP_MODEL_DIR = REPO / "HoopTrack" / "HoopTrack" / "ML"


def load_yaml_names(data_yaml):
    """A YOLO data.yaml and its class names, lower-cased, in id order."""
    import yaml
    data = yaml.safe_load(Path(data_yaml).read_text(encoding="utf-8"))
    names = data["names"]
    if isinstance(names, dict):
        names = [names[k] for k in sorted(names, key=int)]
    return data, [str(n).strip().lower() for n in names]


def resolve_split(source, data, split):
    """The images folder for a split. Roboflow writes paths like
    '../train/images' that only work from one particular folder."""
    entry = data.get(split) or (data.get("valid") if split == "val" else None)
    if not entry:
        return None
    root = Path(data.get("path") or source)
    if not root.is_absolute():
        root = source / root
    plain = Path(*[p for p in Path(entry).parts if p not in ("..", ".")])
    for candidate in (root / entry, source / entry, source / plain):
        if candidate.resolve().is_dir():
            return candidate.resolve()
    return None


def labels_for(image_dir):
    """YOLO keeps labels in a sibling tree: the last 'images' becomes 'labels'."""
    parts = list(image_dir.parts)
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == "images":
            parts[i] = "labels"
            return Path(*parts)
    return image_dir.parent / "labels"


def merge_datasets(sources, work):
    """Copies every source into one YOLO dataset with the app's class ids."""
    for split in ("train", "val"):
        (work / "images" / split).mkdir(parents=True, exist_ok=True)
        (work / "labels" / split).mkdir(parents=True, exist_ok=True)

    for index, source in enumerate(sources):
        source = Path(source).expanduser().resolve()
        data, names = load_yaml_names(source / "data.yaml")
        remap = {}
        for i, name in enumerate(names):
            target = SYNONYMS.get(name)
            if target is None:
                print(f"  {source.name}: dropping unknown class '{name}'")
                continue
            remap[i] = CLASSES.index(target)
        print(f"  {source.name}: " + ", ".join(f"{names[i]}→{CLASSES[c]}" for i, c in remap.items()))

        for split in ("train", "val"):
            image_dir = resolve_split(source, data, split)
            if image_dir is None:
                print(f"  {source.name}: no {split} images found")
                continue
            label_dir = labels_for(image_dir)
            for image in sorted(image_dir.glob("*")):
                if image.suffix.lower() not in (".jpg", ".jpeg", ".png"):
                    continue
                stem = f"s{index}_{image.stem}"
                shutil.copy2(image, work / "images" / split / f"{stem}{image.suffix.lower()}")
                lines = []
                label = label_dir / f"{image.stem}.txt"
                if label.is_file():
                    for line in label.read_text(encoding="utf-8").splitlines():
                        parts = line.split()
                        if len(parts) == 5 and int(parts[0]) in remap:
                            lines.append(" ".join([str(remap[int(parts[0])])] + parts[1:]))
                (work / "labels" / split / f"{stem}.txt").write_text(
                    "\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")

    yaml_path = work / "data.yaml"
    yaml_path.write_text(
        f"path: {work}\ntrain: images/train\nval: images/val\nnames:\n"
        + "".join(f"  {i}: {n}\n" for i, n in enumerate(CLASSES)), encoding="utf-8")
    return yaml_path


def per_class_map50(model_path, data_yaml, device):
    """mAP@0.5 for ball and basket on a dataset's val split."""
    from ultralytics import YOLO
    metrics = YOLO(str(model_path)).val(data=str(data_yaml), imgsz=IMAGE_SIZE, device=device,
                                        split="val", plots=False, verbose=False)
    # ap50 has one entry per class present in the val set, in the order of
    # ap_class_index, not by class id.
    scores = {}
    for j, cls in enumerate(metrics.box.ap_class_index):
        name = metrics.names[int(cls)]
        if name in ("ball", "basket"):
            scores[name] = float(metrics.box.ap50[j])
    return scores


def pick_device():
    import torch
    if torch.cuda.is_available():
        return "0"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def export_and_install(weights, version, install):
    from ultralytics import YOLO
    import coremltools as ct

    exported = Path(YOLO(str(weights)).export(format="coreml", imgsz=IMAGE_SIZE, nms=True, half=True))
    if exported.suffix != ".mlpackage":
        sys.exit(f"export produced {exported.name}, not an .mlpackage; export on a Mac or Linux")

    model = ct.models.MLModel(str(exported))
    model.short_description = "HoopTrack ball / basket detector"
    model.version = version
    model.user_defined_metadata["classes"] = ",".join(CLASSES)
    model.user_defined_metadata["imgsz"] = str(IMAGE_SIZE)
    model.save(str(exported))
    print(f"exported {exported}")

    if not install:
        return
    for stale in (APP_MODEL_DIR / "BallDetector.mlmodel", APP_MODEL_DIR / "BallDetector.mlpackage"):
        if stale.is_dir():
            shutil.rmtree(stale)
        elif stale.exists():
            stale.unlink()
    shutil.copytree(exported, APP_MODEL_DIR / "BallDetector.mlpackage")
    print(f"""installed {APP_MODEL_DIR / 'BallDetector.mlpackage'}
Next:
  * Xcode: check BallDetector.mlpackage has the HoopTrack target ticked
    (File Inspector), and that the old .mlmodel is gone from the project.
  * Set HoopTrack.MLModel.modelVersion to "{version}" in Constants.swift.
  * Replay a few logged sessions with shot-eval before shipping.""")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", nargs="+", help="YOLO datasets (folders with data.yaml) to train on")
    parser.add_argument("--hooptrack-val", help="dataset from build_dataset.py; its val split is the gate")
    parser.add_argument("--baseline", help="weights of the model in the app now (.pt), to compare with")
    parser.add_argument("--model", default="yolo11m.pt",
                        help="starting weights (default yolo11m.pt; try yolo11s.pt if the phone runs hot)")
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--batch", type=int, default=16)
    parser.add_argument("--work", default="runs/hooptrack", help="scratch folder (default runs/hooptrack)")
    parser.add_argument("--tolerance", type=float, default=0.01,
                        help="how much worse than the baseline (mAP@0.5) still passes (default 0.01)")
    parser.add_argument("--force", action="store_true", help="install even if the gate fails")
    parser.add_argument("--skip-export", action="store_true", help="train and check only")
    parser.add_argument("--export-only", metavar="WEIGHTS", help="just export (and install) these weights")
    parser.add_argument("--no-install", action="store_true", help="export but don't copy into the app")
    args = parser.parse_args()

    version = datetime.date.today().isoformat()
    if args.export_only:
        export_and_install(Path(args.export_only), version, install=not args.no_install)
        return
    if not args.data:
        parser.error("--data is required unless --export-only")

    from ultralytics import YOLO

    work = Path(args.work).expanduser().resolve()
    merged = work / "dataset"
    if merged.exists():
        shutil.rmtree(merged)
    print("merging datasets")
    data_yaml = merge_datasets(args.data, merged)

    device = pick_device()
    print(f"training {args.model} at {IMAGE_SIZE} on {device}")
    results = YOLO(args.model).train(
        data=str(data_yaml), imgsz=IMAGE_SIZE, epochs=args.epochs, batch=args.batch,
        device=device, project=str(work), name="train", exist_ok=True,
        patience=20, seed=0, deterministic=True,
        # Phone footage: no vertical flips (balls fall down), mild colour shifts.
        flipud=0.0, fliplr=0.5, hsv_v=0.3, degrees=0.0)
    best = Path(results.save_dir) / "weights" / "best.pt"

    report = {"version": version, "weights": str(best), "data": args.data}
    passed = True
    if args.hooptrack_val:
        gate_yaml = Path(args.hooptrack_val).expanduser() / "data.yaml"
        report["candidate"] = per_class_map50(best, gate_yaml, device)
        print(f"candidate on HoopTrack val: {report['candidate']}")
        if args.baseline:
            report["baseline"] = per_class_map50(args.baseline, gate_yaml, device)
            print(f"baseline  on HoopTrack val: {report['baseline']}")
            for name, old in report["baseline"].items():
                new = report["candidate"].get(name, 0.0)
                if new < old - args.tolerance:
                    print(f"GATE: {name} mAP@0.5 fell from {old:.3f} to {new:.3f}")
                    passed = False
    else:
        print("no --hooptrack-val: nothing checks the model on HoopTrack's own footage")
    report["passed"] = passed
    (work / f"report-{version}.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    if not passed and not args.force:
        sys.exit("not installed: the new model is worse on HoopTrack frames (use --force to override)")
    if not args.skip_export:
        export_and_install(best, version, install=not args.no_install)


if __name__ == "__main__":
    main()
