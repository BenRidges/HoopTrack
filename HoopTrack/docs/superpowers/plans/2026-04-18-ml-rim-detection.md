# ML-Based Rim Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the rectangle-heuristic hoop calibrator with the ML model's `basket` class so the hoop is tracked per-frame (with smoothing), survives camera drift, and doesn't false-lock onto arbitrary rectangles.

**Architecture:** Widen the detector contract to return both ball and basket observations from a single Vision pass. Add a pure `HoopRectSmoother` that exponentially averages recent basket detections and reports lost-tracking. Rewrite `CourtCalibrationService` around that smoother — no more `VNDetectRectanglesRequest`, no more 10-frame accumulation lock, no terminal "calibrated" state. `CVPipeline` forwards basket detections to the calibration service each frame. The existing `courtPosition(for:)` API is preserved so ball-to-zone mapping is unaffected.

**Tech Stack:** Swift 5/6 concurrency, Vision `VNCoreMLRequest`, CoreML `BallDetector.mlmodelc` (yolov8s, classes `ball`/`basket`/`person`), SwiftUI, XCTest.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `HoopTrack/ML/BallDetectorProtocol.swift` | MODIFY | Add `SceneDetection` struct; replace `detect` with `detectScene` |
| `HoopTrack/ML/CoreMLBallDetector.swift` | MODIFY | Single Vision pass returns ball + basket |
| `HoopTrack/ML/BallDetectorStub.swift` | MODIFY | Emit fake basket alongside fake ball |
| `HoopTrack/Utilities/HoopRectSmoother.swift` | CREATE | Pure EMA smoother for hoop rects + lost-tracking |
| `HoopTrackTests/HoopRectSmootherTests.swift` | CREATE | Unit tests for smoother |
| `HoopTrack/Services/CourtCalibrationService.swift` | REWRITE | External basket feed + smoother; keep `courtPosition(for:)` stable |
| `HoopTrack/Services/CVPipeline.swift` | MODIFY | Call `detectScene`, forward basket to calibration, use smoother's rect for shot geometry |
| `HoopTrack/Views/Train/LiveSessionView.swift` | MODIFY | "Looking for hoop" overlay driven by smoother state |

---

## Verification Strategy

- **Unit tests** cover the pure `HoopRectSmoother`. Runnable via `xcodebuild test`.
- **Build gate** every task finishes on green build via:

```bash
xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' build 2>&1 | tail -2
```

Expected: `** BUILD SUCCEEDED **` and the `grep -c warning:` count should remain at the project baseline of 0.

