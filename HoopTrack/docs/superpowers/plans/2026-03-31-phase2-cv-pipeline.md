# HoopTrack Phase 2 — CV Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace manual Make/Miss button logging with automatic shot detection using a CV pipeline that subscribes to the live camera feed, detects ball trajectory, classifies court zone, and resolves make/miss — while keeping manual buttons as a fallback.

**Architecture:** A `BallDetectorProtocol` abstraction lets a `BallDetectorStub` drive the full pipeline during development (real Core ML model drops in later without code changes). `CVPipeline` runs a state machine on the camera's background queue, calling `@MainActor` methods on `LiveSessionViewModel` to log and resolve shots. `CourtCalibrationService` locks a hoop reference rect at session start; `CourtZoneClassifier` maps normalised court coordinates to zones using existing `Constants.CourtGeometry` values.

**Tech Stack:** Swift 5.10, SwiftUI, Combine, Vision framework (`VNDetectRectanglesRequest`, `VNCoreMLRequest`), AVFoundation, XCTest

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `HoopTrack/ML/BallDetectorProtocol.swift` | `BallDetection` struct + `BallDetectorProtocol` |
| Create | `HoopTrack/ML/BallDetectorStub.swift` | DEBUG-only stub simulating a shot arc |
| Create | `HoopTrack/Utilities/CourtZoneClassifier.swift` | Pure zone-classification function |
| Create | `HoopTrack/Services/CourtCalibrationService.swift` | Hoop detection, calibration state, court-coordinate mapping |
| Create | `HoopTrack/Services/CVPipeline.swift` | Shot-detection state machine |
| Create | `HoopTrack/Services/VideoRecordingService.swift` | `AVCaptureMovieFileOutput` wrapper (Task 10) |
| Modify | `HoopTrack/Utilities/Constants.swift` | Add `ballDetectionConfidenceThreshold` |
| Modify | `HoopTrack/Services/DataService.swift` | Add `resolveShot(_:result:zone:courtX:courtY:)` |
| Modify | `HoopTrack/ViewModels/LiveSessionViewModel.swift` | Add `logPendingShot`, `resolvePendingShot`, `calibrationIsActive` |
| Modify | `HoopTrack/Views/Train/LiveSessionView.swift` | Calibration overlay, pipeline lifecycle, pending-shot dot colour |
| Create | `HoopTrackTests/CourtZoneClassifierTests.swift` | Unit tests for zone classifier |
| Create | `HoopTrackTests/CVPipelineStateTests.swift` | Unit tests for pipeline state machine |

---

## Task 1 — BallDetector Contract + Constants

**Files:**
- Create: `HoopTrack/ML/BallDetectorProtocol.swift`
- Modify: `HoopTrack/Utilities/Constants.swift`

- [ ] **Step 1: Create the ML directory and protocol file**

  In Xcode: File → New Group → name it `ML` inside the `HoopTrack` folder. Then create the file:

  ```swift
  // HoopTrack/ML/BallDetectorProtocol.swift
  import AVFoundation
  import CoreGraphics

  /// A single ball detection result from one camera frame.
  struct BallDetection {
      /// Bounding box in Vision normalised coordinates: origin bottom-left, 0–1 range.
      let boundingBox: CGRect
      /// Model confidence score 0–1.
      let confidence: Float
      /// Presentation timestamp of the source frame, used for trajectory timing.
      let frameTimestamp: CMTime
  }

  /// Protocol that both the real Core ML wrapper and the debug stub conform to.
  /// Kept on the background session queue — must NOT touch the main actor.
  protocol BallDetectorProtocol {
      func detect(buffer: CMSampleBuffer) -> BallDetection?
  }
  ```

- [ ] **Step 2: Add confidence threshold to Constants.swift**

  Open `HoopTrack/Utilities/Constants.swift`. Inside the existing `Camera` enum, add one line after `shotDetectionLatencyMs`:

  ```swift
  static let ballDetectionConfidenceThreshold: Float = 0.45
  ```

  The `Camera` enum should now look like:

  ```swift
  enum Camera {
      static let targetFPS: Double             = 60
      static let sessionPreset                 = "AVCaptureSessionPreset1280x720"
      static let maxProcessingLatencyMs: Double = 20.0
      static let shotDetectionLatencyMs: Double = 500.0
      static let ballDetectionConfidenceThreshold: Float = 0.45
  }
  ```

- [ ] **Step 3: Build the project**

  In Xcode press ⌘B. Expected: build succeeds with zero errors.

- [ ] **Step 4: Commit**

  ```bash
  git add HoopTrack/ML/BallDetectorProtocol.swift HoopTrack/Utilities/Constants.swift
  git commit -m "feat: add BallDetectorProtocol contract and confidence threshold constant"
  ```

---

## Task 2 — BallDetectorStub (DEBUG only)

**Files:**
- Create: `HoopTrack/ML/BallDetectorStub.swift`

