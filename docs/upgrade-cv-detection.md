# Upgrade: CV Detection & Make/Miss Accuracy

Roadmap for improving HoopTrack's ball detection and make/miss classification. The v1 BallDetector.mlpackage (yolov8s, 40 epochs, public Roboflow dataset) ships as a baseline — every improvement beyond that depends on capturing real HoopTrack footage and structured per-shot telemetry. This plan front-loads the data-collection infrastructure so every subsequent phase has what it needs.

## Guiding principles

- **Measure before optimizing.** No model change ships without a held-out eval that shows it beats the previous version on real HoopTrack footage.
- **Data beats architecture.** A yolov8n trained on 2,000 labeled HoopTrack frames will outperform a yolov8m trained only on public data, every time.
- **Layered make/miss.** Geometric primary, net-motion confirmation, audio as independent signal, ML classifier only for ambiguous cases.
- **Privacy first.** All telemetry opt-in with explicit consent. File protection complete. Fits the existing Phase 7 security posture (`KeychainService`, `InputValidator`, `PrivacyInfo.xcprivacy`).

## Success criteria (end-state)

| Metric | Current (est.) | Target v2 |
|---|---|---|
| Ball detection mAP50 on real HoopTrack footage | unknown | ≥ 0.90 |
| Make recall | ~85% | ≥ 97% |
| Miss precision | ~80% | ≥ 95% |
| User-corrected shots per session | unmeasured | < 1 per 50 shots |
| On-device inference latency | unmeasured | < 30 ms/frame on iPhone 12+ |
| False shot-detection (non-shot events) | unmeasured | < 1 per 5 min of footage |

---

# Phase A — Instrumentation & Data Collection (ship NOW)

This is the foundation. Every later phase depends on it. Nothing else should begin until Phase A is in production and capturing real session data.

## A1. Shot telemetry model

Add a new SwiftData `@Model` class `ShotTelemetry` in `Models/`. One `ShotTelemetry` per `ShotRecord`, linked by `shotID: UUID`. Not part of `TrainingSession.shots`; stored separately so it can be deleted independently for storage management.

Fields:

```swift
@Model final class ShotTelemetry {
    @Attribute(.unique) var shotID: UUID
    var capturedAt: Date
    var appVersion: String
    var modelVersion: String                    // "BallDetector-v1-yolov8s-2026-04"
    var calibrationConfidence: Double           // 0–1 from CourtCalibrationService
    var rimBoxNormalized: [Double]              // [x, y, w, h] in 0–1 image space
    var ballTrack: Data                         // JSON-encoded [BallFrame]
    var audioClipPath: String?                  // relative path in Documents/Telemetry/
    var videoClipPath: String?                  // short clip: release-1s … resolve+2s
    var predictedOutcome: ShotOutcome           // .made / .missed / .uncertain
    var predictedConfidence: Double
    var userConfirmedOutcome: ShotOutcome?      // nil until user reviews
    var userCorrectedAt: Date?
    var geometricVerdict: String                // JSON: primary reasoning + scores
    var netMotionScore: Double?                 // Phase B
    var audioVerdict: String?                   // Phase C
}

struct BallFrame: Codable {
    let frameIndex: Int
    let timestampMs: Int
    let boxNormalized: [Double]                 // [x, y, w, h]
    let detectionConfidence: Double
}
```

## A2. Telemetry capture in CVPipeline

Extend `CVPipeline` to accumulate per-frame ball detections between `release_detected` and `resolved`. On resolution, emit a `ShotTelemetry` via a new `TelemetryService`.

- Ring buffer of last 150 frames of detections (≈ 5s at 30fps) to capture release-onward
- Clip video: write frames from 1s before release to 2s after resolve to `Documents/Telemetry/<shotID>.mov` with `FileProtectionType.complete`
- Clip audio: synchronized 3s mic capture around the same window. Requires adding audio to `CameraService` if not already present

## A3. TelemetryService

New `Services/TelemetryService.swift`, `@MainActor final class`. Responsibilities:

- Persist `ShotTelemetry` via `DataService`
- Write video/audio clips to `Documents/Telemetry/` with full file protection
- Enforce retention: delete telemetry older than `HoopTrack.Storage.telemetryRetainDays` (default 30) unless user has opted to contribute
- Expose `exportForContribution(shotID:)` — bundles clip + JSON metadata into a zip the user can upload (Phase A6)

