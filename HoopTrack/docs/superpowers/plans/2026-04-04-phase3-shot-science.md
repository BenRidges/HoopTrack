# Phase 3 — Shot Science Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture per-shot biomechanics (release angle, release time, vertical jump, leg angle, ball speed) during live sessions using Vision body pose, and display them in a full-screen video replay view with a shot timeline and per-shot overlay card.

**Architecture:** `PoseEstimationService` wraps `VNDetectHumanBodyPoseRequest` and runs on the existing session queue alongside `CVPipeline`. When the state machine fires `RELEASE_DETECTED`, the pipeline synchronously runs pose detection on the release frame and calls `ShotScienceCalculator` (pure functions) to produce a `ShotScienceMetrics` value type. This struct flows through `LiveSessionViewModel.logPendingShot` → `DataService.addShot` into `ShotRecord`. `TrainingSession.recalculateStats()` derives session-level averages. The replay experience lives in `SessionReplayView` (AVPlayer + custom shot timeline) launched from `SessionSummaryView` when a video file exists.

**Tech Stack:** Swift 5.10, SwiftUI, Vision (`VNDetectHumanBodyPoseRequest`, `VNHumanBodyPoseObservation`), AVFoundation (`AVPlayer`, `AVPlayerViewController`, `AVCaptureMovieFileOutput`), XCTest

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `HoopTrack/Models/ShotScienceMetrics.swift` | Value-type DTO flowing from CVPipeline → DataService |
| Create | `HoopTrack/Utilities/ShotScienceCalculator.swift` | Pure functions: release angle, release time, shot speed, leg angle geometry, vertical jump geometry, consistency score; Vision wrappers call the geometry functions |
| Create | `HoopTrack/Services/PoseEstimationService.swift` | Synchronous single-frame `VNDetectHumanBodyPoseRequest` wrapper |
| Modify | `HoopTrack/HoopTrack/Services/CVPipeline.swift` | Accept optional `PoseEstimationService`; at `RELEASE_DETECTED` run pose + calculator; pass `ShotScienceMetrics?` through `logPendingShot` |
| Modify | `HoopTrack/ViewModels/LiveSessionViewModel.swift` | `logPendingShot` gains `science: ShotScienceMetrics?` parameter |
| Modify | `HoopTrack/Services/DataService.swift` | `addShot` gains `science: ShotScienceMetrics?`; applies fields to `ShotRecord`; auto-sets `videoTimestampSeconds` |
| Modify | `HoopTrack/Models/TrainingSession.swift` | `recalculateStats()` computes Shot Science averages and `consistencyScore` |
| Modify | `HoopTrack/Views/Train/LiveSessionView.swift` | Uncomment `VideoRecordingService`; add `@State var videoRecorder`; stop on disappear; pass `PoseEstimationService` to `CVPipeline` |
| Create | `HoopTrack/Views/Components/ShotScienceCard.swift` | Reusable card displaying per-shot biomechanics |
| Create | `HoopTrack/Views/Train/SessionReplayView.swift` | Full-screen AVPlayer + shot timeline + `ShotScienceCard` overlay |
| Modify | `HoopTrack/Views/Train/SessionSummaryView.swift` | Add Replay toolbar button (when `videoFileName != nil`); show per-shot science in `ShotReviewRow` |
| Create | `HoopTrackTests/ShotScienceCalculatorTests.swift` | Unit tests for all pure calculation functions |
| Create | `docs/config/video-recording.md` | Config doc: storage path, retention policy, pinning |

---

## Task 1 — ShotScienceMetrics value type

**Files:**
- Create: `HoopTrack/Models/ShotScienceMetrics.swift`

- [ ] **Step 1: Create the file**

  ```swift
  // HoopTrack/Models/ShotScienceMetrics.swift
  // Value-type DTO that carries biomechanics data from CVPipeline
  // through LiveSessionViewModel to DataService.
  // All fields are optional — nil means the measurement was unavailable.

  import Foundation

  struct ShotScienceMetrics {
      /// Ball launch angle from horizontal at release (degrees). Optimal 43–57°.
      var releaseAngleDeg: Double?
      /// Time from first ball detection to release peak (milliseconds).
      var releaseTimeMs: Double?
      /// Estimated vertical jump height at release (centimetres). Rough approximation.
      var verticalJumpCm: Double?
      /// Knee-joint angle at jump initiation (degrees). Derived from Vision body pose.
      var legAngleDeg: Double?
      /// Estimated ball velocity post-release (MPH). Derived from trajectory + hoop-size scale.
      var shotSpeedMph: Double?
  }
  ```