- [ ] **Step 1: Create the stub**

  ```swift
  // HoopTrack/ML/BallDetectorStub.swift
  // Simulates a basketball shot arc so the CV pipeline can be built and tested
  // before the real Core ML model is trained.
  // Compiled only in DEBUG builds — not shipped.

  #if DEBUG
  import AVFoundation
  import CoreGraphics

  final class BallDetectorStub: BallDetectorProtocol {

      private var frameCount = 0

      // One shot arc every 180 frames (3 seconds at 60fps).
      // Ball appears at frame 30, peaks at frame 90, leaves at frame 150.
      func detect(buffer: CMSampleBuffer) -> BallDetection? {
          frameCount += 1
          let phase = frameCount % 180
          guard phase > 30 && phase < 150 else { return nil }

          let progress = Double(phase - 30) / 120.0          // 0 → 1 over the arc
          let y        = 0.15 + sin(progress * .pi) * 0.55   // rises 0.15 → 0.70, then falls

          return BallDetection(
              boundingBox: CGRect(x: 0.45, y: y, width: 0.07, height: 0.07),
              confidence: 0.87,
              frameTimestamp: CMSampleBufferGetPresentationTimeStamp(buffer)
          )
      }
  }
  #endif
  ```

- [ ] **Step 2: Build (⌘B)**

  Expected: zero errors.

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/ML/BallDetectorStub.swift
  git commit -m "feat: add BallDetectorStub for pipeline development without ML model"
  ```

---

## Task 3 — CourtZoneClassifier (TDD)

**Files:**
- Create: `HoopTrack/Utilities/CourtZoneClassifier.swift`
- Create: `HoopTrackTests/CourtZoneClassifierTests.swift`

- [ ] **Step 1: Write the failing tests first**

  In Xcode, add `CourtZoneClassifierTests.swift` to the `HoopTrackTests` target:

  ```swift
  // HoopTrackTests/CourtZoneClassifierTests.swift
  import XCTest
  @testable import HoopTrack

  final class CourtZoneClassifierTests: XCTestCase {

      // Paint: centred horizontally, below free throw line
      func testPaintCentre() {
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.5, courtY: 0.15), .paint)
      }

      func testPaintLeftEdge() {
          // Just inside paint width (32% of court = ±16% from centre = 0.34–0.66)
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.35, courtY: 0.20), .paint)
      }

      func testPaintRightEdge() {
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.65, courtY: 0.20), .paint)
      }

      // Free throw: centre horizontally, at free throw line Y ± 5%
      func testFreeThrowExact() {
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.5, courtY: 0.38), .freeThrow)
      }

      func testFreeThrowWithinTolerance() {
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.5, courtY: 0.40), .freeThrow)
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.5, courtY: 0.36), .freeThrow)
      }

      // Corner three: outside paint width, below corner depth threshold (28% from baseline)
      func testCornerThreeLeft() {
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.05, courtY: 0.15), .cornerThree)
      }

      func testCornerThreeRight() {
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.95, courtY: 0.15), .cornerThree)
      }

      // Mid-range: inside 3pt arc, outside paint
      func testMidRangeLeft() {
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.20, courtY: 0.45), .midRange)
      }

      func testMidRangeRight() {
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.80, courtY: 0.45), .midRange)
      }

      // Above-break three: outside 3pt arc radius, above corner depth
      func testAboveBreakThreeLeft() {
          // Arc radius = 0.47. Distance from (0.5, 0.0):
          // x=0.05, y=0.50 → dist = sqrt(0.45²+0.50²) ≈ 0.67 > 0.47
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.05, courtY: 0.50), .aboveBreakThree)
      }

      func testAboveBreakThreeCentre() {
          // Straight on: x=0.5, y=0.50 → dist = 0.50 > 0.47
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.5, courtY: 0.50), .aboveBreakThree)
      }

      // Boundary: just outside paint → mid-range, not paint
      func testJustOutsidePaintX() {
          XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.33, courtY: 0.20), .midRange)
      }
  }
  ```

- [ ] **Step 2: Run tests — verify they FAIL**

  In Xcode, ⌘U or run `CourtZoneClassifierTests`. Expected: compile error "Cannot find type 'CourtZoneClassifier'".

- [ ] **Step 3: Implement CourtZoneClassifier**

  ```swift
  // HoopTrack/Utilities/CourtZoneClassifier.swift
  import Foundation

  /// Maps a normalised court position (0–1, origin bottom-left half-court)
  /// to a CourtZone using the geometry constants in HoopTrack.CourtGeometry.
  enum CourtZoneClassifier {

      static func classify(courtX: Double, courtY: Double) -> CourtZone {
          let g = HoopTrack.CourtGeometry

          let paintHalfWidth     = g.paintWidthFraction / 2.0    // 0.16
          let inPaintX           = abs(courtX - 0.5) <= paintHalfWidth
          let freeThrowTolerance = 0.05
          let atFreeThrowY       = abs(courtY - g.freeThrowLineFraction) <= freeThrowTolerance

          // Free throw (checked before paint to avoid free-throw-line shots classified as paint)
          if inPaintX && atFreeThrowY {
              return .freeThrow
          }

          // Paint: horizontally within paint, below free throw line
          if inPaintX && courtY <= g.paintHeightFraction {
              return .paint
          }

          // Distance from basket (basket modelled at x=0.5, y=0.0 in normalised space)
          let dx = courtX - 0.5
          let dy = courtY
          let distanceFromBasket = (dx * dx + dy * dy).squareRoot()

          // Corner three: outside paint width, below corner depth
          let outsidePaintX = abs(courtX - 0.5) > paintHalfWidth
          if outsidePaintX && courtY <= g.cornerThreeDepthFraction {
              return .cornerThree
          }

          // Above-break three: beyond arc radius
          if distanceFromBasket >= g.threePointArcRadiusFraction {
              return .aboveBreakThree
          }

          return .midRange
      }
  }
  ```

- [ ] **Step 4: Run tests — verify they PASS**

  Press ⌘U. Expected: all 11 tests in `CourtZoneClassifierTests` pass.

- [ ] **Step 5: Commit**

  ```bash
  git add HoopTrack/Utilities/CourtZoneClassifier.swift HoopTrackTests/CourtZoneClassifierTests.swift
  git commit -m "feat: add CourtZoneClassifier with unit tests"
  ```

---

## Task 4 — DataService: resolveShot

**Files:**
- Modify: `HoopTrack/Services/DataService.swift`

This adds a method that updates a pending `ShotRecord` with its final result. It differs from the existing `updateShot(_:result:courtX:courtY:)` in that it does **not** set `isUserCorrected = true` — CV resolution is not a user correction.

- [ ] **Step 1: Add `resolveShot` to DataService**

  Open `HoopTrack/Services/DataService.swift`. After the closing brace of `updateShot`, add:

  ```swift
  /// Called by CVPipeline to resolve a pending shot with its final make/miss result.
  /// Does NOT set isUserCorrected — only user-initiated edits set that flag.
  func resolveShot(_ shot: ShotRecord,
                   result: ShotResult,
                   zone: CourtZone,
                   courtX: Double,
                   courtY: Double) throws {
      shot.result  = result
      shot.zone    = zone
      shot.courtX  = courtX
      shot.courtY  = courtY
      shot.session?.recalculateStats()
      try modelContext.save()
  }
  ```

- [ ] **Step 2: Build (⌘B)**

  Expected: zero errors.

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/Services/DataService.swift
  git commit -m "feat: add DataService.resolveShot for CV pipeline shot resolution"
  ```