## A4. User review UI

New `Views/ShotReviewSheet.swift` surfaced from `SessionSummaryView`:

- Lists shots the pipeline flagged as `predictedConfidence < 0.7` first
- Shows the 3s clip, predicted outcome, and a "Correct this" control
- Writes `userConfirmedOutcome` + `userCorrectedAt`
- Updates `ShotRecord.wasMade` if corrected, triggers `TrainingSession.recalculateStats()`

This is high-value for the user AND generates the labeled data future phases need.

## A5. Consent & settings

- New setting in `Views/Settings/PrivacySettings.swift`: **"Help improve shot detection"** (default OFF)
- When OFF: telemetry captured locally for your own review only, never uploaded, auto-deleted per retention
- When ON: clips + labels queued for upload (Phase A6 below)
- Settings string must explain exactly what's captured. Tie to the privacy manifest.

## A6. Contribution upload pipeline

*Defer to Phase 9 (Supabase) — stub now, wire later.*

Create `Services/TelemetryUploadService.swift` with a `queuePendingShots()` entry point. For now it just logs intent; when Phase 9 Supabase lands, this fills out:

- Upload `ShotTelemetry` + clip to a Supabase Storage bucket (`shot-contributions/`)
- Strip all PII (no userID — just an anonymous contribution UUID)
- RLS policy: insert-only, no read-back
- Dashboard in Supabase for the HoopTrack team to triage and label

## A7. Eval fixture

Create `HoopTrackTests/Fixtures/ShotEvalSet/`:

- 50–100 hand-picked real shot clips with ground-truth labels (make/miss, ball track, outcome)
- Never used for training; used only to score every model version
- New test `BallDetectorEvalTests.swift` runs the current CoreML model against the fixture and asserts mAP50 ≥ regression threshold
- Make/miss eval: `MakeMissPipelineEvalTests.swift` runs the full CVPipeline against the fixtures and asserts make recall ≥ threshold

Initial fixture assembly: ~4 hours of manual labeling. Do this as soon as ~20 sessions of real telemetry exist.

## A8. ROADMAP integration

Add a new phase to `docs/ROADMAP.md`: **Phase 8 — CV Telemetry Foundation**. Link back to this document.

Gate all later CV model work in this plan behind this phase shipping.

---

# Phase B — Ball Detection v2 (data-driven retrain)

Begins once Phase A has captured ≥ 2,000 usable frames across ≥ 20 sessions.

## B1. Dataset assembly