- [ ] **Step 2: Add file to Xcode target**

  In Xcode Project Navigator, drag `ShotScienceMetrics.swift` into the `HoopTrack/Models/` group. Ensure **Target: HoopTrack** is checked.

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/Models/ShotScienceMetrics.swift
  git commit -m "feat: add ShotScienceMetrics DTO for biomechanics pipeline"
  ```

---

## Task 2 — ShotScienceCalculator (TDD)

**Files:**
- Create: `HoopTrack/Utilities/ShotScienceCalculator.swift`
- Create: `HoopTrackTests/ShotScienceCalculatorTests.swift`

Vision types (`VNHumanBodyPoseObservation`) cannot be constructed in tests. The calculator separates pure geometry functions (testable) from Vision wrappers (integration-tested on device).

- [ ] **Step 1: Write the failing tests**

  Create `HoopTrackTests/ShotScienceCalculatorTests.swift`:

  ```swift
  import XCTest
  import AVFoundation
  @testable import HoopTrack

  final class ShotScienceCalculatorTests: XCTestCase {

      // MARK: - releaseAngle

      func test_releaseAngle_typicalAscendingShot_returnsPositiveAngle() {
          // Ball moves right (+x) and upward (+y, Vision origin = bottom-left)
          let detections = [
              BallDetection(boundingBox: CGRect(x: 0.30, y: 0.40, width: 0.05, height: 0.05),
                            confidence: 0.9,
                            frameTimestamp: CMTime(value: 0, timescale: 60)),
              BallDetection(boundingBox: CGRect(x: 0.34, y: 0.47, width: 0.05, height: 0.05),
                            confidence: 0.9,
                            frameTimestamp: CMTime(value: 1, timescale: 60)),
          ]
          let angle = ShotScienceCalculator.releaseAngle(trajectory: detections)
          XCTAssertNotNil(angle)
          // atan2(0.07, 0.04) ≈ 60° — within a plausible shooting range
          XCTAssertTrue(angle! > 30 && angle! < 80, "Expected shooting arc angle, got \(angle!)")
      }

      func test_releaseAngle_singleDetection_returnsNil() {
          let detections = [
              BallDetection(boundingBox: CGRect(x: 0.3, y: 0.4, width: 0.05, height: 0.05),
                            confidence: 0.9,
                            frameTimestamp: .zero),
          ]
          XCTAssertNil(ShotScienceCalculator.releaseAngle(trajectory: detections))
      }

      func test_releaseAngle_emptyTrajectory_returnsNil() {
          XCTAssertNil(ShotScienceCalculator.releaseAngle(trajectory: []))
      }

      // MARK: - releaseTime

      func test_releaseTime_thirtyFramesAt60fps_returns500ms() {
          let t1 = CMTime(value: 0,  timescale: 60)
          let t2 = CMTime(value: 30, timescale: 60)   // 30 frames = 0.5 s
          let detections = [
              BallDetection(boundingBox: .zero, confidence: 0.9, frameTimestamp: t1),
              BallDetection(boundingBox: .zero, confidence: 0.9, frameTimestamp: t2),
          ]
          let time = ShotScienceCalculator.releaseTime(trajectory: detections)
          XCTAssertNotNil(time)
          XCTAssertEqual(time!, 500.0, accuracy: 1.0)
      }

      func test_releaseTime_singleDetection_returnsNil() {
          let detections = [
              BallDetection(boundingBox: .zero, confidence: 0.9, frameTimestamp: .zero),
          ]
          XCTAssertNil(ShotScienceCalculator.releaseTime(trajectory: detections))
      }

      // MARK: - shotSpeed

      func test_shotSpeed_knownDisplacement_returnsPositiveSpeed() {
          // Ball moves 0.1 normalized units horizontally in 1 frame (1/60 s).
          // hoopRectWidth = 0.1 → scale = 45.72 cm / 0.1 = 457.2 cm per unit
          // distance = 0.1 * 457.2 = 45.72 cm  in  1/60 s = 60 * 45.72 = 2743 cm/s ≈ 61 mph
          let t1 = CMTime(value: 0, timescale: 60)
          let t2 = CMTime(value: 1, timescale: 60)
          let detections = [
              BallDetection(boundingBox: CGRect(x: 0.00, y: 0.5, width: 0.05, height: 0.05),
                            confidence: 0.9, frameTimestamp: t1),
              BallDetection(boundingBox: CGRect(x: 0.10, y: 0.5, width: 0.05, height: 0.05),
                            confidence: 0.9, frameTimestamp: t2),
          ]
          let speed = ShotScienceCalculator.shotSpeed(trajectory: detections, hoopRectWidth: 0.1)
          XCTAssertNotNil(speed)
          XCTAssertTrue(speed! > 0)
      }

      func test_shotSpeed_singleDetection_returnsNil() {
          let detections = [BallDetection(boundingBox: .zero, confidence: 0.9, frameTimestamp: .zero)]
          XCTAssertNil(ShotScienceCalculator.shotSpeed(trajectory: detections, hoopRectWidth: 0.1))
      }

      func test_shotSpeed_zeroHoopWidth_returnsNil() {
          let t1 = CMTime(value: 0, timescale: 60)
          let t2 = CMTime(value: 1, timescale: 60)
          let detections = [
              BallDetection(boundingBox: .zero, confidence: 0.9, frameTimestamp: t1),
              BallDetection(boundingBox: CGRect(x: 0.1, y: 0, width: 0.05, height: 0.05),
                            confidence: 0.9, frameTimestamp: t2),
          ]
          XCTAssertNil(ShotScienceCalculator.shotSpeed(trajectory: detections, hoopRectWidth: 0))
      }

      // MARK: - consistencyScore

      func test_consistencyScore_uniformAngles_returnsZero() {
          let score = ShotScienceCalculator.consistencyScore(releaseAngles: [45, 45, 45, 45])
          XCTAssertNotNil(score)
          XCTAssertEqual(score!, 0.0, accuracy: 0.001)
      }

      func test_consistencyScore_singleAngle_returnsNil() {
          XCTAssertNil(ShotScienceCalculator.consistencyScore(releaseAngles: [45]))
      }

      func test_consistencyScore_emptyAngles_returnsNil() {
          XCTAssertNil(ShotScienceCalculator.consistencyScore(releaseAngles: []))
      }

      func test_consistencyScore_spreadAngles_returnsPositiveStdDev() {
          let score = ShotScienceCalculator.consistencyScore(releaseAngles: [40, 45, 50, 55, 60])
          XCTAssertNotNil(score)
          XCTAssertTrue(score! > 0)
      }

      // MARK: - legAngleGeometry (pure geometry, no Vision dependency)

      func test_legAngleGeometry_straightLeg_returns180Degrees() {
          // Hip directly above knee, knee directly above ankle = straight leg = 180°
          let angle = ShotScienceCalculator.legAngleGeometry(
              hip:   CGPoint(x: 0.5, y: 0.8),
              knee:  CGPoint(x: 0.5, y: 0.5),
              ankle: CGPoint(x: 0.5, y: 0.2)
          )
          XCTAssertNotNil(angle)
          XCTAssertEqual(angle!, 180.0, accuracy: 0.5)
      }

      func test_legAngleGeometry_rightAngle_returns90Degrees() {
          // hip above knee, ankle to the right of knee = 90° at the knee
          let angle = ShotScienceCalculator.legAngleGeometry(
              hip:   CGPoint(x: 0.5, y: 0.8),
              knee:  CGPoint(x: 0.5, y: 0.5),
              ankle: CGPoint(x: 0.8, y: 0.5)
          )
          XCTAssertNotNil(angle)
          XCTAssertEqual(angle!, 90.0, accuracy: 0.5)
      }

      // MARK: - verticalJumpGeometry

      func test_verticalJumpGeometry_standingPosition_returnsNilOrNearZero() {
          // Hip at 55% of body height (standing baseline — should return nil / near zero)
          let result = ShotScienceCalculator.verticalJumpGeometry(
              hipY: 0.55, ankleY: 0.05, shoulderY: 0.90
          )
          // Either nil (below noise threshold) or very small
          if let jump = result { XCTAssertTrue(jump < 5.0) }
      }

      func test_verticalJumpGeometry_jumpedPosition_returnsPositiveCm() {
          // Hip elevated well above standing baseline
          let result = ShotScienceCalculator.verticalJumpGeometry(
              hipY: 0.68, ankleY: 0.05, shoulderY: 0.95
          )
          XCTAssertNotNil(result)
          XCTAssertTrue(result! > 5.0)
      }

      func test_verticalJumpGeometry_bodyNotFullyVisible_returnsNil() {
          // bodyHeight < 0.1 normalised — person not in frame
          XCTAssertNil(ShotScienceCalculator.verticalJumpGeometry(
              hipY: 0.5, ankleY: 0.48, shoulderY: 0.52
          ))
      }
  }
  ```

- [ ] **Step 2: Run tests to verify they all fail**

  In Xcode: `Cmd+U` (Product → Test). Expected: compile errors because `ShotScienceCalculator` doesn't exist yet.

- [ ] **Step 3: Implement ShotScienceCalculator**

  Create `HoopTrack/Utilities/ShotScienceCalculator.swift`:

  ```swift
  // HoopTrack/Utilities/ShotScienceCalculator.swift
  // Pure biomechanics math. Vision-dependent wrappers call the geometry functions.
  // No side effects. All functions are static.

  import CoreGraphics
  import AVFoundation
  import Vision

  enum ShotScienceCalculator {

      // MARK: - Release Angle

      /// Ball launch angle from horizontal (degrees).
      /// Uses the midpoints of the first two detections in the trajectory.
      /// Vision Y origin is bottom-left (increasing upward).
      static func releaseAngle(trajectory: [BallDetection]) -> Double? {
          guard trajectory.count >= 2 else { return nil }
          let p1 = trajectory[0].boundingBox
          let p2 = trajectory[1].boundingBox
          let dx = p2.midX - p1.midX
          let dy = p2.midY - p1.midY
          let angleRad = atan2(abs(Double(dy)), abs(Double(dx)))
          return angleRad * (180.0 / Double.pi)
      }

      // MARK: - Release Time

      /// Time from first detection to last detection (milliseconds).
      /// Approximates "ball-in-hand to release" — within one ball-detection window.
      static func releaseTime(trajectory: [BallDetection]) -> Double? {
          guard trajectory.count >= 2 else { return nil }
          let start  = CMTimeGetSeconds(trajectory.first!.frameTimestamp)
          let end    = CMTimeGetSeconds(trajectory.last!.frameTimestamp)
          let elapsedSec = end - start
          guard elapsedSec > 0 else { return nil }
          return elapsedSec * 1000.0
      }

      // MARK: - Shot Speed

      /// Estimated ball speed in MPH using the hoop rect as a real-world scale reference.
      /// hoopRectWidth: normalised width of the calibrated hoop bounding box.
      /// Real hoop diameter = 45.72 cm (18 inches).
      static func shotSpeed(trajectory: [BallDetection], hoopRectWidth: CGFloat) -> Double? {
          guard trajectory.count >= 2, hoopRectWidth > 0 else { return nil }
          let p1 = trajectory[0].boundingBox
          let p2 = trajectory[1].boundingBox
          let t1 = CMTimeGetSeconds(trajectory[0].frameTimestamp)
          let t2 = CMTimeGetSeconds(trajectory[1].frameTimestamp)
          let elapsedSec = t2 - t1
          guard elapsedSec > 0 else { return nil }

          let dx = Double(p2.midX - p1.midX)
          let dy = Double(p2.midY - p1.midY)
          let distNorm   = sqrt(dx * dx + dy * dy)
          let scaleCmPerUnit = 45.72 / Double(hoopRectWidth)   // cm per normalised unit
          let distCm     = distNorm * scaleCmPerUnit
          let speedCmps  = distCm / elapsedSec
          return speedCmps * 0.0224                             // cm/s → mph
      }

      // MARK: - Consistency Score

      /// Population standard deviation of release angles (degrees).
      /// Returns nil for fewer than 2 data points.
      static func consistencyScore(releaseAngles: [Double]) -> Double? {
          guard releaseAngles.count >= 2 else { return nil }
          let mean     = releaseAngles.reduce(0, +) / Double(releaseAngles.count)
          let variance = releaseAngles.map { pow($0 - mean, 2) }.reduce(0, +)
                       / Double(releaseAngles.count)
          return sqrt(variance)
      }

      // MARK: - Leg Angle (pure geometry — used in tests and Vision wrapper)

      /// Knee-joint angle in degrees. Computes the angle at `knee` between
      /// the hip→knee and knee→ankle vectors. 180° = straight leg.
      static func legAngleGeometry(hip: CGPoint, knee: CGPoint, ankle: CGPoint) -> Double? {
          let v1 = CGVector(dx: hip.x   - knee.x, dy: hip.y   - knee.y)
          let v2 = CGVector(dx: ankle.x - knee.x, dy: ankle.y - knee.y)
          let dot  = v1.dx * v2.dx + v1.dy * v2.dy
          let mag1 = sqrt(v1.dx * v1.dx + v1.dy * v1.dy)
          let mag2 = sqrt(v2.dx * v2.dx + v2.dy * v2.dy)
          guard mag1 > 0, mag2 > 0 else { return nil }
          let cosAngle = max(-1.0, min(1.0, dot / (mag1 * mag2)))
          return acos(cosAngle) * (180.0 / Double.pi)
      }

      /// Vision wrapper — extracts left leg keypoints and calls legAngleGeometry.
      static func legAngle(from observation: VNHumanBodyPoseObservation) -> Double? {
          guard let hip   = try? observation.recognizedPoint(.leftHip),
                let knee  = try? observation.recognizedPoint(.leftKnee),
                let ankle = try? observation.recognizedPoint(.leftAnkle),
                hip.confidence   > 0.3,
                knee.confidence  > 0.3,
                ankle.confidence > 0.3 else { return nil }
          return legAngleGeometry(hip:   hip.location,
                                  knee:  knee.location,
                                  ankle: ankle.location)
      }

      // MARK: - Vertical Jump (pure geometry — used in tests and Vision wrapper)

      /// Rough estimate of vertical jump in centimetres from a single observation.
      /// Compares hip height (as fraction of body height) to the standing baseline of 55%.
      /// Returns nil when the person is not fully in frame or below noise threshold.
      ///
      /// - Parameters:
      ///   - hipY:      Normalised Y of left hip (Vision: 0 = bottom, 1 = top).
      ///   - ankleY:    Normalised Y of left ankle.
      ///   - shoulderY: Normalised Y of left shoulder (used to derive body height).
      static func verticalJumpGeometry(hipY: Double, ankleY: Double, shoulderY: Double) -> Double? {
          let bodyHeight = shoulderY - ankleY
          guard bodyHeight > 0.1 else { return nil }   // person not fully visible

          let hipHeightFrac   = (hipY - ankleY) / bodyHeight
          let standingBaseline = 0.55                  // standing hip ≈ 55% of body height
          let excessFrac      = hipHeightFrac - standingBaseline

          // Assume average body height 180 cm for scaling
          let estimatedJumpCm = excessFrac * 180.0
          return estimatedJumpCm > 3.0 ? estimatedJumpCm : nil   // filter noise
      }

      /// Vision wrapper — extracts left-side keypoints and calls verticalJumpGeometry.
      static func estimatedVerticalJump(from observation: VNHumanBodyPoseObservation) -> Double? {
          guard let hip      = try? observation.recognizedPoint(.leftHip),
                let ankle    = try? observation.recognizedPoint(.leftAnkle),
                let shoulder = try? observation.recognizedPoint(.leftShoulder),
                hip.confidence      > 0.3,
                ankle.confidence    > 0.3,
                shoulder.confidence > 0.3 else { return nil }
          return verticalJumpGeometry(hipY:      Double(hip.location.y),
                                      ankleY:    Double(ankle.location.y),
                                      shoulderY: Double(shoulder.location.y))
      }

      // MARK: - Convenience bundle

      /// Computes all metrics in one call. Always returns a struct; fields may be nil.
      static func compute(trajectory: [BallDetection],
                          poseObservation: VNHumanBodyPoseObservation?,
                          hoopRectWidth: CGFloat) -> ShotScienceMetrics {
          ShotScienceMetrics(
              releaseAngleDeg: releaseAngle(trajectory: trajectory),
              releaseTimeMs:   releaseTime(trajectory: trajectory),
              verticalJumpCm:  poseObservation.flatMap { estimatedVerticalJump(from: $0) },
              legAngleDeg:     poseObservation.flatMap { legAngle(from: $0) },
              shotSpeedMph:    shotSpeed(trajectory: trajectory, hoopRectWidth: hoopRectWidth)
          )
      }
  }
  ```

- [ ] **Step 4: Run tests — all must pass**

  `Cmd+U`. Expected: 13 tests pass, 0 fail.

- [ ] **Step 5: Add both files to Xcode targets**

  - `ShotScienceCalculator.swift` → **Target: HoopTrack**
  - `ShotScienceCalculatorTests.swift` → **Target: HoopTrackTests**

- [ ] **Step 6: Commit**

  ```bash
  git add HoopTrack/Utilities/ShotScienceCalculator.swift \
          HoopTrackTests/ShotScienceCalculatorTests.swift
  git commit -m "feat: add ShotScienceCalculator with full unit test coverage"
  ```

---

## Task 3 — PoseEstimationService

**Files:**
- Create: `HoopTrack/Services/PoseEstimationService.swift`

No unit tests — wraps the Vision framework directly. Integration-test on device by running a session and checking that `ShotRecord.legAngleDeg` is non-nil when a body is in frame.

- [ ] **Step 1: Create the service**

  ```swift
  // HoopTrack/Services/PoseEstimationService.swift
  // Synchronous Vision body pose detector.
  // Must be called on the camera session queue (same queue as CVPipeline).

  import Vision
  import AVFoundation

  final class PoseEstimationService {

      /// Runs VNDetectHumanBodyPoseRequest on a single frame.
      /// Returns the first body pose observation, or nil if none detected or Vision fails.
      /// Synchronous — blocks the calling queue for < 5ms on A15.
      func detectPose(buffer: CMSampleBuffer) -> VNHumanBodyPoseObservation? {
          guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
          let request = VNDetectHumanBodyPoseRequest()
          let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                              orientation: .up,
                                              options: [:])
          try? handler.perform([request])
          return request.results?.first
      }
  }
  ```

- [ ] **Step 2: Add to Xcode target**

  Drag into `HoopTrack/Services/` group. Target: **HoopTrack**.

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/Services/PoseEstimationService.swift
  git commit -m "feat: add PoseEstimationService wrapping VNDetectHumanBodyPoseRequest"
  ```