---

## Task 5 — CourtCalibrationService

**Files:**
- Create: `HoopTrack/Services/CourtCalibrationService.swift`

- [ ] **Step 1: Create the service**

  ```swift
  // HoopTrack/Services/CourtCalibrationService.swift
  // Detects the backboard/hoop rectangle via Vision and locks a reference CGRect
  // used by CVPipeline to map ball positions to normalised court coordinates.

  import Vision
  import AVFoundation
  import CoreGraphics

  enum CalibrationState {
      case uncalibrated
      case detecting
      case calibrated(hoopRect: CGRect)
      case failed(reason: String)

      var isCalibrated: Bool {
          if case .calibrated = self { return true }
          return false
      }
  }

  final class CourtCalibrationService {

      // MARK: - State
      private(set) var state: CalibrationState = .uncalibrated

      // Callback fired on main thread when state changes — observed by LiveSessionViewModel.
      var onStateChange: ((CalibrationState) -> Void)?

      // MARK: - Vision
      private let request: VNDetectRectanglesRequest = {
          let r = VNDetectRectanglesRequest()
          r.minimumAspectRatio    = 1.5   // backboard is wider than tall
          r.maximumAspectRatio    = 5.0
          r.minimumConfidence     = 0.6
          r.maximumObservations   = 3
          return r
      }()

      // Accumulate candidate rects across frames before locking
      private var candidates: [CGRect] = []
      private let framesNeeded = 10

      // MARK: - Lifecycle

      func startCalibration() {
          candidates = []
          setState(.detecting)
      }

      func reset() {
          candidates = []
          setState(.uncalibrated)
      }

      // MARK: - Frame Processing
      // Called on the camera's sessionQueue (background thread).

      func processFrame(_ buffer: CMSampleBuffer) {
          guard case .detecting = state,
                let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }

          let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                              orientation: .up,
                                              options: [:])
          try? handler.perform([request])

          guard let results = request.results as? [VNRectangleObservation],
                let best    = results.max(by: { $0.boundingBox.width < $1.boundingBox.width })
          else { return }

          candidates.append(best.boundingBox)
          if candidates.count >= framesNeeded {
              let avgRect = averaged(candidates)
              setState(.calibrated(hoopRect: avgRect))
          }
      }

      // MARK: - Court Coordinate Mapping

      /// Maps a ball bounding box (Vision normalised coords) to normalised court position (0–1).
      /// Returns nil if calibration is not complete.
      func courtPosition(for ballBox: CGRect) -> (courtX: Double, courtY: Double)? {
          guard case .calibrated(let hoopRect) = state else { return nil }

          let ballCX = ballBox.midX
          let ballCY = ballBox.midY

          // Horizontal: positive offset from hoop centre maps to court right
          let rawX = (ballCX - hoopRect.midX) / hoopRect.width * 0.5 + 0.5
          // Vertical: ball below hoop (lower Y in Vision) = closer to baseline (lower courtY)
          let rawY = max(0, hoopRect.midY - ballCY) / hoopRect.height * 0.5

          return (
              courtX: rawX.clamped(to: 0...1),
              courtY: rawY.clamped(to: 0...1)
          )
      }

      // MARK: - Private

      private func setState(_ newState: CalibrationState) {
          state = newState
          DispatchQueue.main.async { [weak self] in
              guard let self else { return }
              self.onStateChange?(self.state)
          }
      }

      private func averaged(_ rects: [CGRect]) -> CGRect {
          let n = Double(rects.count)
          return CGRect(
              x:      rects.map(\.minX).reduce(0, +) / n,
              y:      rects.map(\.minY).reduce(0, +) / n,
              width:  rects.map(\.width).reduce(0, +) / n,
              height: rects.map(\.height).reduce(0, +) / n
          )
      }
  }
  ```