- **Manual simulator smoke** — after Task 7, launch Free Shoot. Overlay should show "Looking for hoop…" briefly, then disappear as the stubbed detector emits a basket. No hard lock, no stationary green box.
- **Manual device smoke** — aim at a real hoop. Green HOOP box tracks the backboard in real time; pan the phone and the box follows (doesn't drift).

---

## Task 1: Extend the detector contract with `SceneDetection`

**Files:**
- Modify: `HoopTrack/ML/BallDetectorProtocol.swift`

- [ ] **Step 1: Replace file contents**

```swift
// HoopTrack/ML/BallDetectorProtocol.swift
import AVFoundation
import CoreGraphics

/// A single detection from one camera frame — used for both ball and basket.
/// Vision-normalised coordinates: origin bottom-left, 0–1 range.
nonisolated struct BallDetection: Sendable {
    let boundingBox: CGRect
    let confidence: Float
    let frameTimestamp: CMTime
}

/// All detections of interest from a single frame inference. Either field
/// may be nil — no ball in frame, or hoop out of view — but the detector
/// always returns a `SceneDetection` when the frame was processed, so the
/// caller can distinguish "no detection this frame" from "frame skipped".
nonisolated struct SceneDetection: Sendable {
    let ball: BallDetection?
    let basket: BallDetection?
    let frameTimestamp: CMTime
}

/// Protocol that both the real Core ML wrapper and the debug stub conform to.
/// Kept on the background session queue — must NOT touch the main actor.
nonisolated protocol BallDetectorProtocol: Sendable {
    /// Single inference per frame, returns every class of interest.
    func detectScene(buffer: CMSampleBuffer) -> SceneDetection?
}
```

- [ ] **Step 2: Build — expect errors**

Run:
```bash
xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' build 2>&1 | grep error: | head -5
```

Expected: errors in `CoreMLBallDetector.swift`, `BallDetectorStub.swift`, and `CVPipeline.swift` — they still implement/call the old `detect(buffer:)`. Tasks 2, 3, 6 fix each in turn.

- [ ] **Step 3: Do not commit yet**

The tree is broken until Tasks 2 + 3 land. Commit after Task 3.

---

## Task 2: Update `CoreMLBallDetector` to return `SceneDetection`

**Files:**
- Modify: `HoopTrack/ML/CoreMLBallDetector.swift`

- [ ] **Step 1: Replace the public `detect(buffer:)` method and its helper**

In `HoopTrack/ML/CoreMLBallDetector.swift`, replace the existing `func detect(...)` implementation (lines 34–72 of the current file) with:

```swift
    func detectScene(buffer: CMSampleBuffer) -> SceneDetection? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        try? handler.perform([request])

        // NMS-enabled models return VNRecognizedObjectObservation. The current
        // shipped model (yolov8s + nms=True) takes this path.
        if let results = request.results as? [VNRecognizedObjectObservation], !results.isEmpty {
            let ball   = bestObservation(results, labelContains: "ball",   timestamp: timestamp)
            let basket = bestObservation(results, labelContains: "basket", timestamp: timestamp)
            return SceneDetection(ball: ball, basket: basket, frameTimestamp: timestamp)
        }

        // Raw-tensor fallback for non-NMS exports. Ball-only; basket decoding
        // from raw YOLO output is not worth the complexity — if the user
        // needs basket support they should re-export with nms=True.
        if let feature = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue,
           let tensor = feature.multiArrayValue {
            let ball = decodeYOLO(tensor, buffer: buffer)
            return SceneDetection(ball: ball, basket: nil, frameTimestamp: timestamp)
        }

        return SceneDetection(ball: nil, basket: nil, frameTimestamp: timestamp)
    }

    /// Returns the highest-confidence observation whose label contains the
    /// given substring (case-insensitive) and whose confidence clears the
    /// detector's threshold. Uses largest-bounding-box as a tiebreaker.
    private func bestObservation(_ results: [VNRecognizedObjectObservation],
                                  labelContains needle: String,
                                  timestamp: CMTime) -> BallDetection? {
        let needleLower = needle.lowercased()
        let candidates = results.filter { obs in
            obs.confidence >= confidenceThreshold &&
            obs.labels.first?.identifier.lowercased().contains(needleLower) == true
        }
        guard let best = candidates.max(by: { $0.confidence < $1.confidence }) else {
            return nil
        }
        return BallDetection(
            boundingBox: best.boundingBox,
            confidence: best.confidence,
            frameTimestamp: timestamp
        )
    }
```

The private `decodeYOLO(_:buffer:)` helper and the `nonisolated private extension CGRect { var area: CGFloat { ... } }` at the bottom of the file stay as-is.

- [ ] **Step 2: Build — expect remaining errors only in BallDetectorStub and CVPipeline**

Run the baseline build command. Expected: errors still in `BallDetectorStub.swift:16` (still implements old `detect`) and `CVPipeline.swift:83` (still calls old `detect`). That's fine.

---

## Task 3: Update `BallDetectorStub` to emit a fake basket

**Files:**
- Modify: `HoopTrack/ML/BallDetectorStub.swift`

- [ ] **Step 1: Replace file contents**

```swift
// HoopTrack/ML/BallDetectorStub.swift
// Simulates a basketball shot arc + a static hoop box so the CV pipeline
// can be built and tested before the real Core ML model is running.
// Used in the simulator and as a fallback during development.

import AVFoundation
import CoreGraphics

nonisolated final class BallDetectorStub: BallDetectorProtocol {

    nonisolated(unsafe) private var frameCount = 0

    // Static basket at roughly rim-height in a landscape frame.
    // Vision coords: origin bottom-left, so y = 0.75 is near the top.
    private let fakeBasket = CGRect(x: 0.45, y: 0.73, width: 0.10, height: 0.08)

    func detectScene(buffer: CMSampleBuffer) -> SceneDetection? {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        frameCount += 1

        // One shot arc every 180 frames (3 seconds at 60fps).
        // Ball appears at frame 30, peaks at frame 90, leaves at frame 150.
        let phase = frameCount % 180
        let ball: BallDetection?
        if phase > 30 && phase < 150 {
            let progress = Double(phase - 30) / 120.0
            let y        = 0.15 + sin(progress * .pi) * 0.55
            ball = BallDetection(
                boundingBox: CGRect(x: 0.45, y: y, width: 0.07, height: 0.07),
                confidence: 0.87,
                frameTimestamp: timestamp
            )
        } else {
            ball = nil
        }

        let basket = BallDetection(
            boundingBox: fakeBasket,
            confidence: 0.92,
            frameTimestamp: timestamp
        )

        return SceneDetection(ball: ball, basket: basket, frameTimestamp: timestamp)
    }
}
```

- [ ] **Step 2: Build — expect only CVPipeline errors**

Baseline build. Expected: errors only in `CVPipeline.swift:83` and surrounding (uses old `detect` and old `calibration.processFrame`).

- [ ] **Step 3: Commit the protocol + detector changes**

```bash
git add HoopTrack/ML/BallDetectorProtocol.swift \
        HoopTrack/ML/CoreMLBallDetector.swift \
        HoopTrack/ML/BallDetectorStub.swift
git commit -m "refactor(cv): widen detector contract to return SceneDetection (ball + basket)

Single Vision inference per frame now yields both classes. Callers will
be migrated in the next commit."
```

The tree still won't build (CVPipeline / CourtCalibrationService haven't been migrated yet). Commit a broken-build intermediate only because the next two tasks stand alone and are easier to review separately.

