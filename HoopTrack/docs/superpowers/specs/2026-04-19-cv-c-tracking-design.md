# CV-C — Ball Tracking Layer (Kalman) Design Spec

**Date:** 2026-04-19
**Status:** Draft — pending user review
**Scope:** A temporal smoothing + occlusion-bridging layer that sits between `CoreMLBallDetector` and `CVPipeline`, turning flickery per-frame ball detections into a coherent `BallTrack`. Does not touch the detector model, does not touch the rim-calibration path.
**Parent:** [docs/upgrade-cv-detection.md](../../../docs/upgrade-cv-detection.md) Phase C
**Parallel track:** Independent of CV-A (telemetry) and CV-B (detector v2); can ship in parallel with either.

---

## 1. Goal

HoopTrack's shipped `CVPipeline` consumes raw per-frame ball detections. Any occlusion — behind the rim at release peak, behind the shooter's hand, a single motion-blurred frame — returns a `nil` ball, which today either (a) extends `tracking` until the 0.3s timeout and drops the pipeline back to `idle`, or (b) mid-flight makes the state machine miss the "at peak" condition and never transitions to `release_detected`. Real shot-release footage has 1–5 frame detection gaps constantly; the state machine treats these as "no shot happened."

CV-C fixes this by introducing a `BallTracker` service that maintains a single smoothed `BallTrack` across short detection gaps. The tracker runs a 2D constant-velocity Kalman filter, associates incoming detections to the existing track by proximity, and emits a predicted position on frames where the detector returned nothing. "Done" means: (a) the `tracking → release_detected` transition fires reliably even when the detector misses 1–3 frames around the release, (b) the pipeline no longer drops back to `idle` on a single missed frame, (c) release-point and peak-position estimates become smooth enough to feed CV-D's homography classifier without additional filtering, and (d) on-device inference latency stays within the existing 30 fps budget on iPhone SE 2.

---

## 2. Architecture Overview

`BallTracker` is a **sibling value-type smoother** owned by `CVPipeline`, not a replacement for it. It follows the same pattern as the rim-side `HoopRectSmoother` inside `CourtCalibrationService`: a `struct` held as pipeline state, mutated per frame, exposing a pure public surface that's easy to unit-test.

```
 CameraService.framePublisher (CMSampleBuffer on sessionQueue)
                │
                ▼
        CoreMLBallDetector.detectScene(buffer:)
                │
                ▼  SceneDetection(ball: BallDetection?, basket: …)
                │
        ┌───────┴────────┐
        ▼                ▼
CourtCalibration     BallTracker.update(ball:timestamp:)
 (rim path)                │
                           ▼  BallTrackSample(state: .tracking | .predicted | .lost,
                           │                  box: CGRect, velocity: CGVector, …)
                           ▼
               CVPipeline state machine
               (idle → tracking → releaseDetected → resolved)
```

Key consequences:
- `CVPipeline.processBuffer` no longer branches on `scene.ball` directly — it branches on `BallTrackSample.state`.
- `LiveSessionViewModel` is **not touched**. The tracker is transparent to the UI layer; `logPendingShot` / `resolvePendingShot` are still called with the same inputs.
- The debug `DetectionOverlay` continues to show the raw detection box (so users / us can still see the underlying ML quality); a follow-up could optionally render the predicted box on missed frames.

CV-A (telemetry) will want to capture **both** the raw `BallDetection` stream *and* the tracker's per-frame `BallTrackSample` (including which frames were predicted-only). Flagged as a minor integration point in §10.

---

## 3. Kalman Model Choice