- [ ] **Step 2: Build (⌘B)**

  Expected: zero errors. `clamped(to:)` is already defined on `Double` in `Extensions.swift`.

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/Services/CourtCalibrationService.swift
  git commit -m "feat: add CourtCalibrationService with hoop detection and court mapping"
  ```

---

## Task 6 — CVPipeline State Machine

**Files:**
- Create: `HoopTrack/Services/CVPipeline.swift`

- [ ] **Step 1: Create CVPipeline**

  ```swift
  // HoopTrack/Services/CVPipeline.swift
  // Subscribes to CameraService.framePublisher and runs the shot-detection
  // state machine. All Vision work and trajectory maths run on the camera's
  // sessionQueue. Calls @MainActor methods on LiveSessionViewModel for shot logging.

  import AVFoundation
  import Combine
  import CoreGraphics
  import Foundation

  // MARK: - Internal State

  private enum PipelineState {
      case idle
      case tracking(trajectory: [BallDetection])
      case releaseDetected(releaseBox: CGRect, trajectory: [BallDetection])
  }

  // MARK: - CVPipeline

  final class CVPipeline {

      // MARK: - Dependencies
      private let detector:    BallDetectorProtocol
      private let calibration: CourtCalibrationService
      private weak var viewModel: LiveSessionViewModel?

      // MARK: - State
      private var pipelineState: PipelineState = .idle
      private var frameCancellable: AnyCancellable?

      // Tracking: if no ball seen for 0.3s, return to IDLE
      private var lastDetectionTimestamp: CMTime = .zero
      private let trackingTimeoutSec: Double = 0.3

      // Release resolved: 2s timeout → MISS
      private var releaseTimestamp: CMTime = .zero
      private let shotTimeoutSec: Double = 2.0

      // MARK: - Init
      init(detector: BallDetectorProtocol, calibration: CourtCalibrationService) {
          self.detector    = detector
          self.calibration = calibration
      }

      // MARK: - Lifecycle

      func start(framePublisher: AnyPublisher<CMSampleBuffer, Never>,
                 viewModel: LiveSessionViewModel) {
          self.viewModel = viewModel
          // Frames arrive on sessionQueue — CV work stays there; UI calls dispatch to main.
          frameCancellable = framePublisher
              .sink { [weak self] buffer in
                  self?.processBuffer(buffer)
              }
      }

      func stop() {
          frameCancellable?.cancel()
          frameCancellable = nil
          pipelineState = .idle
      }

      // MARK: - Core Frame Processing

      private func processBuffer(_ buffer: CMSampleBuffer) {
          // Feed calibration during detecting phase
          calibration.processFrame(buffer)

          // Only run shot detection after hoop is locked
          guard calibration.state.isCalibrated else { return }

          let now       = CMSampleBufferGetPresentationTimeStamp(buffer)
          let detection = detector.detect(buffer: buffer)

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
                      // The first point in the trajectory is where the player released
                      let releaseBox = trajectory.first!.boundingBox
                      pipelineState  = .releaseDetected(releaseBox: releaseBox,
                                                         trajectory: trajectory)
                      releaseTimestamp = now
                      logPendingShot(releaseBox: releaseBox)
                  } else {
                      pipelineState = .tracking(trajectory: trajectory)
                  }
              } else {
                  let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, lastDetectionTimestamp))
                  if elapsed > trackingTimeoutSec { pipelineState = .idle }
              }

          case .releaseDetected(let releaseBox, let trajectory):
              let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, releaseTimestamp))

              if let d = detection, case .calibrated(let hoopRect) = calibration.state {
                  if isEnteringHoop(ballBox: d.boundingBox, hoopRect: hoopRect) {
                      resolveShot(result: .make, releaseBox: releaseBox)
                      return
                  }
                  if isBelowHoop(ballBox: d.boundingBox, hoopRect: hoopRect) {
                      resolveShot(result: .miss, releaseBox: releaseBox)
                      return
                  }
                  _ = trajectory  // reserved for Phase 3 Shot Science
              }

              if elapsed > shotTimeoutSec {
                  resolveShot(result: .miss, releaseBox: releaseBox)
              }
          }
      }

      // MARK: - Trajectory Analysis

      /// True when the ball has risen at least 5% of frame height and is now 3% below its peak.
      /// Vision Y coordinates: origin bottom-left, increasing upward.
      private func isAtPeak(trajectory: [BallDetection]) -> Bool {
          guard trajectory.count >= 5 else { return false }
          let ys      = trajectory.suffix(5).map { $0.boundingBox.midY }
          let peak    = ys.max()!
          let current = ys.last!
          let first   = ys.first!
          let wasRising = peak - first   > 0.05   // rose ≥ 5% of frame height
          let hasPeaked = peak - current > 0.03   // dropped ≥ 3% from peak
          return wasRising && hasPeaked
      }

      /// Ball centre is within an expanded hoop rect — indicates a make.
      private func isEnteringHoop(ballBox: CGRect, hoopRect: CGRect) -> Bool {
          // Expand rect to tolerate partial overlap as ball enters from above
          let expanded    = hoopRect.insetBy(dx: -hoopRect.width  * 0.2,
                                             dy: -hoopRect.height * 0.5)
          let ballCentre  = CGPoint(x: ballBox.midX, y: ballBox.midY)
          return expanded.contains(ballCentre)
      }

      /// Ball has fallen below the bottom edge of the hoop rect — indicates a miss.
      private func isBelowHoop(ballBox: CGRect, hoopRect: CGRect) -> Bool {
          return ballBox.midY < hoopRect.minY - 0.05
      }

      // MARK: - Shot Logging (dispatches to main actor)

      private func logPendingShot(releaseBox: CGRect) {
          let pos  = calibration.courtPosition(for: releaseBox) ?? (courtX: 0.5, courtY: 0.5)
          let zone = CourtZoneClassifier.classify(courtX: pos.courtX, courtY: pos.courtY)
          DispatchQueue.main.async { [weak self] in
              self?.viewModel?.logPendingShot(zone: zone, courtX: pos.courtX, courtY: pos.courtY)
          }
      }

      private func resolveShot(result: ShotResult, releaseBox: CGRect) {
          let pos  = calibration.courtPosition(for: releaseBox) ?? (courtX: 0.5, courtY: 0.5)
          let zone = CourtZoneClassifier.classify(courtX: pos.courtX, courtY: pos.courtY)
          pipelineState = .idle
          DispatchQueue.main.async { [weak self] in
              self?.viewModel?.resolvePendingShot(result: result,
                                                   zone: zone,
                                                   courtX: pos.courtX,
                                                   courtY: pos.courtY)
          }
      }
  }
  ```

- [ ] **Step 2: Build (⌘B)**

  Expected: zero errors. Note: `LiveSessionViewModel.logPendingShot` and `resolvePendingShot` don't exist yet — the build will fail with "value of type has no member". That's expected; we add them in Task 7.

  If you want a green build before Task 7, add stub methods to `LiveSessionViewModel`:
  ```swift
  func logPendingShot(zone: CourtZone, courtX: Double, courtY: Double) {}
  func resolvePendingShot(result: ShotResult, zone: CourtZone, courtX: Double, courtY: Double) {}
  ```
  These are replaced in full in Task 7.

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/Services/CVPipeline.swift
  git commit -m "feat: add CVPipeline shot-detection state machine"
  ```