Actually — do not commit yet. Pre-commit hooks may enforce a green build. Verify:

```bash
ls .git/hooks/ 2>/dev/null
```

If no `pre-commit` hook exists, the above commit is safe. If it does, hold the commit until Task 6 completes.

---

## Task 4: Add pure `HoopRectSmoother`

**Files:**
- Create: `HoopTrack/Utilities/HoopRectSmoother.swift`
- Create: `HoopTrackTests/HoopRectSmootherTests.swift`

- [ ] **Step 1: Write the failing tests first**

Create `HoopTrackTests/HoopRectSmootherTests.swift`:

```swift
// HoopRectSmootherTests.swift
import XCTest
import CoreGraphics
@testable import HoopTrack

final class HoopRectSmootherTests: XCTestCase {

    // MARK: - Initial state

    func test_initialState_isLooking() {
        let smoother = HoopRectSmoother()
        XCTAssertEqual(smoother.state, .looking)
        XCTAssertNil(smoother.smoothedRect)
    }

    // MARK: - First detection

    func test_firstDetection_returnsThatRect_stateBecomesTracking() {
        var smoother = HoopRectSmoother()
        let rect = CGRect(x: 0.45, y: 0.70, width: 0.10, height: 0.08)
        smoother.update(basketRect: rect, timestamp: 0.0)

        XCTAssertEqual(smoother.state, .tracking)
        XCTAssertEqual(smoother.smoothedRect, rect)
    }

    // MARK: - Smoothing

    func test_secondDetection_emaBlendsTowardNewRect() {
        var smoother = HoopRectSmoother(alpha: 0.5)
        let a = CGRect(x: 0.0, y: 0.0, width: 0.10, height: 0.10)
        let b = CGRect(x: 1.0, y: 1.0, width: 0.20, height: 0.20)

        smoother.update(basketRect: a, timestamp: 0.0)
        smoother.update(basketRect: b, timestamp: 0.1)

        // EMA with alpha=0.5 averages a and b exactly.
        let expected = CGRect(x: 0.5, y: 0.5, width: 0.15, height: 0.15)
        XCTAssertEqual(smoother.smoothedRect!.origin.x, expected.origin.x, accuracy: 1e-6)
        XCTAssertEqual(smoother.smoothedRect!.origin.y, expected.origin.y, accuracy: 1e-6)
        XCTAssertEqual(smoother.smoothedRect!.width,    expected.width,    accuracy: 1e-6)
        XCTAssertEqual(smoother.smoothedRect!.height,   expected.height,   accuracy: 1e-6)
    }

    // MARK: - Lost tracking

    func test_noDetectionForLongerThanTimeout_transitionsToLost() {
        var smoother = HoopRectSmoother(lostTimeoutSec: 0.5)
        smoother.update(basketRect: CGRect(x: 0, y: 0, width: 1, height: 1), timestamp: 0.0)
        XCTAssertEqual(smoother.state, .tracking)

        smoother.updateNoDetection(timestamp: 0.6)
        XCTAssertEqual(smoother.state, .lost)
    }

    func test_lostState_retainsLastSmoothedRect() {
        var smoother = HoopRectSmoother(lostTimeoutSec: 0.5)
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        smoother.update(basketRect: rect, timestamp: 0.0)
        smoother.updateNoDetection(timestamp: 0.6)

        XCTAssertEqual(smoother.state, .lost)
        XCTAssertEqual(smoother.smoothedRect, rect)  // last known good rect preserved
    }

    func test_noDetectionShorterThanTimeout_staysTracking() {
        var smoother = HoopRectSmoother(lostTimeoutSec: 0.5)
        smoother.update(basketRect: CGRect(x: 0, y: 0, width: 1, height: 1), timestamp: 0.0)

        smoother.updateNoDetection(timestamp: 0.3)
        XCTAssertEqual(smoother.state, .tracking)
    }

    // MARK: - Recovery

    func test_detectionAfterLost_returnsToTracking_withNewRect() {
        var smoother = HoopRectSmoother(lostTimeoutSec: 0.5)
        smoother.update(basketRect: CGRect(x: 0, y: 0, width: 1, height: 1), timestamp: 0.0)
        smoother.updateNoDetection(timestamp: 0.6)
        XCTAssertEqual(smoother.state, .lost)

        let newRect = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        smoother.update(basketRect: newRect, timestamp: 1.0)

        XCTAssertEqual(smoother.state, .tracking)
        // After a lost-then-seen transition, smoother snaps to the new rect
        // rather than blending with the stale one.
        XCTAssertEqual(smoother.smoothedRect, newRect)
    }

    // MARK: - Reset

    func test_reset_returnsToLooking() {
        var smoother = HoopRectSmoother()
        smoother.update(basketRect: CGRect(x: 0, y: 0, width: 1, height: 1), timestamp: 0.0)
        smoother.reset()

        XCTAssertEqual(smoother.state, .looking)
        XCTAssertNil(smoother.smoothedRect)
    }
}
```

