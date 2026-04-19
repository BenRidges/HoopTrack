"""
config.py — single source of truth for auto-labeling behaviour.

Edit this file to tune prompts, class mapping, and thresholds. Every
autolabel.py run hashes this file and records the hash in the output
manifest, so changes here are tracked.
"""

# Model — HuggingFace transformers port. Weights auto-download on first use.
#   tiny: ~200 MB, faster, slightly lower accuracy
#   base: ~400 MB, recommended default for 500–3000 frame batches
MODEL_ID = "IDEA-Research/grounding-dino-base"

# Grounding DINO uses period-separated text queries. Order matters slightly
# for which label the detector prefers when two match — put the most
# specific phrase first.
PROMPT = "basketball . basketball rim . basketball hoop . person"

# Map any output label (lowercased) to a YOLO class index. Outputs NOT in
# this map get dropped — expected for odd DINO labels like "hand",
# "shadow", "net". Drop counts are recorded in the manifest.
#
# YOLO class indices must match the training dataset (basketball-xil7x,
# alphabetical: ball=0, human=1, rim=2).
LABEL_MAP: dict[str, int] = {
    "basketball": 0,
    "ball": 0,
    "person": 1,
    "human": 1,
    "basketball rim": 2,
    "basketball hoop": 2,
    "rim": 2,
    "hoop": 2,
}

# Class names for display (index → name). Must match basketball-xil7x
# schema so YOLO data.yaml generation stays consistent.
CLASS_NAMES: list[str] = ["ball", "human", "rim"]

# Confidence threshold on raw Grounding DINO scores. DINO calibration
# differs from YOLO — 0.35 is tuned empirically for basketball footage.
#   0.45+ → stricter, fewer false positives, more missed balls
#   0.25  → higher recall, more review work needed
CONFIDENCE_THRESHOLD = 0.35

# Text-similarity threshold — DINO returns a separate score for how well
# a detected region matches the prompt text. Leave at 0.25 unless
# prompts are firing on obviously wrong things.
TEXT_THRESHOLD = 0.25

# Max detections per class per frame. Real sessions almost never have
# more than 1 ball / 1 rim visible. People can have a few.
MAX_PER_CLASS = {
    0: 2,  # ball — 2 allows for rebound / two-ball drills
    1: 5,  # human
    2: 2,  # rim — 2 allows for dual-rim gym shots
}


def config_hash() -> str:
    """SHA-256 hash of this file's source — used in run manifests."""
    import hashlib
    from pathlib import Path
    return "sha256:" + hashlib.sha256(
        Path(__file__).read_bytes()
    ).hexdigest()[:16]