- Pull telemetry videos and sample ~1 frame/sec
- Auto-label with current v1 BallDetector
- Hand-correct in Roboflow (focus on v1's mistakes — hardest frames give biggest gains)
- Target: 2,000–3,000 HoopTrack-native labeled frames
- Merge with the public Roboflow dataset as a base

## B2. Unified ball + rim + backboard model

Replace the current ball-only detector with a multi-class model:

- Classes: `ball`, `rim`, `backboard`
- One Vision pass per frame instead of two
- Required for Phase D (homography-based make/miss)

Update `HoopTrack/Utilities/Constants.swift` class labels. Update `CourtCalibrationService` to consume rim detections from the same model instead of its current heuristics (if applicable — audit during this phase).

## B3. Training config sweep

One variable at a time, measured against the Phase A7 eval fixture:

1. Baseline: retrain v1 config on new dataset → expect +5–15 mAP on real footage
2. `EPOCHS = 80`, `BATCH = 16` → typically +2–5 mAP
3. Trial `yolov8m.pt` — keep only if on-device latency stays under 30 ms/frame
4. Trial `imgsz = 960` — keep only if it survives the same latency budget

## B4. Targeted augmentation

Update [build_basketball_model.py](HoopTrack/scripts/build_basketball_model.py) training call with basketball-specific augmentation: `degrees=10`, `hsv_v=0.5`, `flipud=0.0`. Disable mosaic for final 10 epochs (`close_mosaic=10`, already default).

## B5. Release checklist

- Score new model on Phase A7 fixture — must beat current version on all three metrics
- Benchmark on-device latency on iPhone 12 / 13 / 15 via Instruments → CoreML template
- Confirm CoreML loader uses `MLModelConfiguration.computeUnits = .all` (Neural Engine)
- Bump `HoopTrack.ML.modelVersion` string — Phase A telemetry records this
- Update [docs/ROADMAP.md](docs/ROADMAP.md) with the new baseline numbers

---

# Phase C — Tracking Layer

A Swift-side temporal smoother over per-frame detections. Dramatically improves release detection and geometry accuracy. No model retrain required.

## C1. Constant-velocity Kalman filter

New `Services/BallTracker.swift`:

- Constant-velocity Kalman filter (state = [x, y, vx, vy])
- Associates new detections to existing tracks via IoU + proximity
- Bridges 1–3 frame gaps (critical for swish occlusions)
- Emits smoothed `trackID` + velocity estimate to `CVPipeline`

## C2. CVPipeline refactor

Change the pipeline's ball state from raw per-frame detections to `BallTrack`. The state machine's transitions become velocity-driven:

- `tracking → release_detected`: sustained upward velocity for ≥ N frames after leaving shooter's hand
- `release_detected → resolved`: track terminates near hoop AND doesn't reappear above rim within rebound window

## C3. Test coverage

Pure-function Kalman tests in `HoopTrackTests/BallTrackerTests.swift` following the existing pattern. Integration tests against Phase A7 fixture.

---

# Phase D — Make/Miss v2 (Homography + Net Motion)

Begins once Phase B (multi-class model) and Phase C (tracking) are in production.

## D1. Homography-based geometric classifier

Replace the current make/miss heuristic with rim-plane homography. New `Services/MakeMissClassifier.swift`:

- Input: `BallTrack`, rim box, backboard box, calibration data
- Compute homography from image → real-world rim plane using the known 45.7 cm rim diameter as the scale reference
- Project ball track onto rim plane
- Classify make if the track passes through the rim circle from above while descending, and doesn't reappear above the rim within the rebound window

Kills the "ball passes in front of hoop" false positives that plague 2D overlap methods.

## D2. Net-motion confirmation

Cheap frame-differencing heuristic over the net ROI (derived from rim + backboard boxes):

- Compute pixel-delta sum in the net ROI for 500 ms after suspected make
- Threshold calibrated on Phase A telemetry
- Used as a confidence modifier, not a primary vote — geometric still decides

Upgrade to a tiny CNN only if heuristic false-positive rate proves too high.

## D3. Rebound window

Hard requirement: ≥ 800 ms of "no ball above rim plane" before committing to `made`. Tuned against Phase A7 fixture.

## D4. Confidence surfacing

When `MakeMissClassifier` emits `predictedConfidence < 0.7`, flag the shot for user review in `ShotReviewSheet` (Phase A4). User correction updates telemetry and feeds future training.

---

# Phase E — Audio Classification

Mic-based make/miss signal. Runs in parallel with visual classifier; results fused.

## E1. Audio dataset

Extracted from Phase A telemetry. 500+ labeled 1-second clips around shot resolution: `swish`, `rim-make`, `rim-miss`, `airball`, `unclear`.

## E2. Tiny on-device classifier

- MFCC features → small CNN (< 1 MB, < 5 ms inference)
- Train with `coremltools` → `AudioShotClassifier.mlpackage`
- Load via same pattern as BallDetector

## E3. Fusion

`MakeMissClassifier` takes both visual and audio verdicts. Agreement → high confidence. Disagreement → flag for user review.

---

# Phase F — ML Re-ranker (ambiguous cases only)

Only if Phases B–E still leave > 2% silent errors. Dedicated shot-clip classifier runs only when upstream confidence is low.

## F1. Shot clip dataset

- 2,000+ hand-labeled shot clips from Phase A telemetry and user-corrected Phase A4 reviews
- 8–16 frame windows centered on the release

## F2. Model

Small 3D CNN or transformer, exported to CoreML. Only invoked when `predictedConfidence < 0.6`. Latency budget: < 100 ms per ambiguous shot (runs on the main session queue, off the per-frame hot path).

---

# Integration map

Files this plan will touch, grouped by phase:

**Phase A — ship now:**
- NEW: `HoopTrack/Models/ShotTelemetry.swift`
- NEW: `HoopTrack/Services/TelemetryService.swift`
- NEW: `HoopTrack/Services/TelemetryUploadService.swift` (stub)
- NEW: `HoopTrack/Views/ShotReviewSheet.swift`
- NEW: `HoopTrack/Views/Settings/PrivacySettings.swift` (or extend existing)
- EDIT: `HoopTrack/Services/CVPipeline.swift` (emit telemetry on resolve)
- EDIT: `HoopTrack/Services/CameraService.swift` (audio capture if missing)
- EDIT: `HoopTrack/Services/DataService.swift` (add telemetry CRUD, extend `deleteAllUserData`)
- EDIT: `HoopTrack/Utilities/Constants.swift` (add `HoopTrack.Telemetry.*`, `HoopTrack.Storage.telemetryRetainDays`)
- EDIT: `HoopTrack/HoopTrackApp.swift` (apply file protection to `Documents/Telemetry/`)
- EDIT: `HoopTrack/Views/SessionSummaryView.swift` (link to `ShotReviewSheet`)
- EDIT: `HoopTrack/PrivacyInfo.xcprivacy` (declare telemetry category)
- EDIT: `docs/ROADMAP.md` (add Phase 8 — CV Telemetry Foundation)
- NEW: `HoopTrackTests/Fixtures/ShotEvalSet/` (fixtures + `BallDetectorEvalTests.swift`, `MakeMissPipelineEvalTests.swift`)

**Phase B:**
- EDIT: [HoopTrack/scripts/build_basketball_model.py](HoopTrack/scripts/build_basketball_model.py) (multi-class, new augmentation)
- REPLACE: `HoopTrack/ML/BallDetector.mlpackage`
- EDIT: `HoopTrack/Utilities/Constants.swift` (class labels, `modelVersion`)
- EDIT: `HoopTrack/Services/CourtCalibrationService.swift` (consume rim/backboard detections)

**Phase C:**
- NEW: `HoopTrack/Services/BallTracker.swift`
- EDIT: `HoopTrack/Services/CVPipeline.swift` (consume `BallTrack`)
- NEW: `HoopTrackTests/BallTrackerTests.swift`

**Phase D:**
- NEW: `HoopTrack/Services/MakeMissClassifier.swift`
- EDIT: `HoopTrack/Services/CVPipeline.swift` (swap in new classifier)
- NEW: `HoopTrackTests/MakeMissClassifierTests.swift`

**Phase E:**
- NEW: `HoopTrack/ML/AudioShotClassifier.mlpackage`
- NEW: `HoopTrack/Services/AudioShotClassifier.swift`
- EDIT: `HoopTrack/Services/MakeMissClassifier.swift` (fuse audio verdict)

**Phase F:**
- NEW: `HoopTrack/ML/ShotClipClassifier.mlpackage`
- NEW: `HoopTrack/Services/ShotClipClassifier.swift`
- EDIT: `HoopTrack/Services/MakeMissClassifier.swift` (invoke re-ranker on low confidence)

---

# Sequencing & dependencies

```
Phase A (Telemetry)  ← SHIPS FIRST, ALONE
        │
        ├─► Phase B (Detector v2)        ─┐
        │                                  ├─► Phase D (Make/Miss v2)
        └─► Phase C (Tracking)            ─┘           │
                                                       ├─► Phase F (Re-ranker)
Phase E (Audio) ──────────────────────────────────────┘
   (can start anytime after A has audio data)
```

Phase A is the only phase with no upstream dependency and must ship before anything else. Phases B, C, E can run in parallel after A. D depends on B + C. F depends on D + E and only justifies its existence if error rates are still too high.

---

# Open questions for the product side

Flag these before Phase A implementation:

1. **Video clip retention default** — 30 days seems reasonable but consumes storage. Confirm.
2. **Contribution upload mechanism** — Supabase Storage (Phase 9) is the planned path. Is there an interim mechanism you'd accept, or wait for Phase 9?
3. **ShotReviewSheet trigger** — always end-of-session, or only when low-confidence shots exist? I lean toward only-when-needed so the flow stays fast for high-confidence sessions.
4. **Audio capture consent** — do we want a separate toggle, or bundle with "help improve shot detection"? Legal sometimes wants audio broken out.
5. **Does `CourtCalibrationService` currently detect the rim via CoreML or heuristics?** Determines Phase B2 scope.