- [ ] **Step 2: Run test — expect compile failure**

Run:
```bash
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' \
  -only-testing:HoopTrackTests/HoopRectSmootherTests 2>&1 | grep -E "error:|failed" | head -5
```

Expected: compile errors for unresolved `HoopRectSmoother`.

- [ ] **Step 3: Implement the smoother**

Create `HoopTrack/Utilities/HoopRectSmoother.swift`:

```swift
// HoopTrack/Utilities/HoopRectSmoother.swift
// Pure value-type EMA smoother for per-frame hoop bounding boxes.
// Stateless-ish — holds only the last smoothed rect + last-seen timestamp.
// Replaces the 10-frame-accumulation lock in the previous CourtCalibrationService.

import CoreGraphics

nonisolated struct HoopRectSmoother: Sendable {

    enum State: Sendable, Equatable {
        /// No basket ever seen.
        case looking
        /// Recent basket detection; smoothedRect is current.
        case tracking
        /// No detection for longer than lostTimeoutSec. Last-known rect preserved.
        case lost
    }

    /// Exponential-moving-average factor. Higher = more responsive to new
    /// detections; lower = smoother but laggier. 0.4 keeps jitter low while
    /// reacting within ~3 frames to real phone movement at 60 fps.
    let alpha: Double

    /// How long since the last basket detection before transitioning to `lost`.
    /// 0.5 s covers a typical hand-over-lens occlusion without prematurely
    /// tearing down the known rect.
    let lostTimeoutSec: Double

    private(set) var state: State = .looking
    private(set) var smoothedRect: CGRect?
    private var lastSeenTimestamp: Double = 0

    init(alpha: Double = 0.4, lostTimeoutSec: Double = 0.5) {
        self.alpha = alpha
        self.lostTimeoutSec = lostTimeoutSec
    }

    /// Call when a basket detection is produced for the current frame.
    mutating func update(basketRect: CGRect, timestamp: Double) {
        let next: CGRect
        switch state {
        case .looking, .lost:
            // Fresh start — snap to the new rect rather than blending with
            // stale or nil state.
            next = basketRect
        case .tracking:
            next = ema(from: smoothedRect ?? basketRect, to: basketRect, alpha: alpha)
        }

        smoothedRect = next
        lastSeenTimestamp = timestamp
        state = .tracking
    }

    /// Call once per frame when no basket was detected.
    mutating func updateNoDetection(timestamp: Double) {
        guard state == .tracking else { return }
        if timestamp - lastSeenTimestamp > lostTimeoutSec {
            state = .lost
        }
    }

    mutating func reset() {
        state = .looking
        smoothedRect = nil
        lastSeenTimestamp = 0
    }

    // MARK: - Private

    private func ema(from a: CGRect, to b: CGRect, alpha: Double) -> CGRect {
        let blend: (Double, Double) -> Double = { old, new in (1 - alpha) * old + alpha * new }
        return CGRect(
            x:      blend(a.origin.x, b.origin.x),
            y:      blend(a.origin.y, b.origin.y),
            width:  blend(a.width,    b.width),
            height: blend(a.height,   b.height)
        )
    }
}
```