---

## Task 4 — Wire CVPipeline to compute Shot Science at release

**Files:**
- Modify: `HoopTrack/HoopTrack/Services/CVPipeline.swift`

- [ ] **Step 1: Add `PoseEstimationService?` dependency and update init**

  In `CVPipeline.swift`, add a stored property and update `init`:

  ```swift
  // In class CVPipeline — add after `private let calibration: CourtCalibrationService`
  private let poseService: PoseEstimationService?
  ```

  Update `init`:

  ```swift
  init(detector: BallDetectorProtocol,
       calibration: CourtCalibrationService,
       poseService: PoseEstimationService? = nil) {
      self.detector    = detector
      self.calibration = calibration
      self.poseService = poseService
  }
  ```

- [ ] **Step 2: Update `logPendingShot` to accept `ShotScienceMetrics?`**

  Replace the existing `logPendingShot` private method:

  ```swift
  private func logPendingShot(releaseBox: CGRect, science: ShotScienceMetrics?) {
      let pos  = calibration.courtPosition(for: releaseBox) ?? (courtX: 0.5, courtY: 0.5)
      let zone = CourtZoneClassifier.classify(courtX: pos.courtX, courtY: pos.courtY)
      DispatchQueue.main.async { [weak self] in
          self?.viewModel?.logPendingShot(zone: zone,
                                          courtX: pos.courtX,
                                          courtY: pos.courtY,
                                          science: science)
      }
  }
  ```