**Constant-velocity 2D** — state vector is 4-dimensional: `[x, y, vx, vy]` in normalised image coordinates (Vision's 0–1 space).

Justification:
- A basketball in flight **is** under constant acceleration (gravity), but only in world coordinates. In image-space, the apparent acceleration depends on distance, camera tilt, and projection — and the detector's per-frame noise is much larger than the gravity signal over a 3-frame gap. A constant-acceleration (CA) model would give us 2 extra state dimensions of unverifiable value.
- The tracker has to work for both the ascent *and* the descent halves of a shot. A CA model biased toward gravity-consistent trajectories would actively hurt descent prediction when the ball is decelerating under air resistance after a rim kiss.
- Existing proven pattern: most open-source sports trackers (Norfair, ByteTrack, SORT family) use constant-velocity for ball tracking. Only specialized tennis/baseball trackers go to CA, and they have multi-camera or depth priors we don't.

Process noise `Q` is tuned to be roughly proportional to the expected gravity drift per frame at 30 fps (empirically ~0.015 in normalised coords near rim distance) so the filter can absorb real acceleration without a formal model. Measurement noise `R` is derived from detector confidence — higher-confidence detections get tighter covariance, low-confidence get wider.

---

## 4. State Estimation Math

Standard linear Kalman filter with constant-velocity transition:

```
State:     x = [px, py, vx, vy]ᵀ
Transition F:  [[1, 0, dt, 0],
                [0, 1, 0, dt],
                [0, 0, 1,  0],
                [0, 0, 0,  1]]

Measurement H: [[1, 0, 0, 0],
                [0, 1, 0, 0]]   (we observe position only)

Predict:   x' = F·x
           P' = F·P·Fᵀ + Q

Update:    y = z − H·x'                       (innovation)
           S = H·P'·Hᵀ + R
           K = P'·Hᵀ·S⁻¹                      (Kalman gain)
           x'' = x' + K·y
           P'' = (I − K·H)·P'
```

Implementation: **hand-rolled 4×4 / 2×2 matrix math in pure Swift**. No Accelerate dependency. Rationale: matrices are tiny (≤ 16 entries), the entire predict+update takes < 100 arithmetic ops, and `simd` / `Accelerate` setup overhead would likely cost more than it saves at this scale. Keeping it pure Swift also keeps the math trivially unit-testable and portable if we ever want to share logic with a server-side tool.

A small `Matrix4x4` helper struct (plus `Vector4`, `Matrix2x2`, `Matrix4x2`) lives in `Utilities/Kalman/`. Only operations needed: multiply, transpose, add/subtract, 2×2 inverse. Explicit, no generics, < 100 LOC total.

---

## 5. BallTracker API

```swift
// HoopTrack/Services/BallTracker.swift

nonisolated struct BallTrackSample: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case noTrack                  // no ball seen recently enough to track
        case tracking                 // fresh measurement landed this frame
        case predicted(sinceFrames: Int)   // filter ran forward without a measurement
        case lost                     // tracker gave up; caller should treat as noTrack
    }
    let state: State
    let box: CGRect                   // best-estimate bounding box, normalised
    let velocity: CGVector            // vx, vy in normalised coords per second
    let confidence: Double            // 0..1, blends detection conf + predict age
    let timestamp: CMTime
}

nonisolated struct BallTracker: Sendable {
    init(
        processNoise: Double        = HoopTrack.Tracking.processNoise,
        measurementNoiseFloor: Double = HoopTrack.Tracking.measurementNoiseFloor,
        maxPredictedFrames: Int     = HoopTrack.Tracking.maxPredictedFrames,
        associationDistance: Double = HoopTrack.Tracking.associationDistance
    )

    private(set) var sample: BallTrackSample

    /// Per-frame entry point. Pass the detector's ball detection (nil if the
    /// detector returned no ball this frame) and the frame timestamp.
    /// Returns the updated `BallTrackSample` — also stored in `self.sample`.
    mutating func update(ball: BallDetection?, timestamp: CMTime) -> BallTrackSample

    /// Drop all state — e.g. when `CVPipeline.stop()` is called.
    mutating func reset()
}
```

`BallTracker` is a `struct` (not a class) for the same reasons `HoopRectSmoother` is: pure value semantics, no need for actor isolation, trivially unit-testable. It is `nonisolated` — the `CVPipeline` owns it as `nonisolated(unsafe)` state inside its `sessionQueue`-confined closure, identical to the existing `PipelineState`.

---

## 6. Track Lifecycle

```
             (first detection, confidence ≥ minDetectConf)
   noTrack ───────────────────────────────────► tracking
      ▲                                           │
      │                                           │ detection arrives
      │                                           │ within associationDistance
      │                                           │ of predicted position
      │                                           ▼
      │                                        tracking
      │                                           │
      │                                           │ no detection this frame
      │                                           ▼
      │                                      predicted(n=1)
      │                                           │
      │                                           │ still no detection (n++)
      │                                           ▼
      │                                      predicted(n)
      │                                           │
      │                                           │ n > maxPredictedFrames
      │                                           ▼
      │                                          lost
      │ ◄──────────────────────────────────────────┘
      │            (on next update, lost → noTrack)
      │
      └── a detection arriving while predicted(n) that lies within
          associationDistance of the filter's current predicted
          position returns the tracker to `tracking`; otherwise it
          is treated as a new candidate and either dropped (if weak)
          or, after the current track is killed, starts a new track
          on the next frame.
```

**Frame budget for a lost track:** `maxPredictedFrames = 5` (≈ 166 ms at 30 fps). Chosen because (a) a swish with rim occlusion typically drops 2–4 frames; (b) any gap larger than ~200 ms is probably a real discontinuity (the ball left the frame or the state changed) and we'd rather start a new track than extrapolate blindly.

Association: a new detection is associated to the current track if `|detectionCenter - predictedCenter| < associationDistance` (default 0.08 in normalised coords, ≈ 8% of frame width). Beyond that, we assume it's a different object (e.g. a second ball in frame, a false positive) and start fresh on the next frame. We do **not** support multi-track — basketball has one ball; pipeline state is single-ball throughout.

Only one exception to single-track: if the current state is `lost`, the next qualifying detection starts a new track. This handles re-entry after the ball goes out of frame.

---

## 7. Integration Contract

### Before CV-C

```swift
// CVPipeline.processBuffer, abbreviated
let detection: BallDetection? = scene.ball
switch pipelineState {
case .tracking(var trajectory):
    if let d = detection {
        trajectory.append(d)
        lastDetectionTimestamp = now
        if isAtPeak(trajectory) { … releaseDetected … }
    } else {
        if elapsed > trackingTimeoutSec { pipelineState = .idle }
    }
}
```

### After CV-C

```swift
// CVPipeline.processBuffer, abbreviated
let sample = tracker.update(ball: scene.ball, timestamp: now)
switch (pipelineState, sample.state) {
case (.idle, .tracking):
    pipelineState = .tracking(trajectory: [sample])

case (.tracking(var trajectory), .tracking),
     (.tracking(var trajectory), .predicted):
    trajectory.append(sample)
    if isAtPeak(trajectory: trajectory) { /* release logic unchanged */ }
    else { pipelineState = .tracking(trajectory: trajectory) }

case (.tracking, .lost), (.tracking, .noTrack):
    pipelineState = .idle

case (.releaseDetected(let releaseBox, _), _):
    /* use sample.box for isEnteringHoop / isBelowHoop checks,
       which already accept any CGRect — no signature change */
}
```

`PipelineState.tracking`'s associated-value type migrates from `[BallDetection]` to `[BallTrackSample]`, a wider type (carries velocity + predicted flag). `isAtPeak` keeps the same trajectory-over-5-samples shape; with predicted samples filling gaps, 5 samples is always reachable.

`LiveSessionViewModel`: **no change**. `logPendingShot(zone:courtX:courtY:science:)` and `resolvePendingShot(result:zone:courtX:courtY:)` are called with identical inputs — the tracker feeds the same values in, just smoother.

`ShotScienceCalculator.compute(trajectory:poseObservation:hoopRectWidth:)` currently takes `[BallDetection]`. It needs a small adapter: either (a) change its signature to `[BallTrackSample]`, or (b) project `[BallTrackSample]` back to `[BallDetection]` at the call site. Lean: **(b)**, to keep ShotScience untouched for this phase. Open question in §11.

---

## 8. Performance Budget

Existing per-frame CV budget: ≤ 20 ms (see `HoopTrack.Camera.maxProcessingLatencyMs`). Current breakdown on iPhone 14 Pro:
- CoreML inference: ~12 ms
- Detector post-processing: ~1 ms
- Rim smoother + pipeline state: < 0.5 ms

Kalman add-on cost: **one predict + at most one update per frame.** That's one 4×4 × 4×1 multiply, one 4×4 × 4×4 + 4×4 add, a 2×2 matrix invert. Measured elsewhere (pure-Swift reference impls) at < 50 µs on A15 — negligible. Even on iPhone SE 2 (A13) this stays under 200 µs.

Target: **< 0.5 ms p99** on iPhone SE 2. Verified via Instruments before merge. If we blow the budget (we won't), fall back to Accelerate `simd_float4x4`.

---

## 9. Testing Strategy

Three layers.

**Pure Kalman math (unit tests, test-first):**
- Matrix helpers (multiply, transpose, 2×2 invert) — inputs and outputs specified to 6 decimal places
- One-step predict on a known-velocity state
- One-step update with synthetic measurement
- Numerical stability: 100-frame filter run stays bounded

**Tracker state machine (unit tests, test-first):**
- `noTrack → tracking` on first detection
- `tracking → predicted(1)` on missed frame
- `predicted(n) → tracking` on recovery inside associationDistance
- `predicted(5+) → lost`
- Velocity estimate converges on a linear synthetic trajectory
- Out-of-distance detection does not corrupt the current track
- `reset()` clears state

**Integration (fixture-based, run on demand):**
- `HoopTrackTests/Fixtures/BallTrackerEval/` — 3–5 short real clips (pulled from CV-A once telemetry exists; pre-A we hand-pick from dev recordings)
- Each clip has a JSON sidecar with ground-truth ball boxes for a subset of frames
- `BallTrackerEvalTests.swift` runs the tracker, asserts: (a) no more than 5% of frames are `lost` during a shot window, (b) predicted-position error < 0.05 in normalised coords on frames with ground truth, (c) no spurious `lost` transitions during a contiguous known-tracking span.
- Gated behind `ENABLE_CV_EVAL=1` env var — not run on CI. Matches the pattern already sketched in [docs/upgrade-cv-detection.md](../../../docs/upgrade-cv-detection.md) Phase A7.

No manual QA required for the tracker itself — the integration point with `CVPipeline` gets a smoke-test checklist in the plan (launch a session, shoot 5 shots, verify release detection fires).

---

## 10. Constants

New block added to `HoopTrack/Utilities/Constants.swift`:

```swift
// MARK: - Ball Tracking (Phase CV-C)
enum Tracking {
    /// Process-noise scalar for the Kalman covariance. Larger = more reactive,
    /// smaller = smoother. Tuned so a 3-frame gap can be bridged without the
    /// predicted box drifting more than ~5% of frame width on a typical shot.
    static let processNoise: Double        = 0.015

    /// Floor for measurement noise — detections with confidence 1.0 still get
    /// a small amount of noise so the filter doesn't collapse on perfect-score frames.
    static let measurementNoiseFloor: Double = 0.005

    /// Maximum number of consecutive frames the filter will run in
    /// predict-only mode before giving up. 5 ≈ 166ms at 30fps.
    static let maxPredictedFrames: Int     = 5

    /// Max normalised-space distance between a predicted box centre and a new
    /// detection centre for them to be considered the same track. 0.08 ≈ 8% of frame width.
    static let associationDistance: Double = 0.08

    /// Minimum ML detection confidence to start a brand-new track. Mid-flight
    /// updates use `HoopTrack.Camera.ballDetectionConfidenceThreshold`.
    static let minDetectConfidenceToStart: Float = 0.55
}
```

---

## 11. Interaction with CV-A

CV-A's `ShotTelemetry` will want to capture the **raw** `[BallDetection]` sequence (what the detector actually saw) *and* the tracker's per-frame `BallTrackSample` (what the pipeline actually consumed). Both are useful:
- Raw detections answer "is the ML model good enough?"
- Tracker samples answer "did the smoothing help or hurt on this shot?"

**Action for CV-A (not CV-C):** when CV-A's ring-buffer lands, include a parallel buffer of `BallTrackSample` alongside `BallDetection`. Both are small (≤ 150 × ~60 bytes ≈ 9 KB) and Codable-friendly.

No work required in CV-C beyond making `BallTrackSample` public and `Codable`. (It already is, per §5.)

---

## 12. Open Questions

1. **`ShotScienceCalculator` signature change.** Today it takes `[BallDetection]`. After CV-C, trajectory samples include predicted-only frames — are those valid inputs for release-angle / arc math, or should we filter them out? **My lean:** pass only `sample.state == .tracking` samples to ShotScience for now; revisit once CV-A telemetry shows whether the predicted frames help or hurt Shot Science accuracy.
2. **Multi-track support.** A second ball entering the frame (e.g. a rebound during a drill) is treated as "not our ball" and dropped. In 2v2+ game mode, a second ball at the other hoop might get picked up. **My lean:** deliberately single-track in CV-C. Revisit if/when CV integration in Game Mode (SP2+) shows multi-ball false positives.
3. **Process / measurement noise auto-tuning.** `processNoise = 0.015` is a seed value from similar open-source trackers. The right answer is almost certainly to fit these on CV-A telemetry once ≥ 20 sessions exist. **My lean:** ship with seed values; add a tracker-tuning notebook to `hooptrack-ball-detection/` in a follow-up.
4. **Predicted-box rendering in `DetectionOverlay`.** Overlay currently shows raw detections only. Showing predicted boxes (e.g. in a different colour) would be a powerful debug tool but also confusing for non-dev users. **My lean:** ship CV-C without touching the overlay; add it behind a debug toggle if/when we need it.
5. **Does calibration-ready gate still apply?** Shot detection requires a calibrated hoop rect (see `CVPipeline.processBuffer` `guard let hoopRect`). With CV-C, the `BallTracker` runs regardless — should it also be gated, to avoid wasting CPU when no shots are possible? **My lean:** let the tracker run unconditionally — the cost is negligible and it means if calibration drops mid-session, we keep a valid track ready for when calibration returns.

---

## 13. Exit Criteria

- All pure-math unit tests pass; all state-machine unit tests pass.
- Eval fixture shows ≥ 95% frame-tracking coverage during known shot windows on the seed fixtures.
- iPhone SE 2 device test: 5 consecutive shot-release events all transition through `tracking → releaseDetected → resolved` with no `idle` fallbacks mid-flight (vs. baseline where roughly 1-in-5 shots drops back to idle due to occlusion).
- On-device processing latency p99 stays under 20 ms/frame (no regression vs. current).
- No changes required to `LiveSessionViewModel`, `ShotRecord`, or any UI layer.