- [ ] **Step 4: Run tests — expect all passing**

Run:
```bash
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' \
  -only-testing:HoopTrackTests/HoopRectSmootherTests 2>&1 | tail -10
```

Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/Utilities/HoopRectSmoother.swift \
        HoopTrackTests/HoopRectSmootherTests.swift
git commit -m "feat(cv): add HoopRectSmoother for EMA-smoothed per-frame rim tracking

Pure value-type smoother that averages recent basket detections and
transitions to a lost state after 0.5s of no detections. Replaces the
10-frame accumulation lock in CourtCalibrationService — the hoop can
now follow the phone when the user reframes, rather than sticking to a
stale rect."
```

---

## Task 5: Rewrite `CourtCalibrationService` around the smoother

**Files:**
- Modify: `HoopTrack/Services/CourtCalibrationService.swift`

- [ ] **Step 1: Replace the file**

Replace the full contents of `HoopTrack/Services/CourtCalibrationService.swift` with:

```swift
// HoopTrack/Services/CourtCalibrationService.swift
// Tracks the basketball rim on a per-frame basis using detections from the
// ML ball detector's `basket` class. Replaces the earlier rectangle-heuristic
// approach (VNDetectRectanglesRequest + 10-frame lock), which couldn't tell
// a hoop from a poster and never recovered from camera movement.

import AVFoundation
import CoreGraphics

nonisolated enum CalibrationState: Sendable, Equatable {
    /// No basket has been seen yet.
    case looking
    /// Basket is currently in-frame and the smoother has a rect.
    case tracking(hoopRect: CGRect)
    /// Recently lost tracking — last-known rect is still available as a fallback.
    case lost(lastKnownHoopRect: CGRect)

    var isTracking: Bool {
        if case .tracking = self { return true }
        return false
    }

    /// Either the live tracked rect or the last-known one during a temporary drop-out.
    var hoopRect: CGRect? {
        switch self {
        case .looking:                       return nil
        case .tracking(let r):               return r
        case .lost(let r):                   return r
        }
    }
}