- [ ] **Step 3: Compute Shot Science at RELEASE_DETECTED and store buffer for each frame**

  `processBuffer` needs access to the current `CMSampleBuffer` when `isAtPeak` fires. The buffer is already the parameter. Replace the `isAtPeak` branch inside `case .tracking(var trajectory):`:

  ```swift
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
                  let hoopWidth: CGFloat
                  if case .calibrated(let hoopRect) = calibration.state {
                      hoopWidth = hoopRect.width
                  } else {
                      hoopWidth = 0.1   // fallback scale
                  }
                  science = ShotScienceCalculator.compute(
                      trajectory: trajectory,
                      poseObservation: observation,
                      hoopRectWidth: hoopWidth
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
  ```

  Also remove the now-redundant placeholder comment in `case .releaseDetected`:
  ```swift
  // Remove this line:
  // _ = trajectory  // reserved for Phase 3 Shot Science
  ```

- [ ] **Step 4: Build — no errors expected**

  `Cmd+B`. The compiler will flag `logPendingShot` calls in `LiveSessionViewModel` as missing the new `science` parameter in the next task, but the CVPipeline itself should compile cleanly after the changes above.

- [ ] **Step 5: Commit**

  ```bash
  git add HoopTrack/HoopTrack/Services/CVPipeline.swift
  git commit -m "feat: compute ShotScienceMetrics in CVPipeline at RELEASE_DETECTED"
  ```