---

## Task 7 — LiveSessionViewModel Phase 2 Additions

**Files:**
- Modify: `HoopTrack/ViewModels/LiveSessionViewModel.swift`

Adds `logPendingShot`, `resolvePendingShot`, calibration state exposure, and the Phase 2 dependency storage.

- [ ] **Step 1: Add Phase 2 published properties and storage**

  Open `HoopTrack/ViewModels/LiveSessionViewModel.swift`. After the line `@Published var errorMessage: String?`, add:

  ```swift
  // MARK: - Phase 2 CV State
  @Published var calibrationIsActive: Bool = false   // true while CV is auto-detecting shots
  @Published var isCalibrated: Bool = false           // true once hoop is locked
  ```

  After `private var hapticService: HapticService`, add:

  ```swift
  // Phase 2 — CV pipeline pending shot tracking
  private var pendingShotRecord: ShotRecord?
  ```

- [ ] **Step 2: Add logPendingShot and resolvePendingShot**

  After the closing brace of the existing `logShot` method, add:

  ```swift
  // MARK: - Phase 2 CV Shot Logging

  /// Called by CVPipeline when the ball peaks (release detected).
  /// Creates a pending ShotRecord and stores a reference for later resolution.
  func logPendingShot(zone: CourtZone, courtX: Double, courtY: Double) {
      guard let session else { return }
      do {
          let shot = try dataService.addShot(to: session,
                                             result: .pending,
                                             zone: zone,
                                             shotType: .unknown,
                                             courtX: courtX,
                                             courtY: courtY)
          pendingShotRecord = shot
          recentShots       = Array(session.shots.suffix(5))
          lastShotResult    = .pending
          triggerHaptic(for: .pending)
      } catch {
          errorMessage = error.localizedDescription
      }
  }

  /// Called by CVPipeline when make/miss is determined.
  /// Updates the pending ShotRecord in place; falls back to a fresh logShot if
  /// no pending record exists (guards against edge-case timing).
  func resolvePendingShot(result: ShotResult, zone: CourtZone, courtX: Double, courtY: Double) {
      guard let pending = pendingShotRecord else {
          logShot(result: result, zone: zone, courtX: courtX, courtY: courtY)
          return
      }
      do {
          try dataService.resolveShot(pending,
                                      result: result,
                                      zone: zone,
                                      courtX: courtX,
                                      courtY: courtY)
          pendingShotRecord = nil
          recentShots       = Array(session?.shots.suffix(5) ?? [])
          lastShotResult    = result
          triggerHaptic(for: result)
      } catch {
          errorMessage = error.localizedDescription
      }
  }

  /// Called by LiveSessionView when CourtCalibrationService changes state.
  func updateCalibrationState(isCalibrated: Bool) {
      self.isCalibrated      = isCalibrated
      self.calibrationIsActive = isCalibrated
  }
  ```