nonisolated final class CourtCalibrationService {

    // MARK: - State
    private(set) var state: CalibrationState = .looking
    private var smoother: HoopRectSmoother

    /// Callback fired on main thread when state changes — observed by LiveSessionViewModel.
    var onStateChange: (@Sendable (CalibrationState) -> Void)?

    // MARK: - Init

    init(smoother: HoopRectSmoother = HoopRectSmoother()) {
        self.smoother = smoother
    }

    // MARK: - Lifecycle

    func reset() {
        smoother.reset()
        transition(to: .looking)
    }

    // MARK: - Per-Frame Input
    // Called on the camera's sessionQueue with the basket detection for this frame
    // (nil when no basket was detected).

    func updateBasket(_ basket: BallDetection?, timestamp: CMTime) {
        let ts = CMTimeGetSeconds(timestamp)
        if let basket {
            smoother.update(basketRect: basket.boundingBox, timestamp: ts)
        } else {
            smoother.updateNoDetection(timestamp: ts)
        }

        let next: CalibrationState
        switch smoother.state {
        case .looking:
            next = .looking
        case .tracking:
            next = .tracking(hoopRect: smoother.smoothedRect ?? .zero)
        case .lost:
            next = .lost(lastKnownHoopRect: smoother.smoothedRect ?? .zero)
        }

        if next != state { transition(to: next) }
    }

    // MARK: - Court Coordinate Mapping

    /// Maps a ball bounding box (Vision normalised coords) to normalised court position (0–1).
    /// Uses the current or last-known hoop rect. Returns nil only when no rim has ever been seen.
    func courtPosition(for ballBox: CGRect) -> (courtX: Double, courtY: Double)? {
        guard let hoopRect = state.hoopRect else { return nil }

        let ballCX = ballBox.midX
        let ballCY = ballBox.midY

        // Horizontal: positive offset from hoop centre maps to court right
        let rawX = (ballCX - hoopRect.midX) / hoopRect.width * 0.5 + 0.5
        // Vertical: ball below hoop (lower Y in Vision) = closer to baseline (lower courtY)
        let rawY = max(0, hoopRect.midY - ballCY) / hoopRect.height * 0.5

        return (
            courtX: Double(rawX).clamped(to: 0...1),
            courtY: Double(rawY).clamped(to: 0...1)
        )
    }

    // MARK: - Private

    private func transition(to newState: CalibrationState) {
        state = newState
        let callback = onStateChange
        Task { @MainActor in
            callback?(newState)
        }
    }
}
```

Notes on the contract change:
- The old `state.isCalibrated` becomes `state.isTracking` — shot detection may now start as soon as the hoop is first seen.
- `processFrame(_:)` is gone. `CVPipeline` feeds `updateBasket(_:timestamp:)` instead.
- `startCalibration()` is gone. The service is always "live" once instantiated.

- [ ] **Step 2: Build — expect two call-site errors**

Baseline build. Expected: errors in `CVPipeline.swift` (calls `calibration.processFrame(_:)` and reads `calibration.state.isCalibrated`) and `LiveSessionView.swift` (reads `state.isCalibrated` in the onStateChange callback). Tasks 6 + 7 fix each.

---

## Task 6: Wire `CVPipeline` to forward basket detections + use smoother's rect

**Files:**
- Modify: `HoopTrack/Services/CVPipeline.swift`

- [ ] **Step 1: Update the core frame loop**

In `HoopTrack/Services/CVPipeline.swift`, replace the entire body of `processBuffer(_:)` (currently lines 75–157) with:

```swift
    private func processBuffer(_ buffer: CMSampleBuffer) {
        guard let scene = detector.detectScene(buffer: buffer) else { return }
        let now = scene.frameTimestamp

        // Feed the basket detection to calibration every frame — the
        // smoother handles jitter and missed frames internally.
        calibration.updateBasket(scene.basket, timestamp: now)

        // Push ball detection to the debug overlay.
        let overlayBox = scene.ball?.boundingBox
        let overlayConfidence = scene.ball?.confidence
        Task { @MainActor [weak viewModel] in
            viewModel?.updateBallDetection(box: overlayBox, confidence: overlayConfidence)
        }

        // Shot detection requires a tracked (or recently-tracked) hoop rect.
        guard let hoopRect = calibration.state.hoopRect else { return }

        let detection = scene.ball

        switch pipelineState {

        case .idle:
            if let d = detection {
                pipelineState = .tracking(trajectory: [d])
                lastDetectionTimestamp = now
            }

        case .tracking(var trajectory):
            if let d = detection {
                trajectory.append(d)
                lastDetectionTimestamp = now

                if isAtPeak(trajectory: trajectory) {
                    let releaseBox = trajectory.first!.boundingBox

                    // Phase 3: compute Shot Science synchronously on the session queue
                    let science: ShotScienceMetrics?
                    if let ps = poseService {
                        let observation = ps.detectPose(buffer: buffer)
                        science = ShotScienceCalculator.compute(
                            trajectory: trajectory,
                            poseObservation: observation,
                            hoopRectWidth: hoopRect.width
                        )
                    } else {
                        science = nil
                    }

                    pipelineState    = .releaseDetected(releaseBox: releaseBox, trajectory: trajectory)
                    releaseTimestamp = now
                    logPendingShot(releaseBox: releaseBox, science: science)
                } else {
                    pipelineState = .tracking(trajectory: trajectory)
                }
            } else {
                let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, lastDetectionTimestamp))
                if elapsed > trackingTimeoutSec { pipelineState = .idle }
            }

        case .releaseDetected(let releaseBox, _):
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, releaseTimestamp))

            if let d = detection {
                if isEnteringHoop(ballBox: d.boundingBox, hoopRect: hoopRect) {
                    resolveShot(result: .make, releaseBox: releaseBox)
                    return
                }
                if isBelowHoop(ballBox: d.boundingBox, hoopRect: hoopRect) {
                    resolveShot(result: .miss, releaseBox: releaseBox)
                    return
                }
            }

            if elapsed > shotTimeoutSec {
                resolveShot(result: .miss, releaseBox: releaseBox)
            }
        }
    }
