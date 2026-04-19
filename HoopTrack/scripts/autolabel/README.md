# autolabel

Offline auto-labeling pipeline for HoopTrack CV training data. Lives
next to `build_basketball_model.py` so all model-related tooling stays
in one repo.

Uses Grounding DINO (HuggingFace port — `IDEA-Research/grounding-dino-base`)
to auto-label frames captured from on-device CV-A telemetry, producing
YOLO-format labels ready to merge into the training pipeline at
[../build_basketball_model.py](../build_basketball_model.py).

Designed to run on a local CUDA GPU (e.g. RTX 3080). No cloud, no SaaS,
no repo clones — just `pip install` and `python`.

---

## Why this tool exists

The public Roboflow datasets that trained the shipped `BallDetector.mlmodel`
don't match real HoopTrack footage (different lighting, angles, ball
colour, court type, occlusion patterns). Closing that distribution gap
requires real captured frames — and labeling 500–3000 of them by hand
is unacceptable solo.

Grounding DINO is an open-vocabulary detector: prompt it with text
("basketball", "basketball rim", "person") and it draws boxes for you.
Quality is ~80% on typical basketball footage; the remaining 20% gets
caught in the review gallery before training.

---

## One-time setup

```bash
cd HoopTrack/scripts/autolabel
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

First `autolabel.py` run downloads `grounding-dino-base` weights
(~400 MB) into the HuggingFace cache. No manual weight management.

---

## Workflow

### 1. Tune prompts on a handful of frames

```bash
python preview.py --images /path/to/captured/frames --sample 12
```

Generates `preview.png` — a 4×3 grid of sample frames with detections
overlaid. Iterate on `config.py` prompts until boxes look right on a
representative sample. Typical tuning takes 2–5 minutes.

### 2. Auto-label the full batch

```bash
python autolabel.py --images /path/to/captured/frames --output runs/session_01
```

Writes:
- `runs/session_01/images/*.jpg` — copies of input frames
- `runs/session_01/labels/*.txt` — YOLO-format labels (one per image)
- `runs/session_01/manifest.json` — config hash, git SHA, date, stats
- `runs/session_01/review.html` — self-contained visual review page

### 3. Review in the browser

```bash
open runs/session_01/review.html
```

Each frame is rendered with its auto-labels overlaid as boxes. Keyboard:
`j` / `k` to move, `d` to mark a frame for deletion. Marked frames
accumulate in `delete_list.txt` (saved via the "Export" button).

### 4. Apply review decisions

```bash
python apply_review.py --run runs/session_01
```

Removes frames listed in `delete_list.txt` from `images/` and `labels/`.

### 5. Hand off to training

The `runs/session_01/` directory now matches the YOLO layout
`build_basketball_model.py` expects. Merge it into your Roboflow
dataset or train directly:

```bash
# Option A: add a data.yaml and train in-place
# Option B: upload to Roboflow as a new dataset version
```

---

## Class mapping

Edit `config.py` to change prompts / mapping. Current defaults target
the `basketball-xil7x` schema:

| YOLO class | Index | Grounding DINO prompts |
|---|---|---|
| ball | 0 | "basketball", "ball" |
| human | 1 | "person", "human" |
| rim | 2 | "basketball rim", "basketball hoop", "rim", "hoop" |

Grounding DINO outputs any label NOT in the map get dropped silently
with a `manifest.json` count.

---

## Known issues & mitigations

| Issue | Mitigation |
|---|---|
| Prompts "rim" and "hoop" trigger false positives on tires, wheels, earrings | Use `"basketball rim"` or `"basketball hoop"` — the modifier anchors context. Defaults in `config.py` already include both. |
| Grounding DINO confidence isn't calibrated like YOLO | Default threshold 0.35 is tuned for basketball-xil7x-style footage. Raise to 0.45 for stricter output; lower to 0.25 for more recall before review. |
| Low-light frames produce noisy boxes | Review gallery — mark for deletion. |
| Labels shift slightly from frame-to-frame on stationary rim | Fine for training — a little label noise actually regularises the detector. |

---

## Output format

YOLO v5/v8/v11 label format, one line per detection:

```
<class_id> <cx_norm> <cy_norm> <w_norm> <h_norm>
```

All coords normalised 0–1 relative to image dimensions.

---

## Versioning

Every `autolabel.py` run writes a `manifest.json`:

```json
{
  "run_id": "2026-04-19-session_01",
  "git_sha": "abc123...",
  "config_hash": "sha256:...",
  "model": "IDEA-Research/grounding-dino-base",
  "prompts": "basketball . person . basketball rim",
  "confidence_threshold": 0.35,
  "input_dir": "/path/to/captured/frames",
  "frame_count": 347,
  "detections_total": 891,
  "label_drops_unmapped": 12,
  "timestamp": "2026-04-19T10:33:21Z"
}
```

Combined with git-tracking `config.py`, every output run is fully
reproducible.