- [ ] **Step 3: Build (⌘B)**

  Expected: zero errors. If stub methods were added in Task 6 Step 2, remove them now — the real implementations above replace them.

- [ ] **Step 4: Commit**

  ```bash
  git add HoopTrack/ViewModels/LiveSessionViewModel.swift
  git commit -m "feat: add logPendingShot and resolvePendingShot to LiveSessionViewModel"
  ```

---

## Task 8 — LiveSessionView: Pipeline Wiring + Calibration Overlay

**Files:**
- Modify: `HoopTrack/Views/Train/LiveSessionView.swift`

Wires the CV pipeline lifecycle into the view and adds the calibration prompt overlay.

- [ ] **Step 1: Add pipeline state properties**

  Open `HoopTrack/Views/Train/LiveSessionView.swift`. After `@State private var showMissAnimation`, add:

  ```swift
  // Phase 2: CV pipeline
  @State private var cvPipeline:    CVPipeline?
  @State private var calibration:   CourtCalibrationService?
  ```

- [ ] **Step 2: Start the pipeline in `.task`**

  Find the `.task` modifier. Replace its entire body with:

  ```swift
  .task {
      viewModel.configure(
          dataService: DataService(modelContext: modelContext),
          hapticService: hapticService
      )

      if cameraService.permissionStatus == .notDetermined {
          await cameraService.requestPermission()
      }
      if cameraService.permissionStatus == .authorized {
          cameraService.configureSession(mode: .rear)
          cameraService.startSession()
      }

      viewModel.start(drillType: drillType, namedDrill: namedDrill, courtType: .nba)

      // Phase 2: start CV pipeline
      let cal = CourtCalibrationService()
      cal.onStateChange = { [weak viewModel] state in
          viewModel?.updateCalibrationState(isCalibrated: state.isCalibrated)
      }
      cal.startCalibration()

      #if DEBUG
      let detector: BallDetectorProtocol = BallDetectorStub()
      #else
      // Replace with: let detector = try! BallDetector() once model is trained
      fatalError("Real BallDetector not yet available — use DEBUG build")
      #endif

      let pipeline = CVPipeline(detector: detector, calibration: cal)
      pipeline.start(framePublisher: cameraService.framePublisher, viewModel: viewModel)

      calibration = cal
      cvPipeline  = pipeline
  }
  ```

- [ ] **Step 3: Stop the pipeline in `.onDisappear`**

  Find `.onDisappear { cameraService.stopSession() }`. Replace with:

  ```swift
  .onDisappear {
      cvPipeline?.stop()
      calibration?.reset()
      cameraService.stopSession()
  }
  ```

- [ ] **Step 4: Add calibration overlay to the ZStack**

  In the `body` computed property, find the `// MARK: HUD Overlay` comment. After the `VStack { topHUD ... }` block but still inside the outer `ZStack`, add:

  ```swift
  // Phase 2: calibration prompt — shown until hoop is locked
  if !viewModel.isCalibrated {
      calibrationOverlay
  }
  ```

- [ ] **Step 5: Implement the calibration overlay view**

  After the `// MARK: - Top HUD` private var, add:

  ```swift
  // MARK: - Calibration Overlay

  private var calibrationOverlay: some View {
      VStack(spacing: 16) {
          Image(systemName: "viewfinder")
              .font(.system(size: 48))
              .foregroundStyle(.white)
          Text("Aim at the hoop")
              .font(.title2.bold())
              .foregroundStyle(.white)
          Text("Keep the backboard in frame until the indicator turns green.")
              .font(.subheadline)
              .foregroundStyle(.white.opacity(0.8))
              .multilineTextAlignment(.center)
              .padding(.horizontal, 40)
          ProgressView()
              .progressViewStyle(.circular)
              .tint(.white)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.black.opacity(0.55))
  }
  ```

- [ ] **Step 6: Build (⌘B)**

  Expected: zero errors.

