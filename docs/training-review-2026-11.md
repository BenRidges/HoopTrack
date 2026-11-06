# Detector training review: November 2026

This reviews how `ML/BallDetector.mlmodel` was made. The training code lives
in `hooptrack-ball-detection`, which isn't in this repo, so I reviewed the
last copy in git history (commit `490d311^`):

- `scripts/build_basketball_model.py`
- `scripts/export_coreml.py`
- the Grounding DINO auto-labeller

The replacement tooling is `Tools/dataset/build_dataset.py` and
`Tools/training/train_detector.py`.

## What ships today

| | |
|---|---|
| Model | Ultralytics YOLO (AGPL-3.0, per the model's own metadata) |
| File | `BallDetector.mlmodel`, 44 MB, FP32, NeuralNetwork format |
| Classes | 0 ball, 1 basket, 2 person |
| Input | 640 × 640, NMS built in |
| Trained | 18 April 2026, on `C:\tmp\basketball_dataset` |

## Problems, most serious first

1. **Licence.** Ultralytics code and the weights it trains are AGPL-3.0.
   Shipping one inside a closed-source App Store app needs an
   [Ultralytics Enterprise licence](https://www.ultralytics.com/license).
   App Store terms are generally held to be incompatible with (A)GPL, so
   making the app open source doesn't cleanly fix it either. This has to be
   settled before the first App Store build. Options, cheapest first:
   - **Create ML Object Detector** (Mac, Apple licence, Core ML out of the
     box). Needs the same labelled data; small-ball accuracy is unproven, so
     compare it with the gate below.
   - **An Apache-2.0 detector** (YOLOX, RT-DETR, D-FINE), converted with
     coremltools. More work, but no licence questions.
   - **Buy the Ultralytics licence** and keep everything as is.
2. **Trained at one size, shipped at another.** Training ran at
   `imgsz=1280`; `export_coreml.py` exported at 640. A model tuned on
   1280-pixel images sees balls at half the size it learned, which is the
   worst case for a small ball. Train at the size you ship. 640 suits 60 fps
   on a phone.
3. **Inconsistent basket boxes.** The auto-labeller prompted for both
   "basketball rim" and "basketball hoop" and mapped both to the same class:
   - "rim" gives a thin box around the ring;
   - "hoop" gives the ring plus the net.

   The tracker's make line (`maxY − 0.15·h`) and "out the bottom of the net"
   test both depend on the box's height, so the box needs one meaning. Use
   rim plus net, every time.
4. **Class drift.** The Roboflow set is `ball / human / rim`; the shipped
   model is `ball / basket / person`. Renames like this were silently
   remapped by hand. The new script maps by name, so `rim`, `hoop` and
   `net` → `basket`, and `human` and `player` → `person`.
5. **The wrong footage.** The dataset is mostly broadcast and elevated
   angles. The app sees a phone on a stand behind or beside one shooter, at
   chest height, often in a dim gym or outdoors at dusk. Nothing in training
   looks like that yet.
6. **No check before installing.** The old script copied whatever it
   trained straight into the app. A worse model would have shipped
   unnoticed.
7. **Heavy, old format.** The 44 MB FP32 `.mlmodel` uses the NeuralNetwork
   format. An FP16 ML Program (`.mlpackage`) is about half the size and runs
   better on the Neural Engine. Exporting on Windows is what produced the
   old format.
8. **Not reproducible.** Unpinned packages are `pip install`ed in the middle
   of a run. A retrain in six months would build something different.

## The new loop

1. **Collect.** Players who turn on "Help improve shot tracking" share
   frames from their sessions. Each `manifest.json` now records:
   - the detector's boxes for every frame;
   - every shot: its result, whether the tracker called it, its confidence,
     whether it was flagged and whether the player corrected it.

   `detections.jsonl` also records net movement and the published call.
   Log times now start at the video's first frame, so they line up with
   the frames exactly.
2. **Build.** Run:

   ```
   python3 Tools/dataset/build_dataset.py <downloaded sessions> --out ~/hooptrack-dataset
   ```

   It writes YOLO images and labels, splits by session, and writes
   `review.csv`. That list ranks first the frames where the app is known to
   have gone wrong:
   - corrected calls;
   - shots logged by hand;
   - calls that were undone;
   - flagged calls;
   - detection flicker.
3. **Fix the labels.** Import the folder into CVAT or Label Studio (YOLO
   format) and correct frames from the top of `review.csv` down. The
   starting boxes are the model's own guesses. Without this step, training
   only reinforces its mistakes. Label baskets as rim plus net.
4. **Train and gate.** Run:

   ```
   .venv/bin/python Tools/training/train_detector.py \
       --data ~/datasets/roboflow-basketball ~/hooptrack-dataset \
       --hooptrack-val ~/hooptrack-dataset --baseline <current .pt>
   ```

   It trains at 640, then scores the new model and the current one on
   HoopTrack's own held-out sessions. If ball or basket mAP@0.5 drops by
   more than 0.01, it stops. Otherwise it exports an FP16 `.mlpackage` and
   installs it into the app.
5. **Check on device.** Replay a few logged sessions with `shot-eval`. Then
   shoot a session with Profile → Developer → Show detection boxes on.

## What I couldn't check

There's no GPU or Mac here. I've syntax-checked both scripts and run the
dataset builder and the dataset merge on synthetic data. `train_detector.py`
has not yet done a real training run, so expect to fix small things on the
first one, most likely in Ultralytics' export arguments.
