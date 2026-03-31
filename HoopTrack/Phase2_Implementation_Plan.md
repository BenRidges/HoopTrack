# HoopTrack — Phase 2 Implementation Plan
## Shot Tracking MVP

### Overview
Replace the manual Make/Miss buttons with automatic shot detection using Core ML + Apple Vision. Shots must be classified by zone and mapped to normalised court coordinates, targeting > 92% accuracy in indoor lighting.

---

## Step 1 — Ball Detection Model (Core ML)
**New files:** `HoopTrack/ML/BallDetector.mlpackage`, `HoopTrack/ML/BallDetector.swift`

- Train or adapt a YOLO/MobileNet model using `coremltools` (Python, offline) to detect a basketball in a frame
- Input: 416×416 pixel buffer from `CMSampleBuffer`
- Output: bounding box (`CGRect`) + confidence score
- `BallDetector.swift` wraps the model in a `VNCoreMLRequest` and returns `CGRect?` detections
- Target: < 20ms per frame on A15 Bionic

> The model training data is out of scope here. Use a pre-trained YOLO base fine-tuned on basketball footage, or a public sports ball detector as a starting point.

---

## Step 2 — Hoop Detection & Court Calibration
**New file:** `HoopTrack/Services/CourtCalibrationService.swift`

- On session start, run `VNDetectRectanglesRequest` to locate the backboard/hoop area
- Lock a reference `CGRect` for the hoop zone for the session duration
- Map hoop position to normalised court coordinates (feeds zone classification)
- Prompt user to aim camera until calibration succeeds before enabling auto-detection

---

## Step 3 — CV Pipeline
**New file:** `HoopTrack/Services/CVPipeline.swift`

Subscribes to `CameraService.framePublisher` and runs the shot detection state machine:

```
IDLE
  → Ball detected → TRACKING
  → Ball lost → IDLE

TRACKING
  → Ball moving upward + peaks → RELEASE_DETECTED
  → Ball lost for > 0.3s → IDLE

RELEASE_DETECTED
  → Ball enters hoop zone (Y decreasing, overlapping hoop rect) → MAKE
  → Ball hits backboard/floor without entering hoop zone → MISS
  → Timeout (2s) → MISS
```

Key outputs per shot:
- `ShotResult` (.make / .miss)
- `CourtZone` — derived from ball position at release relative to calibrated hoop
- Normalised `courtX`, `courtY` (0–1) at release point

Calls `LiveSessionViewModel.logShot(result:zone:shotType:courtX:courtY:)` on the main actor when a shot is resolved.

---

## Step 4 — Wire CVPipeline into LiveSessionView
**Modified files:** `HoopTrack/Views/Train/LiveSessionView.swift`, `HoopTrack/ViewModels/LiveSessionViewModel.swift`

- In `.task`, after camera starts, instantiate `CVPipeline` and call `pipeline.start(session:viewModel:)`
- Add `@State private var cvPipeline: CVPipeline?`
- Call `CVPipeline.stop()` in `.onDisappear`
- Manual Make/Miss buttons remain visible as a fallback (per spec)

---

## Step 5 — Shot Zone Classification
**Modified file:** `HoopTrack/Utilities/Constants.swift`

The court geometry constants are already defined. Implement `CourtZoneClassifier.classify(courtX:courtY:courtType:) -> CourtZone` as a pure function using existing `Constants.Court` values:

| Zone | Condition |
|------|-----------|
| `.paint` | `courtX` within paint width, `courtY` < free throw line |
| `.freeThrow` | `courtX` within paint width, `courtY` ≈ free throw line (±5%) |
| `.midRange` | Inside 3-point arc, outside paint |
| `.cornerThree` | `courtX` < corner zone threshold, `courtY` < arc base height |
| `.aboveBreakThree` | Outside arc, not corner |

---

## Step 6 — Pending Shot State & UI
**Modified file:** `HoopTrack/Views/Train/LiveSessionView.swift`

- While CV is resolving a shot (`ShotResult.pending`), show a neutral "detecting…" indicator in the HUD strip
- `ShotRecord` already has `.pending` in `ShotResult` — just needs a UI treatment (gray dot in the recent shots strip)

---

## Step 7 — Session Video Recording
**New file:** `HoopTrack/Services/VideoRecordingService.swift`

- Optional in Phase 2, required for Phase 3 (Shot Science)
- Wrap `AVCaptureMovieFileOutput` to record to `Documents/Sessions/<session-id>.mov`
- Store filename in `TrainingSession.videoFileName`
- `DataService.purgeOldVideos(olderThanDays:)` already handles cleanup

---

## Done Criteria

- [ ] Ball detected and tracked in real-time at 60fps with < 20ms processing
- [ ] Make/miss auto-detected with > 92% accuracy in indoor lighting
- [ ] Shot zone classified and stored with each `ShotRecord`
- [ ] Shot chart in `SessionSummaryView` and `ProgressTabView` populated with real CV data
- [ ] Manual Make/Miss buttons remain as fallback
- [ ] Hoop calibration prompt shown at session start

---

## Effort Estimate

| Step | Complexity |
|------|-----------|
| 1 — Ball detection model (fine-tuning) | High — requires offline ML work |
| 2 — Court calibration | Medium |
| 3 — CVPipeline state machine | High |
| 4 — LiveSession wiring | Low |
| 5 — Zone classifier | Low |
| 6 — Pending shot UI | Low |
| 7 — Video recording | Medium |

> The ML model prep (Step 1) is the longest pole — everything else can be built in parallel once the model contract (input/output format) is locked.