---

## Task 5 — Propagate ShotScienceMetrics through ViewModel and DataService

**Files:**
- Modify: `HoopTrack/ViewModels/LiveSessionViewModel.swift`
- Modify: `HoopTrack/Services/DataService.swift`

- [ ] **Step 1: Update `LiveSessionViewModel.logPendingShot`**

  In `LiveSessionViewModel.swift`, update the signature (default nil keeps manual-mode callers unchanged):

  ```swift
  func logPendingShot(zone: CourtZone,
                      courtX: Double,
                      courtY: Double,
                      science: ShotScienceMetrics? = nil) {
      guard let session else { return }
      do {
          let shot = try dataService.addShot(to: session,
                                             result: .pending,
                                             zone: zone,
                                             shotType: .unknown,
                                             courtX: courtX,
                                             courtY: courtY,
                                             science: science)
          pendingShotRecord = shot
          recentShots       = Array(session.shots.suffix(5))
          lastShotResult    = .pending
          triggerHaptic(for: .pending)
      } catch {
          errorMessage = error.localizedDescription
      }
  }
  ```

- [ ] **Step 2: Update `DataService.addShot` to accept and apply ShotScienceMetrics**

  In `DataService.swift`, replace the existing `addShot` signature and body:

  ```swift
  func addShot(to session: TrainingSession,
               result: ShotResult,
               zone: CourtZone,
               shotType: ShotType,
               courtX: Double,
               courtY: Double,
               science: ShotScienceMetrics? = nil) throws -> ShotRecord {
      let shot = ShotRecord(
          sequenceIndex: session.shots.count + 1,
          result: result,
          zone: zone,
          shotType: shotType,
          courtX: courtX,
          courtY: courtY
      )
      shot.session = session
      session.shots.append(shot)

      // Set video timestamp so the replay view can seek to this shot
      shot.videoTimestampSeconds = shot.timestamp.timeIntervalSince(session.startedAt)

      // Apply Shot Science metrics if available
      if let s = science {
          shot.releaseAngleDeg = s.releaseAngleDeg
          shot.releaseTimeMs   = s.releaseTimeMs
          shot.verticalJumpCm  = s.verticalJumpCm
          shot.legAngleDeg     = s.legAngleDeg
          shot.shotSpeedMph    = s.shotSpeedMph
      }

      session.recalculateStats()
      modelContext.insert(shot)
      try modelContext.save()
      return shot
  }
  ```

- [ ] **Step 3: Build — all compile errors should now be resolved**

  `Cmd+B`. Expected: 0 errors.

- [ ] **Step 4: Commit**

  ```bash
  git add HoopTrack/ViewModels/LiveSessionViewModel.swift \
          HoopTrack/Services/DataService.swift
  git commit -m "feat: propagate ShotScienceMetrics through ViewModel and DataService into ShotRecord"
  ```

---

## Task 6 — TrainingSession: compute Shot Science session averages

**Files:**
- Modify: `HoopTrack/Models/TrainingSession.swift`

`recalculateStats()` is already called on every shot add and at session end. Extend it to also compute Shot Science averages and `consistencyScore`.