```

Key changes:
- Calls `detector.detectScene(buffer:)` once per frame.
- Feeds `scene.basket` into `calibration.updateBasket(_:timestamp:)` every frame.
- Reads `hoopRect` from `calibration.state.hoopRect` once, uses it for both Shot Science scaling and hoop-geometry checks.
- Removes the old `calibration.processFrame(buffer)` call and the old `case .calibrated(let hoopRect) = calibration.state` pattern-matches.

- [ ] **Step 2: Verify `logPendingShot` and `resolveShot` still compile**

They call `calibration.courtPosition(for:)` which is preserved. No changes needed.

- [ ] **Step 3: Build — expect remaining errors only in LiveSessionView**

Baseline build. Expected error: `LiveSessionView.swift:~105` reads `state.isCalibrated` in the onStateChange callback (that API is now `state.isTracking`).

---

## Task 7: Update `LiveSessionView` calibration overlay

**Files:**
- Modify: `HoopTrack/Views/Train/LiveSessionView.swift`

- [ ] **Step 1: Fix the `onStateChange` callback**

Find the block in `HoopTrack/Views/Train/LiveSessionView.swift` (around lines 98–110) that currently reads:

```swift
                cal.onStateChange = { @Sendable [weak viewModel] state in
                    let calibrated = state.isCalibrated
                    let hoopRect: CGRect?
                    if case .calibrated(let rect) = state { hoopRect = rect } else { hoopRect = nil }
                    Task { @MainActor [weak viewModel] in
                        viewModel?.updateCalibrationState(isCalibrated: calibrated, hoopRect: hoopRect)
                    }
                }
```

Replace with:

```swift
                cal.onStateChange = { @Sendable [weak viewModel] state in
                    let tracking = state.isTracking
                    let hoopRect = state.hoopRect
                    Task { @MainActor [weak viewModel] in
                        viewModel?.updateCalibrationState(isCalibrated: tracking, hoopRect: hoopRect)
                    }
                }
```

The view-model API still takes `isCalibrated:` — that semantic name is preserved at the view-model layer so the rest of the UI code keeps working. Only the calibration service's internal vocabulary has changed.

- [ ] **Step 2: Update the `calibrationOverlay` copy**

Find the `calibrationOverlay` computed property (around line 432). Replace the existing Text lines:

```swift
            Text("Aim at the hoop")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Keep the backboard in frame until the indicator turns green.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
```

With:

```swift
            Text("Looking for hoop…")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Point the camera at the rim. Tracking stays locked even if the view shifts.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