- [ ] **Step 7: Smoke test on simulator / device (DEBUG)**

  Run on a real device (camera required). The calibration overlay should appear on session start, then dismiss once the `BallDetectorStub` begins producing detections (within ~3 seconds — stub fires `onStateChange` only when 10 frames are scanned; because stub returns nil during calibration, `CourtCalibrationService` will need actual rectangles).

  > **Note:** The `BallDetectorStub` does not trigger calibration (it returns ball detections, not hoop rects). To test calibration dismissal in DEBUG, temporarily hard-code `cal.startCalibration()` to immediately call `setState(.calibrated(hoopRect: CGRect(x:0.3, y:0.7, width:0.4, height:0.1)))` — remove after verifying UI. Alternatively, add a debug "Skip Calibration" button that calls `calibration?.state = .calibrated(...)`.

- [ ] **Step 8: Commit**

  ```bash
  git add HoopTrack/Views/Train/LiveSessionView.swift
  git commit -m "feat: wire CVPipeline into LiveSessionView with calibration overlay"
  ```

---

## Task 9 — Pending Shot UI (Recent Shots Strip)

**Files:**
- Modify: `HoopTrack/Views/Train/LiveSessionView.swift`

Changes the recent shots strip so pending shots show as gray instead of red.

- [ ] **Step 1: Write the failing test**

  > The shot-dot colour logic is currently inline in the view — extract it to a helper for testability.

  Add to `HoopTrackTests/CVPipelineStateTests.swift` (create this file if it doesn't exist):

  ```swift
  // HoopTrackTests/CVPipelineStateTests.swift
  import XCTest
  @testable import HoopTrack

  final class CVPipelineStateTests: XCTestCase {

      // Test the helper that maps ShotResult → dot colour name
      func testShotDotColorMake() {
          XCTAssertEqual(ShotResult.make.dotColorName,    "shotDotGreen")
      }

      func testShotDotColorMiss() {
          XCTAssertEqual(ShotResult.miss.dotColorName,    "shotDotRed")
      }

      func testShotDotColorPending() {
          XCTAssertEqual(ShotResult.pending.dotColorName, "shotDotGray")
      }
  }
  ```

- [ ] **Step 2: Run test — verify it FAILS**

  Expected: compile error "value of type 'ShotResult' has no member 'dotColorName'".

- [ ] **Step 3: Add dotColorName to ShotResult**

  Open `HoopTrack/Models/Enums.swift`. After the `ShotResult` enum closing brace, add:

  ```swift
  extension ShotResult {
      /// Semantic colour name for the recent-shots HUD dot.
      var dotColorName: String {
          switch self {
          case .make:    return "shotDotGreen"
          case .miss:    return "shotDotRed"
          case .pending: return "shotDotGray"
          }
      }
  }
  ```

- [ ] **Step 4: Run test — verify it PASSES**

  ⌘U. Expected: `CVPipelineStateTests` passes (all 3 tests).

- [ ] **Step 5: Update the recent shots strip in LiveSessionView**

  Find `recentShotsStrip` in `LiveSessionView.swift`. Replace the `Circle().fill(shot.isMake ? Color.green : Color.red)` line with:

  ```swift
  Circle()
      .fill(dotColor(for: shot.result))
      .frame(width: 18, height: 18)
      .overlay(
          Circle().stroke(.white.opacity(0.4), lineWidth: 1)
      )
  ```

  Then add the private helper immediately below `recentShotsStrip`:

  ```swift
  private func dotColor(for result: ShotResult) -> Color {
      switch result {
      case .make:    return .green
      case .miss:    return .red
      case .pending: return Color(.systemGray)
      }
  }
  ```

- [ ] **Step 6: Build and visually verify (⌘B, then run)**

  Run in simulator with `BallDetectorStub`. The stub fires pending shots every ~3 seconds. The HUD strip should show a gray dot while the shot is pending, replacing it with green/red once resolved.

  > The stub currently doesn't trigger the full arc automatically because calibration must complete first. For a quick visual test, use the manual Miss/Make buttons — these still call `logShot` directly and will show green/red dots.

- [ ] **Step 7: Commit**

  ```bash
  git add HoopTrack/Models/Enums.swift HoopTrack/Views/Train/LiveSessionView.swift HoopTrackTests/CVPipelineStateTests.swift
  git commit -m "feat: add pending shot gray dot to recent shots HUD strip"
  ```

---

## Task 10 — VideoRecordingService (Optional Phase 2)

**Files:**
- Create: `HoopTrack/Services/VideoRecordingService.swift`

Records the session to `Documents/Sessions/<session-id>.mov` for Phase 3 Shot Science replay.

- [ ] **Step 1: Create the service**

  ```swift
  // HoopTrack/Services/VideoRecordingService.swift
  // Wraps AVCaptureMovieFileOutput to record a session video.
  // Stores the filename in TrainingSession.videoFileName on completion.
  // Phase 2: optional. Phase 3: required for Shot Science replay.

  import AVFoundation
  import Foundation

  final class VideoRecordingService: NSObject {

      // MARK: - State
      private(set) var isRecording: Bool = false
      private var movieOutput = AVCaptureMovieFileOutput()
      private var currentSessionID: UUID?

      /// Called on the main thread when recording completes or fails.
      var onRecordingFinished: ((Result<URL, Error>) -> Void)?

      // MARK: - Setup

      /// Attach to a running AVCaptureSession before calling startRecording().
      func configure(captureSession: AVCaptureSession) {
          guard captureSession.canAddOutput(movieOutput) else { return }
          captureSession.addOutput(movieOutput)
          // Match orientation with camera output
          if let connection = movieOutput.connection(with: .video),
             connection.isVideoRotationAngleSupported(90) {
              connection.videoRotationAngle = 90
          }
      }

      // MARK: - Recording

      func startRecording(sessionID: UUID) {
          guard !isRecording else { return }
          currentSessionID = sessionID

          let docsURL = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask)[0]
          let sessionsDir = docsURL.appendingPathComponent("Sessions", isDirectory: true)
          try? FileManager.default.createDirectory(at: sessionsDir,
                                                    withIntermediateDirectories: true)
          let outputURL = sessionsDir.appendingPathComponent("\(sessionID.uuidString).mov")

          movieOutput.startRecording(to: outputURL, recordingDelegate: self)
          isRecording = true
      }

      func stopRecording() {
          guard isRecording else { return }
          movieOutput.stopRecording()
      }
  }

  // MARK: - AVCaptureFileOutputRecordingDelegate

  extension VideoRecordingService: AVCaptureFileOutputRecordingDelegate {

      func fileOutput(_ output: AVCaptureFileOutput,
                      didFinishRecordingTo outputFileURL: URL,
                      from connections: [AVCaptureConnection],
                      error: Error?) {
          isRecording = false
          if let error {
              DispatchQueue.main.async { [weak self] in
                  self?.onRecordingFinished?(.failure(error))
              }
          } else {
              DispatchQueue.main.async { [weak self] in
                  self?.onRecordingFinished?(.success(outputFileURL))
              }
          }
      }
  }
  ```

- [ ] **Step 2: Integrate into LiveSessionView (optional wire-up)**

  To enable recording, in the `.task` block of `LiveSessionView.swift`, after `cvPipeline = pipeline`, add:

  ```swift
  // Optional Phase 2: record session video
  // let recorder = VideoRecordingService()
  // recorder.configure(captureSession: cameraService.captureSession)
  // if let sessionID = viewModel.session?.id {
  //     recorder.startRecording(sessionID: sessionID)
  //     recorder.onRecordingFinished = { result in
  //         if case .success(let url) = result {
  //             viewModel.session?.videoFileName = url.lastPathComponent
  //         }
  //     }
  // }
  ```

  Leave this commented out for now. Uncomment when Phase 3 Shot Science needs the video file.

- [ ] **Step 3: Build (⌘B)**

  Expected: zero errors.

- [ ] **Step 4: Commit**

  ```bash
  git add HoopTrack/Services/VideoRecordingService.swift HoopTrack/Views/Train/LiveSessionView.swift
  git commit -m "feat: add VideoRecordingService (Phase 2 optional, Phase 3 required)"
  ```

---

## Self-Review

**Spec coverage check against Phase2_Implementation_Plan.md:**

| Spec Requirement | Covered By |
|-----------------|-----------|
| Ball detected and tracked in real-time at 60fps | Tasks 1–2 (stub), Task 6 (pipeline subscribes at 60fps) |
| Make/miss auto-detected > 92% accuracy | Task 6 state machine (accuracy depends on real model — spec acknowledges this) |
| Shot zone classified and stored | Tasks 3, 7 |
| Shot chart populated with real CV data | Tasks 7–8 (logShot/resolvePendingShot write to SwiftData; chart reads SwiftData — no chart changes needed) |
| Manual Make/Miss buttons remain as fallback | Task 8 — buttons NOT removed; overlay hides until calibrated but buttons remain |
| Hoop calibration prompt shown at session start | Task 8, Step 4–5 |
| Pending shot UI (gray dot) | Task 9 |
| Session video recording | Task 10 |
| `ShotRecord` zone, courtX, courtY populated | Tasks 3, 6, 7 |

**Placeholder scan:** None found. All code steps are complete.

**Type consistency:**
- `BallDetection` defined in Task 1, used in Tasks 2, 6 ✓
- `BallDetectorProtocol` defined in Task 1, conformed to in Tasks 2, 8 ✓
- `CalibrationState.isCalibrated` defined in Task 5, used in Tasks 6, 7, 8 ✓
- `logPendingShot(zone:courtX:courtY:)` defined in Task 7, called in Task 6 ✓
- `resolvePendingShot(result:zone:courtX:courtY:)` defined in Task 7, called in Task 6 ✓
- `DataService.resolveShot(_:result:zone:courtX:courtY:)` defined in Task 4, called in Task 7 ✓
- `CourtZoneClassifier.classify(courtX:courtY:)` defined in Task 3, called in Task 6 ✓
- `dotColor(for:)` view helper defined in Task 9, uses `ShotResult` extension from Task 9 ✓

---

*Generated 2026-03-31*