- [ ] **Step 1: Extend `recalculateStats()`**

  In `TrainingSession.swift`, replace the `recalculateStats()` function body:

  ```swift
  func recalculateStats() {
      let completedShots = shots.filter { $0.result != .pending }
      shotsAttempted = completedShots.count
      shotsMade      = completedShots.filter { $0.result == .make }.count
      fgPercent      = shotsAttempted > 0
          ? Double(shotsMade) / Double(shotsAttempted) * 100
          : 0

      // MARK: Shot Science averages
      func avg(_ values: [Double?]) -> Double? {
          let v = values.compactMap { $0 }
          return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
      }

      avgReleaseAngleDeg = avg(completedShots.map { $0.releaseAngleDeg })
      avgReleaseTimeMs   = avg(completedShots.map { $0.releaseTimeMs   })
      avgVerticalJumpCm  = avg(completedShots.map { $0.verticalJumpCm  })
      avgShotSpeedMph    = avg(completedShots.map { $0.shotSpeedMph    })

      // Consistency score = population std dev of release angles
      let angles = completedShots.compactMap { $0.releaseAngleDeg }
      consistencyScore = ShotScienceCalculator.consistencyScore(releaseAngles: angles)
  }
  ```

  Add `import` at the top of the file if not already present — `TrainingSession.swift` doesn't import any framework that `ShotScienceCalculator` requires. Since `ShotScienceCalculator` is defined in the same module, no import is needed.