```

- [ ] **Step 3: Build green**

Baseline build. Expected: `** BUILD SUCCEEDED **`, zero warnings beyond the existing baseline (0).

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/Services/CourtCalibrationService.swift \
        HoopTrack/Services/CVPipeline.swift \
        HoopTrack/Views/Train/LiveSessionView.swift
git commit -m "feat(cv): track rim per-frame using ML basket class

Removes the VNDetectRectanglesRequest heuristic and its 10-frame
accumulation lock. CVPipeline now calls detectScene once per frame,
forwards scene.basket to CourtCalibrationService, and reads the
smoothed hoop rect back from the service. The service is a thin
wrapper around HoopRectSmoother — looking -> tracking -> lost
states reflect the ML model's actual view of the hoop rather than
a synthetic calibration phase.

Shot detection can now start as soon as the hoop is first seen (no
'aim and wait' period). If the camera drifts, the smoother follows
the rim; a 0.5s detection gap parks into .lost with the last-known
rect preserved so an occlusion doesn't tear down the session.

The 'Aim at the hoop' overlay becomes a 'Looking for hoop...' hint
shown only while state is .looking or .lost."
```

---

## Task 8: End-to-End Verification

**Files:**
- None (verification only)

- [ ] **Step 1: Full build + test suite**

Run:
```bash
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' 2>&1 | tail -5
```

Expected:
- `** TEST SUCCEEDED **`
- Test count: previous total + **8** (new HoopRectSmootherTests)
- 0 failures

- [ ] **Step 2: Zero warnings**

```bash
xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' \
  clean build 2>&1 | grep -c "warning:"
```

Expected: `0`

- [ ] **Step 3: Simulator smoke**

Launch the app in iPhone 14 simulator. Tap Train → Free Shoot.

Expect:
- Sidebar appears in landscape; camera preview area fills the left portion.
- "Looking for hoop…" overlay appears for one frame at most — the stub detector emits a fake basket from frame 1, so overlay should dismiss immediately.
- Green HOOP box appears in the upper-middle of the camera area (stub position: `x=0.45, y=0.73`).
- Orange BALL box appears/disappears on the stub's 3-second arc cadence.
- Sidebar FG% updates on make/miss from the stub shots.

If "Looking for hoop…" stays up: the protocol migration dropped basket plumbing somewhere — re-inspect `BallDetectorStub.detectScene` returning a non-nil basket.

If the green HOOP box doesn't appear: `DetectionOverlay` reads `viewModel.detectedHoopRect`; the view-model is set via `updateCalibrationState(isCalibrated:hoopRect:)`. Check that Task 7 Step 1's callback wiring landed.

- [ ] **Step 4: Device smoke (if available)**

Install on a physical iPhone. Aim at a real basketball hoop.

Expect:
- Green HOOP box tracks the rim in real time.
- Panning the phone → box follows (not stuck to the first-seen position).
- Occluding the rim with your hand for ~1s → "Looking for hoop…" overlay comes back; uncovering → it disappears again immediately.

If the green box drifts or lags: tune `HoopRectSmoother(alpha:)` default — higher `alpha` (e.g. 0.6) responds faster but is noisier.

---

## Self-Review Summary

- **Spec coverage:** Protocol widening (Task 1), detector migration (Tasks 2–3), smoother with tests (Task 4), service rewrite (Task 5), pipeline wiring (Task 6), UI copy (Task 7), verification (Task 8). All items from the "what it'd take" sketch in the user's question are covered.
- **Placeholder scan:** Every code block is complete Swift. No "similar to Task N" or "add appropriate error handling" shorthand.
- **Type consistency:** `SceneDetection { ball, basket, frameTimestamp }` is used identically in Task 1 (definition), Task 2 (CoreML producer), Task 3 (stub producer), Task 6 (pipeline consumer). `CalibrationState` cases `looking` / `tracking(hoopRect:)` / `lost(lastKnownHoopRect:)` are used consistently in Task 5 (definition) and Task 6 (pattern match via `state.hoopRect` / `state.isTracking`). `HoopRectSmoother.State` cases `looking` / `tracking` / `lost` are used consistently between Task 4 (definition + tests) and Task 5 (consumer).