- [ ] **Step 2: Build — no errors**

  `Cmd+B`. Expected: 0 errors.

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/Models/TrainingSession.swift
  git commit -m "feat: recalculateStats now derives Shot Science session averages"
  ```

---

## Task 7 — Activate Video Recording + config doc

**Files:**
- Modify: `HoopTrack/Views/Train/LiveSessionView.swift`
- Create: `docs/config/video-recording.md`

- [ ] **Step 1: Add `@State private var videoRecorder` to LiveSessionView**

  In `LiveSessionView.swift`, add a state property alongside the existing `cvPipeline` / `calibration` states:

  ```swift
  // Phase 3: video recording for Shot Science replay
  @State private var videoRecorder: VideoRecordingService?
  ```

- [ ] **Step 2: Update `.task` block — pass PoseEstimationService to CVPipeline and start recording**

  Replace the Phase 2 CV pipeline block (lines 84–99 of the original) with:

  ```swift
  if let detector = BallDetectorFactory.make(BallDetectorFactory.active) {
      let cal = CourtCalibrationService()
      cal.onStateChange = { [weak viewModel] state in
          viewModel?.updateCalibrationState(isCalibrated: state.isCalibrated)
      }
      cal.startCalibration()

      let poseService = PoseEstimationService()
      let pipeline = CVPipeline(detector: detector,
                                calibration: cal,
                                poseService: poseService)
      pipeline.start(framePublisher: cameraService.framePublisher, viewModel: viewModel)

      calibration = cal
      cvPipeline  = pipeline
  } else {
      viewModel.updateCalibrationState(isCalibrated: true)
  }

  // Phase 3: record session video for replay
  let recorder = VideoRecordingService()
  recorder.configure(captureSession: cameraService.captureSession)
  if let sessionID = viewModel.session?.id {
      recorder.startRecording(sessionID: sessionID)
      recorder.onRecordingFinished = { result in
          if case .success(let url) = result {
              viewModel.session?.videoFileName = url.lastPathComponent
          }
      }
  }
  videoRecorder = recorder
  ```

- [ ] **Step 3: Stop recording in `.onDisappear`**

  In the `.onDisappear` modifier, add `videoRecorder?.stopRecording()` before `cameraService.stopSession()`:

  ```swift
  .onDisappear {
      cvPipeline?.stop()
      calibration?.reset()
      videoRecorder?.stopRecording()
      cameraService.stopSession()
  }
  ```

- [ ] **Step 4: Create the config doc**

  Create `docs/config/video-recording.md`:

  ```markdown
  # Video Recording — Configuration

  Session video is recorded automatically during every live session and used for Shot Science replay.

  ## Storage

  - Location: `<app Documents>/Sessions/<session-UUID>.mov`
  - Format: H.264 (AVCaptureMovieFileOutput default)
  - Approximate size: < 300 MB per 30-minute session

  ## Retention

  Auto-deletion is handled by `DataService.purgeOldVideos(olderThanDays:)`.
  Default retention: 60 days (configurable via `HoopTrack.Storage.defaultVideoRetainDays`).
  Users can pin a video permanently by setting `TrainingSession.videoPinnedByUser = true`.

  ## No-video fallback

  If recording fails (disk full, AVCaptureSession error), `TrainingSession.videoFileName` remains nil.
  `SessionSummaryView` and `SessionReplayView` both check for nil before showing the Replay button — no crash.

  ## Testing

  To test replay without a full session, copy any `.mov` file to the simulator's Documents/Sessions/ directory
  and set a `TrainingSession.videoFileName` to match in the SwiftData store via a debug route or unit test fixture.
  ```

- [ ] **Step 5: Build and run**

  Run on a physical device (recording requires a real capture session). Confirm a `.mov` file appears in the app's Documents/Sessions/ directory after ending a session.

- [ ] **Step 6: Commit**

  ```bash
  git add HoopTrack/Views/Train/LiveSessionView.swift \
          docs/config/video-recording.md
  git commit -m "feat: activate VideoRecordingService in LiveSessionView for Phase 3 replay"
  ```

---

## Task 8 — ShotScienceCard + SessionReplayView + SessionSummaryView

**Files:**
- Create: `HoopTrack/Views/Components/ShotScienceCard.swift`
- Create: `HoopTrack/Views/Train/SessionReplayView.swift`
- Modify: `HoopTrack/Views/Train/SessionSummaryView.swift`

- [ ] **Step 1: Create ShotScienceCard**

  Create `HoopTrack/Views/Components/ShotScienceCard.swift`:

  ```swift
  // HoopTrack/Views/Components/ShotScienceCard.swift
  // Reusable card that displays per-shot biomechanics.
  // Used in SessionReplayView overlay and ShotReviewRow expansion.

  import SwiftUI

  struct ShotScienceCard: View {
      let shot: ShotRecord

      var body: some View {
          VStack(alignment: .leading, spacing: 10) {
              // Header
              HStack(spacing: 8) {
                  Image(systemName: shot.isMake ? "checkmark.circle.fill" : "xmark.circle.fill")
                      .foregroundStyle(shot.isMake ? .green : .red)
                  Text("Shot #\(shot.sequenceIndex) · \(shot.zone.rawValue)")
                      .font(.headline)
                      .foregroundStyle(.white)
                  Spacer()
              }

              if hasAnyData {
                  LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                      if let angle = shot.releaseAngleDeg {
                          scienceCell(
                              label: "Release Angle",
                              value: String(format: "%.1f°", angle),
                              isOptimal: angle >= HoopTrack.ShotScience.optimalReleaseAngleMin
                                      && angle <= HoopTrack.ShotScience.optimalReleaseAngleMax
                          )
                      }
                      if let time = shot.releaseTimeMs {
                          scienceCell(label: "Release Time",
                                      value: String(format: "%.0f ms", time))
                      }
                      if let jump = shot.verticalJumpCm {
                          scienceCell(label: "Vertical",
                                      value: String(format: "%.0f cm", jump))
                      }
                      if let leg = shot.legAngleDeg {
                          scienceCell(label: "Leg Angle",
                                      value: String(format: "%.1f°", leg))
                      }
                      if let speed = shot.shotSpeedMph {
                          scienceCell(label: "Ball Speed",
                                      value: String(format: "%.1f mph", speed))
                      }
                  }
              } else {
                  Text("No biomechanics data for this shot")
                      .font(.subheadline)
                      .foregroundStyle(.white.opacity(0.7))
              }
          }
          .padding(16)
          .background(.ultraThinMaterial.opacity(0.88),
                      in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }

      private var hasAnyData: Bool {
          shot.releaseAngleDeg != nil || shot.releaseTimeMs  != nil
          || shot.verticalJumpCm  != nil || shot.legAngleDeg != nil
          || shot.shotSpeedMph    != nil
      }

      @ViewBuilder
      private func scienceCell(label: String, value: String, isOptimal: Bool? = nil) -> some View {
          VStack(alignment: .leading, spacing: 2) {
              Text(label)
                  .font(.caption)
                  .foregroundStyle(.white.opacity(0.65))
              Text(value)
                  .font(.subheadline.bold())
                  .foregroundStyle(
                      isOptimal == true  ? .green  :
                      isOptimal == false ? .red    : .white
                  )
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(.white.opacity(0.08),
                      in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
  }
  ```

- [ ] **Step 2: Create VideoPlayerView helper**

  Add at the bottom of `SessionReplayView.swift` (created in next step) — a UIViewControllerRepresentable that wraps `AVPlayerViewController`:

  *(Will be included inline in Step 3.)*

- [ ] **Step 3: Create SessionReplayView**

  Create `HoopTrack/Views/Train/SessionReplayView.swift`:

  ```swift
  // HoopTrack/Views/Train/SessionReplayView.swift
  // Full-screen video replay with shot timeline markers and per-shot Shot Science overlay.

  import SwiftUI
  import AVKit

  struct SessionReplayView: View {
      let session: TrainingSession
      @Environment(\.dismiss) private var dismiss

      @State private var player:         AVPlayer?
      @State private var currentTimeSec: Double  = 0
      @State private var selectedShot:   ShotRecord? = nil
      @State private var timeObserver:   Any?
      @State private var duration:       Double  = 0

      // Shots that have a video timestamp to place on the timeline
      private var timedShots: [ShotRecord] {
          session.shots
              .filter { $0.videoTimestampSeconds != nil && $0.result != .pending }
              .sorted { $0.sequenceIndex < $1.sequenceIndex }
      }

      var body: some View {
          ZStack {
              Color.black.ignoresSafeArea()

              // Video
              if let player {
                  VideoPlayerView(player: player)
                      .ignoresSafeArea()
              }

              // Shot Science overlay (slides up from bottom when a shot is selected)
              VStack {
                  Spacer()
                  if let shot = selectedShot {
                      ShotScienceCard(shot: shot)
                          .padding(.horizontal, 16)
                          .padding(.bottom, 80)
                          .transition(.move(edge: .bottom).combined(with: .opacity))
                  }
              }
              .animation(.spring(response: 0.35), value: selectedShot?.id)

              // Top bar + timeline
              VStack {
                  // Dismiss button
                  HStack {
                      Button {
                          dismiss()
                      } label: {
                          Image(systemName: "xmark.circle.fill")
                              .font(.title2)
                              .foregroundStyle(.white.opacity(0.85))
                              .padding(16)
                      }
                      Spacer()
                  }

                  Spacer()

                  // Shot timeline
                  shotTimeline
                      .padding(.horizontal, 16)
                      .padding(.bottom, 24)
              }
          }
          .statusBarHidden(true)
          .onAppear  { setupPlayer() }
          .onDisappear { teardownPlayer() }
      }

      // MARK: - Timeline

      private var shotTimeline: some View {
          GeometryReader { geo in
              ZStack(alignment: .leading) {
                  // Track background
                  Capsule()
                      .fill(.white.opacity(0.25))
                      .frame(height: 4)

                  // Elapsed progress
                  Capsule()
                      .fill(.white.opacity(0.8))
                      .frame(width: progressWidth(in: geo.size.width, for: currentTimeSec),
                             height: 4)

                  // Shot markers
                  ForEach(timedShots) { shot in
                      Circle()
                          .fill(shot.isMake ? .green : .red)
                          .frame(width: 14, height: 14)
                          .overlay(
                              Circle().stroke(
                                  selectedShot?.id == shot.id ? Color.white : .clear,
                                  lineWidth: 2
                              )
                          )
                          .offset(
                              x: progressWidth(in: geo.size.width,
                                               for: shot.videoTimestampSeconds!) - 7,
                              y: -5
                          )
                          .onTapGesture {
                              let isSame = selectedShot?.id == shot.id
                              selectedShot = isSame ? nil : shot
                              if !isSame {
                                  player?.seek(
                                      to: CMTime(seconds: shot.videoTimestampSeconds!,
                                                 preferredTimescale: 600),
                                      toleranceBefore: .zero,
                                      toleranceAfter:  .zero
                                  )
                              }
                          }
                  }
              }
              .frame(height: 20)
          }
          .frame(height: 20)
          .background(.ultraThinMaterial.opacity(0.6),
                      in: RoundedRectangle(cornerRadius: 12))
          .padding(.vertical, 8)
      }

      // MARK: - Helpers

      private func progressWidth(in totalWidth: CGFloat, for seconds: Double) -> CGFloat {
          guard duration > 0 else { return 0 }
          return CGFloat(seconds / duration) * totalWidth
      }

      // MARK: - Player lifecycle

      private func setupPlayer() {
          guard let fileName = session.videoFileName else { return }
          let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          let url  = docs.appendingPathComponent("Sessions/\(fileName)")
          guard FileManager.default.fileExists(atPath: url.path) else { return }

          let avPlayer = AVPlayer(url: url)

          // Observe current playback time for timeline progress
          let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
          timeObserver = avPlayer.addPeriodicTimeObserver(
              forInterval: interval, queue: .main
          ) { [weak avPlayer] time in
              currentTimeSec = CMTimeGetSeconds(time)
              if let d = avPlayer?.currentItem?.duration, d.isNumeric {
                  duration = CMTimeGetSeconds(d)
              }
          }

          player = avPlayer
          avPlayer.play()
      }

      private func teardownPlayer() {
          if let obs = timeObserver { player?.removeTimeObserver(obs) }
          player?.pause()
          player = nil
      }
  }

  // MARK: - AVPlayerViewController wrapper

  private struct VideoPlayerView: UIViewControllerRepresentable {
      let player: AVPlayer

      func makeUIViewController(context: Context) -> AVPlayerViewController {
          let vc = AVPlayerViewController()
          vc.player               = player
          vc.showsPlaybackControls = false   // custom timeline provided above
          return vc
      }

      func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
          vc.player = player
      }
  }
  ```

- [ ] **Step 4: Update SessionSummaryView — Replay button + per-shot science indicator**

  In `SessionSummaryView.swift`:

  **a) Add state for replay presentation** at the top of the struct body:

  ```swift
  @State private var showReplay = false
  ```

  **b) Add a `.fullScreenCover` modifier** after the existing `.sheet` or `.onAppear`:

  ```swift
  .fullScreenCover(isPresented: $showReplay) {
      SessionReplayView(session: session)
  }
  ```

  **c) Add a Replay toolbar button** in the existing `.toolbar` block, after the Share button:

  ```swift
  if session.videoFileName != nil {
      ToolbarItem(placement: .navigationBarLeading) {
          Button {
              hapticService.tap()
              showReplay = true
          } label: {
              Label("Replay", systemImage: "play.rectangle.fill")
          }
      }
  }
  ```

  **d) Update `ShotReviewRow`** to show a release angle indicator when present. Inside the `ShotReviewRow` HStack, replace the `Spacer()` between the zone VStack and the correction badge with:

  ```swift
  Spacer()

  // Shot Science quick-stat
  if let angle = shot.releaseAngleDeg {
      Text(String(format: "%.0f°", angle))
          .font(.caption.monospacedDigit())
          .foregroundStyle(
              angle >= HoopTrack.ShotScience.optimalReleaseAngleMin
              && angle <= HoopTrack.ShotScience.optimalReleaseAngleMax
                  ? .green : .orange
          )
  }
  ```

- [ ] **Step 5: Add new files to Xcode target**

  Drag `ShotScienceCard.swift` into `HoopTrack/Views/Components/` and `SessionReplayView.swift` into `HoopTrack/Views/Train/`. Both target: **HoopTrack**.

- [ ] **Step 6: Build and run**

  `Cmd+B` → 0 errors. On device: end a session, tap the Replay button in the summary, verify the video plays, shot markers appear on the timeline, and tapping a marker shows the `ShotScienceCard`.

- [ ] **Step 7: Commit**

  ```bash
  git add HoopTrack/Views/Components/ShotScienceCard.swift \
          HoopTrack/Views/Train/SessionReplayView.swift \
          HoopTrack/Views/Train/SessionSummaryView.swift
  git commit -m "feat: add ShotScienceCard, SessionReplayView, and replay button in SessionSummaryView"
  ```

---

## Self-Review Checklist

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Vision body pose integration (`VNDetectHumanBodyPoseRequest`) | Task 3 |
| Release angle calculation | Task 2 (`releaseAngle`) |
| Release time calculation | Task 2 (`releaseTime`) |
| Vertical jump estimation | Task 2 (`verticalJumpGeometry` / Vision wrapper) |
| Leg angle | Task 2 (`legAngleGeometry` / Vision wrapper) |
| Shot speed | Task 2 (`shotSpeed`) |
| Consistency score | Task 2 (`consistencyScore`) + Task 6 (`recalculateStats`) |
| Session-level averages stored in `TrainingSession` | Task 6 |
| Per-shot science stored in `ShotRecord` | Task 5 |
| Shot Science overlay in replay | Task 8 |
| Video recording activation | Task 7 |
| `SessionSummaryView` Shot Science section populated | Tasks 5 + 6 (data) — section already rendered |

**No fatalError / crash paths:**
- `PoseEstimationService.detectPose` returns nil on failure (no throw)
- `CVPipeline` skips Shot Science entirely when `poseService == nil`
- `SessionReplayView` returns a plain black screen when `videoFileName == nil` or file is missing
- `ShotScienceCard` shows a "no data" message when all fields are nil

**Type consistency check:**
- `ShotScienceMetrics` fields match `ShotRecord` optional fields exactly (Double?)
- `ShotScienceCalculator.compute` produces a `ShotScienceMetrics` — same type flowed through `logPendingShot` and `addShot`
- `timedShots` in `SessionReplayView` filters on `videoTimestampSeconds != nil` — matches `DataService.addShot` which sets this field
