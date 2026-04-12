# Phase 4 — Dribble Drills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement live dribble drill sessions using the front camera and ARKit: real-time hand tracking (Vision), dribble counting, combo detection, AR floor targets, and a post-session dribble summary.

**Architecture:** `DribbleDrillView` replaces `CameraPreviewView` with an `ARView` (RealityKit) configured for the front camera. An `ARSessionDelegate` (`DribbleARCoordinator`) captures each AR frame's `CVPixelBuffer` and feeds it to `HandTrackingService` (Vision `VNDetectHumanHandPoseRequest`). `DribblePipeline` owns the state machine: tracks wrist Y velocity to count dribbles per hand, detects hand-switch combos, and publishes live metrics to `DribbleSessionViewModel`. At session end, aggregates are persisted to `TrainingSession` via `DataService`. `TrainTabView` routes `.dribble` drill types to `DribbleDrillView` instead of `LiveSessionView`.

**Tech Stack:** Swift 5.10, SwiftUI, RealityKit (`ARView`, `ARWorldTrackingConfiguration`, `ModelEntity`), Vision (`VNDetectHumanHandPoseRequest`, `VNHumanHandPoseObservation`), XCTest

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `HoopTrack/Services/HandTrackingService.swift` | Synchronous `VNDetectHumanHandPoseRequest` wrapper — returns wrist positions for up to 2 hands |
| Create | `HoopTrack/Services/DribblePipeline.swift` | State machine: wrist-velocity dribble detection, combo detection, publishes `DribbleLiveMetrics` |
| Create | `HoopTrack/Utilities/DribbleCalculator.swift` | Pure functions: dribbles per second, hand balance fraction, combo count |
| Create | `HoopTrack/Models/DribbleLiveMetrics.swift` | Value-type DTO carrying live dribble state from pipeline → viewmodel |
| Create | `HoopTrack/ViewModels/DribbleSessionViewModel.swift` | Owns session state for a live dribble session; mirrors LiveSessionViewModel pattern |
| Create | `HoopTrack/Views/Train/DribbleDrillView.swift` | ARView + HUD overlay + AR floor targets + long-press end |
| Create | `HoopTrack/Views/Train/DribbleSessionSummaryView.swift` | Post-session summary: total dribbles, BPS, hand balance, combos |
| Modify | `HoopTrack/Models/TrainingSession.swift` | Add dribble aggregate fields + `recalculateDribbleStats()` |
| Modify | `HoopTrack/Services/DataService.swift` | Add `finaliseDribbleSession(_:metrics:)` |
| Modify | `HoopTrack/Utilities/Constants.swift` | Add `HoopTrack.Dribble` constants namespace |
| Modify | `HoopTrack/Views/Train/TrainTabView.swift` | Route `drillType == .dribble` to `DribbleDrillView` |
| Modify | `HoopTrack/Services/DataService.swift` | Update `updateProfileStats` to populate `ratingBallHandling` from dribble sessions |
| Create | `HoopTrackTests/DribbleCalculatorTests.swift` | Unit tests for all pure dribble calculation functions |

---

## Task 1: DribbleCalculator (TDD) + Constants

**Files:**
- Create: `HoopTrackTests/DribbleCalculatorTests.swift`
- Create: `HoopTrack/Utilities/DribbleCalculator.swift`
- Modify: `HoopTrack/Utilities/Constants.swift`

- [ ] **Step 1: Write the failing tests**

  Create `HoopTrackTests/DribbleCalculatorTests.swift`:

  ```swift
  import XCTest
  @testable import HoopTrack

  final class DribbleCalculatorTests: XCTestCase {

      // MARK: - dribblesPerSecond

      func test_dribblesPerSecond_tenDribblesInTwoSeconds_returnsFive() {
          let result = DribbleCalculator.dribblesPerSecond(count: 10, durationSec: 2.0)
          XCTAssertNotNil(result)
          XCTAssertEqual(result!, 5.0, accuracy: 0.001)
      }

      func test_dribblesPerSecond_zeroDuration_returnsNil() {
          XCTAssertNil(DribbleCalculator.dribblesPerSecond(count: 5, durationSec: 0))
      }

      func test_dribblesPerSecond_zeroDribbles_returnsZero() {
          let result = DribbleCalculator.dribblesPerSecond(count: 0, durationSec: 3.0)
          XCTAssertNotNil(result)
          XCTAssertEqual(result!, 0.0, accuracy: 0.001)
      }

      // MARK: - handBalance

      func test_handBalance_equalHands_returnsHalf() {
          let result = DribbleCalculator.handBalance(leftCount: 10, rightCount: 10)
          XCTAssertNotNil(result)
          XCTAssertEqual(result!, 0.5, accuracy: 0.001)
      }

      func test_handBalance_allLeftHand_returnsOne() {
          let result = DribbleCalculator.handBalance(leftCount: 10, rightCount: 0)
          XCTAssertNotNil(result)
          XCTAssertEqual(result!, 1.0, accuracy: 0.001)
      }

      func test_handBalance_allRightHand_returnsZero() {
          let result = DribbleCalculator.handBalance(leftCount: 0, rightCount: 10)
          XCTAssertNotNil(result)
          XCTAssertEqual(result!, 0.0, accuracy: 0.001)
      }

      func test_handBalance_bothZero_returnsNil() {
          XCTAssertNil(DribbleCalculator.handBalance(leftCount: 0, rightCount: 0))
      }

      // MARK: - comboCount

      func test_comboCount_noSwitches_returnsZero() {
          // All same hand — no combos
          let history: [DribbleCalculator.HandSide] = [.right, .right, .right, .right]
          XCTAssertEqual(DribbleCalculator.comboCount(handHistory: history), 0)
      }

      func test_comboCount_singleSwitch_returnsOne() {
          let history: [DribbleCalculator.HandSide] = [.right, .right, .left, .left]
          XCTAssertEqual(DribbleCalculator.comboCount(handHistory: history), 1)
      }

      func test_comboCount_threeAlternatingSwitches_returnsThree() {
          let history: [DribbleCalculator.HandSide] = [.right, .left, .right, .left]
          XCTAssertEqual(DribbleCalculator.comboCount(handHistory: history), 3)
      }

      func test_comboCount_emptyHistory_returnsZero() {
          XCTAssertEqual(DribbleCalculator.comboCount(handHistory: []), 0)
      }
  }
  ```

- [ ] **Step 2: Run tests to verify they fail**

  In Xcode: Product → Test (⌘U), filter to `DribbleCalculatorTests`.
  Expected: build errors — `DribbleCalculator` type not found.

- [ ] **Step 3: Add Dribble constants to Constants.swift**

  In `HoopTrack/Utilities/Constants.swift`, add after the `ShotScience` enum:

  ```swift
      // MARK: - Dribble (Phase 4 thresholds)
      enum Dribble {
          /// Minimum wrist Y displacement (normalised 0–1) to count as a dribble bounce.
          static let minWristDisplacementFrac: Double = 0.03
          /// Frames a wrist velocity must sustain a direction change to avoid noise triggers.
          static let velocityConfirmFrames: Int = 2
          /// Optimal dribbles-per-second range for ball-handling drills.
          static let optimalBPSMin: Double = 3.0
          static let optimalBPSMax: Double = 7.0
          /// Max seconds between two dribble events to count as a hand-switch combo.
          static let comboWindowSec: Double = 1.5
          /// Ball diameter in cm — used as scale reference (same as hoop for shot science).
          static let ballDiameterCm: Double = 24.0
          /// Number of AR floor targets per dribble drill.
          static let arTargetCount: Int = 3
          /// Radius of each AR floor target (metres).
          static let arTargetRadiusM: Float = 0.25
      }
  ```

- [ ] **Step 4: Create DribbleCalculator.swift**

  Create `HoopTrack/Utilities/DribbleCalculator.swift`:

  ```swift
  // HoopTrack/Utilities/DribbleCalculator.swift
  // Pure dribble math. No side effects. All functions are static.

  import Foundation

  enum DribbleCalculator {

      enum HandSide {
          case left, right
      }

      // MARK: - Dribbles Per Second

      /// Returns dribbles per second, or nil if durationSec is zero.
      static func dribblesPerSecond(count: Int, durationSec: Double) -> Double? {
          guard durationSec > 0 else { return nil }
          return Double(count) / durationSec
      }

      // MARK: - Hand Balance

      /// Returns fraction of dribbles performed with the left hand (0.0 = all right, 1.0 = all left).
      /// Returns nil if both counts are zero.
      static func handBalance(leftCount: Int, rightCount: Int) -> Double? {
          let total = leftCount + rightCount
          guard total > 0 else { return nil }
          return Double(leftCount) / Double(total)
      }

      // MARK: - Combo Count

      /// Counts the number of hand switches (each switch = one combo rep).
      static func comboCount(handHistory: [HandSide]) -> Int {
          guard handHistory.count >= 2 else { return 0 }
          var count = 0
          for i in 1 ..< handHistory.count {
              if handHistory[i] != handHistory[i - 1] { count += 1 }
          }
          return count
      }
  }
  ```

- [ ] **Step 5: Run tests to verify they pass**

  Product → Test (⌘U), filter to `DribbleCalculatorTests`.
  Expected: all 10 tests pass.

- [ ] **Step 6: Commit**

  ```bash
  git add HoopTrackTests/DribbleCalculatorTests.swift \
          HoopTrack/Utilities/DribbleCalculator.swift \
          HoopTrack/Utilities/Constants.swift
  git commit -m "feat: add DribbleCalculator pure functions and Dribble constants (TDD)"
  ```

---

## Task 2: DribbleLiveMetrics + HandTrackingService

**Files:**
- Create: `HoopTrack/Models/DribbleLiveMetrics.swift`
- Create: `HoopTrack/Services/HandTrackingService.swift`

- [ ] **Step 1: Create DribbleLiveMetrics.swift**

  Create `HoopTrack/Models/DribbleLiveMetrics.swift`:

  ```swift
  // HoopTrack/Models/DribbleLiveMetrics.swift
  // Value-type DTO carrying live dribble state from DribblePipeline → DribbleSessionViewModel.

  import CoreGraphics

  struct DribbleLiveMetrics {
      var totalDribbles: Int        = 0
      var leftHandDribbles: Int     = 0
      var rightHandDribbles: Int    = 0
      var currentBPS: Double        = 0   // dribbles per second (rolling 3-sec window)
      var maxBPS: Double            = 0
      var combosDetected: Int       = 0
      var lastActiveHand: DribbleCalculator.HandSide? = nil
      /// Normalised image position of left wrist (nil if not visible).
      var leftWristPosition: CGPoint?  = nil
      /// Normalised image position of right wrist (nil if not visible).
      var rightWristPosition: CGPoint? = nil
  }
  ```

- [ ] **Step 2: Create HandTrackingService.swift**

  Create `HoopTrack/Services/HandTrackingService.swift`:

  ```swift
  // HoopTrack/Services/HandTrackingService.swift
  // Synchronous Vision hand pose detector.
  // Returns up to two VNHumanHandPoseObservation (one per hand).
  // Must be called on a background queue (e.g. ARSession delegate queue).

  import Vision
  import CoreVideo

  final class HandTrackingService {

      /// Detects up to 2 hand poses in a single pixel buffer.
      /// Synchronous — blocks calling queue for < 5ms on A15.
      nonisolated func detectHands(pixelBuffer: CVPixelBuffer) -> [VNHumanHandPoseObservation] {
          let request = VNDetectHumanHandPoseRequest()
          request.maximumHandCount = 2
          let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                              orientation: .up,
                                              options: [:])
          try? handler.perform([request])
          return request.results ?? []
      }
  }
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/Models/DribbleLiveMetrics.swift \
          HoopTrack/Services/HandTrackingService.swift
  git commit -m "feat: add DribbleLiveMetrics DTO and HandTrackingService Vision wrapper"
  ```

---

## Task 3: TrainingSession dribble fields + DataService support

**Files:**
- Modify: `HoopTrack/Models/TrainingSession.swift`
- Modify: `HoopTrack/Services/DataService.swift`

- [ ] **Step 1: Add dribble aggregate fields to TrainingSession**

  In `HoopTrack/Models/TrainingSession.swift`, add after the `// MARK: - Video` block (before the `init`):

  ```swift
      // MARK: - Dribble Aggregates (Phase 4 — populated at dribble session end)
      var totalDribbles: Int?
      var avgDribblesPerSec: Double?
      var maxDribblesPerSec: Double?
      var handBalanceFraction: Double?  // 0.0 = all right, 1.0 = all left, nil = no data
      var dribbleCombosDetected: Int?
  ```

  In the `init`, add after `self.videoPinnedByUser = false`:

  ```swift
          self.totalDribbles          = nil
          self.avgDribblesPerSec      = nil
          self.maxDribblesPerSec      = nil
          self.handBalanceFraction    = nil
          self.dribbleCombosDetected  = nil
  ```

  Add a new method after `recalculateStats()`:

  ```swift
      /// Applies dribble session aggregates. Call from DataService.finaliseDribbleSession.
      func applyDribbleMetrics(_ metrics: DribbleLiveMetrics, durationSec: Double) {
          totalDribbles       = metrics.totalDribbles
          maxDribblesPerSec   = metrics.maxBPS
          avgDribblesPerSec   = DribbleCalculator.dribblesPerSecond(
                                    count: metrics.totalDribbles,
                                    durationSec: durationSec)
          handBalanceFraction = DribbleCalculator.handBalance(
                                    leftCount:  metrics.leftHandDribbles,
                                    rightCount: metrics.rightHandDribbles)
          dribbleCombosDetected = metrics.combosDetected
      }
  ```

- [ ] **Step 2: Add finaliseDribbleSession to DataService**

  In `HoopTrack/Services/DataService.swift`, add after `finaliseSession(_:)`:

  ```swift
      /// Finalises a dribble drill session. Applies live dribble metrics to the session model,
      /// stamps endedAt, and updates the player profile's ball-handling rating.
      func finaliseDribbleSession(_ session: TrainingSession,
                                  metrics: DribbleLiveMetrics) throws {
          session.endedAt         = .now
          session.durationSeconds = session.endedAt!.timeIntervalSince(session.startedAt)
          session.applyDribbleMetrics(metrics, durationSec: session.durationSeconds)
          try modelContext.save()

          let profile = try fetchOrCreateProfile()
          updateProfileStats(profile, with: session)
          updateBallHandlingRating(profile, from: session)
          try modelContext.save()
      }
  ```

  Add the helper at the bottom of the private section:

  ```swift
      private func updateBallHandlingRating(_ profile: PlayerProfile,
                                            from session: TrainingSession) {
          guard let bps = session.avgDribblesPerSec, bps > 0 else { return }
          // Scale: 3 BPS = 40 rating, 7 BPS = 90 rating. Clamp to 0–100.
          let raw = ((bps - HoopTrack.Dribble.optimalBPSMin)
                     / (HoopTrack.Dribble.optimalBPSMax - HoopTrack.Dribble.optimalBPSMin))
                    * 50.0 + 40.0
          let clamped = max(HoopTrack.SkillRating.minRating,
                            min(HoopTrack.SkillRating.maxRating, raw))
          // Exponential moving average (α = 0.3) so one session doesn't swing the rating wildly.
          let alpha = 0.3
          profile.ratingBallHandling = profile.ratingBallHandling == 0
              ? clamped
              : profile.ratingBallHandling * (1 - alpha) + clamped * alpha
      }
  ```

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/Models/TrainingSession.swift \
          HoopTrack/Services/DataService.swift
  git commit -m "feat: add dribble aggregate fields to TrainingSession and finaliseDribbleSession to DataService"
  ```

---

## Task 4: DribblePipeline

**Files:**
- Create: `HoopTrack/Services/DribblePipeline.swift`

- [ ] **Step 1: Create DribblePipeline.swift**

  Create `HoopTrack/Services/DribblePipeline.swift`:

  ```swift
  // HoopTrack/Services/DribblePipeline.swift
  // Processes ARKit frames to detect dribble events via Vision hand tracking.
  // Runs on the ARSession delegate queue (background).
  // Publishes DribbleLiveMetrics updates to DribbleSessionViewModel on the main thread.
  //
  // Dribble detection algorithm:
  //   - Track wrist Y position per hand across frames.
  //   - A dribble is counted when wrist Y transitions from descending to ascending
  //     (local minimum = ball contact with floor).
  //   - Requires `velocityConfirmFrames` consecutive frames in each direction
  //     to suppress noise.

  import Vision
  import RealityKit
  import CoreVideo

  @MainActor
  protocol DribblePipelineDelegate: AnyObject {
      func pipeline(_ pipeline: DribblePipeline, didUpdate metrics: DribbleLiveMetrics)
  }

  final class DribblePipeline {

      weak var delegate: DribblePipelineDelegate?

      private let handService = HandTrackingService()

      // Per-hand wrist tracking state
      private var leftState  = WristState()
      private var rightState = WristState()

      // Rolling BPS window (last 3 seconds worth of dribble timestamps)
      private var dribbleTimestamps: [Double] = []  // seconds since session start
      private var sessionStartTime: Double = 0

      private var metrics = DribbleLiveMetrics()

      // Combo tracking: ordered history of which hand dribbled last
      private var handHistory: [DribbleCalculator.HandSide] = []

      // MARK: - Session

      nonisolated func startSession(at startTime: Double) {
          DispatchQueue.main.async { [weak self] in
              self?.sessionStartTime = startTime
              self?.metrics = DribbleLiveMetrics()
              self?.dribbleTimestamps = []
              self?.leftState  = WristState()
              self?.rightState = WristState()
              self?.handHistory = []
          }
      }

      // MARK: - Frame Processing (call from ARSessionDelegate, background queue)

      nonisolated func processFrame(pixelBuffer: CVPixelBuffer,
                                    timestamp: Double) {
          let observations = handService.detectHands(pixelBuffer: pixelBuffer)
          var leftObs:  VNHumanHandPoseObservation? = nil
          var rightObs: VNHumanHandPoseObservation? = nil

          for obs in observations {
              if obs.chirality == .left  { leftObs  = obs }
              if obs.chirality == .right { rightObs = obs }
          }

          let leftWrist  = wristY(from: leftObs)
          let rightWrist = wristY(from: rightObs)

          var newLeftPos:  CGPoint? = nil
          var newRightPos: CGPoint? = nil

          if let lp = leftObs.flatMap({ try? $0.recognizedPoint(.wrist) }), lp.confidence > 0.3 {
              newLeftPos = CGPoint(x: lp.location.x, y: lp.location.y)
          }
          if let rp = rightObs.flatMap({ try? $0.recognizedPoint(.wrist) }), rp.confidence > 0.3 {
              newRightPos = CGPoint(x: rp.location.x, y: rp.location.y)
          }

          var leftDribble  = false
          var rightDribble = false

          if let y = leftWrist  { leftDribble  = leftState.update(y: y)  }
          if let y = rightWrist { rightDribble = rightState.update(y: y) }

          let t = timestamp - sessionStartTime

          DispatchQueue.main.async { [weak self] in
              guard let self else { return }
              if leftDribble {
                  self.metrics.totalDribbles     += 1
                  self.metrics.leftHandDribbles  += 1
                  self.metrics.lastActiveHand     = .left
                  self.handHistory.append(.left)
                  self.dribbleTimestamps.append(t)
              }
              if rightDribble {
                  self.metrics.totalDribbles     += 1
                  self.metrics.rightHandDribbles += 1
                  self.metrics.lastActiveHand     = .right
                  self.handHistory.append(.right)
                  self.dribbleTimestamps.append(t)
              }

              self.metrics.leftWristPosition  = newLeftPos
              self.metrics.rightWristPosition = newRightPos

              // Prune timestamps older than 3 seconds
              self.dribbleTimestamps = self.dribbleTimestamps.filter { t - $0 <= 3.0 }
              let currentBPS = Double(self.dribbleTimestamps.count) / 3.0
              self.metrics.currentBPS = currentBPS
              if currentBPS > self.metrics.maxBPS { self.metrics.maxBPS = currentBPS }

              self.metrics.combosDetected = DribbleCalculator.comboCount(
                  handHistory: self.handHistory)

              self.delegate?.pipeline(self, didUpdate: self.metrics)
          }
      }

      // MARK: - Helpers

      nonisolated private func wristY(from obs: VNHumanHandPoseObservation?) -> Double? {
          guard let obs,
                let wrist = try? obs.recognizedPoint(.wrist),
                wrist.confidence > 0.3 else { return nil }
          return Double(wrist.location.y)
      }
  }

  // MARK: - WristState

  /// Tracks wrist Y velocity to detect the upward turn at the bottom of a dribble.
  private struct WristState {
      private var previousY: Double?
      private var descendingFrames: Int = 0
      private var ascendingFrames:  Int = 0
      private let confirmFrames = HoopTrack.Dribble.velocityConfirmFrames

      /// Returns true when a dribble bounce is confirmed (wrist just turned upward
      /// after at least `confirmFrames` descending frames).
      mutating func update(y: Double) -> Bool {
          defer { previousY = y }
          guard let prev = previousY else { return false }

          let dy = y - prev  // positive = moving up in Vision coords

          if dy < 0 {
              // Descending
              descendingFrames += 1
              ascendingFrames   = 0
          } else if dy > 0 {
              // Ascending
              ascendingFrames += 1
              if ascendingFrames >= confirmFrames && descendingFrames >= confirmFrames {
                  // Confirmed bounce: reset and count
                  descendingFrames = 0
                  ascendingFrames  = 0
                  return true
              }
          }
          return false
      }
  }
  ```

- [ ] **Step 2: Build the project to confirm no compile errors**

  In Xcode: Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/Services/DribblePipeline.swift
  git commit -m "feat: add DribblePipeline — ARKit frame-based dribble detection state machine"
  ```

---

## Task 5: DribbleSessionViewModel

**Files:**
- Create: `HoopTrack/ViewModels/DribbleSessionViewModel.swift`

- [ ] **Step 1: Create DribbleSessionViewModel.swift**

  Create `HoopTrack/ViewModels/DribbleSessionViewModel.swift`:

  ```swift
  // HoopTrack/ViewModels/DribbleSessionViewModel.swift
  // Owns all state for a live dribble drill session.
  // Mirrors LiveSessionViewModel's lifecycle (start/pause/resume/end).

  import Foundation
  import Combine

  @MainActor
  final class DribbleSessionViewModel: ObservableObject, DribblePipelineDelegate {

      // MARK: - Published
      @Published var session: TrainingSession?
      @Published var elapsedSeconds: Double = 0
      @Published var isPaused: Bool = false
      @Published var isFinished: Bool = false
      @Published var isSaving: Bool = false
      @Published var errorMessage: String?
      @Published var liveMetrics = DribbleLiveMetrics()

      // MARK: - Computed HUD values
      var totalDribbles: Int    { liveMetrics.totalDribbles }
      var currentBPS: Double    { liveMetrics.currentBPS }
      var combosDetected: Int   { liveMetrics.combosDetected }

      var elapsedFormatted: String {
          let mins = Int(elapsedSeconds) / 60
          let secs = Int(elapsedSeconds) % 60
          return String(format: "%d:%02d", mins, secs)
      }

      // MARK: - Dependencies
      private var dataService: DataService!
      private var timerCancellable: AnyCancellable?

      init() {}

      init(dataService: DataService) {
          self.dataService = dataService
      }

      func configure(dataService: DataService) {
          self.dataService = dataService
      }

      // MARK: - Lifecycle

      func start(namedDrill: NamedDrill?) {
          do {
              session = try dataService.startSession(drillType: .dribble,
                                                     namedDrill: namedDrill)
              startTimer()
          } catch {
              errorMessage = error.localizedDescription
          }
      }

      func pause() {
          isPaused = true
          timerCancellable?.cancel()
      }

      func resume() {
          isPaused = false
          startTimer()
      }

      func endSession() {
          guard let session else { return }
          isSaving = true
          timerCancellable?.cancel()
          do {
              try dataService.finaliseDribbleSession(session, metrics: liveMetrics)
              isFinished = true
          } catch {
              errorMessage = error.localizedDescription
          }
          isSaving = false
      }

      // MARK: - DribblePipelineDelegate

      nonisolated func pipeline(_ pipeline: DribblePipeline,
                                didUpdate metrics: DribbleLiveMetrics) {
          // Already dispatched to main by DribblePipeline
          liveMetrics = metrics
      }

      // MARK: - Timer (private)

      private func startTimer() {
          timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
              .autoconnect()
              .sink { [weak self] _ in
                  guard let self, !self.isPaused else { return }
                  self.elapsedSeconds += 1
              }
      }
  }
  ```

- [ ] **Step 2: Build to confirm no compile errors**

  Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/ViewModels/DribbleSessionViewModel.swift
  git commit -m "feat: add DribbleSessionViewModel — lifecycle and DribblePipeline delegate"
  ```

---

## Task 6: DribbleDrillView

**Files:**
- Create: `HoopTrack/Views/Train/DribbleDrillView.swift`

- [ ] **Step 1: Create DribbleDrillView.swift**

  Create `HoopTrack/Views/Train/DribbleDrillView.swift`:

  ```swift
  // DribbleDrillView.swift
  // Full-screen ARKit session for dribble drills.
  // Phone is placed on the floor facing up; player stands above.
  //
  // ARView (RealityKit) handles camera display, horizontal plane detection,
  // and AR floor target anchors.
  // DribblePipeline processes ARKit frames via Vision hand tracking.

  import SwiftUI
  import RealityKit
  import ARKit
  import SwiftData

  struct DribbleDrillView: View {

      let namedDrill: NamedDrill?
      let onFinish: () -> Void

      @Environment(\.modelContext) private var modelContext

      @StateObject private var viewModel = DribbleSessionViewModel()

      @State private var arCoordinator: DribbleARCoordinator?
      @State private var pipeline      = DribblePipeline()

      @State private var isLongPressingEnd      = false
      @State private var endLongPressProgress: Double = 0
      @State private var endSessionTask: Task<Void, Never>?

      var body: some View {
          ZStack {
              // MARK: ARView (replaces CameraPreviewView for dribble sessions)
              DribbleARViewContainer(coordinator: $arCoordinator)
                  .ignoresSafeArea()

              // MARK: HUD
              VStack {
                  topHUD
                  Spacer()
                  bottomControls
              }
              .ignoresSafeArea(edges: .bottom)
          }
          .task {
              viewModel.configure(dataService: DataService(modelContext: modelContext))
              viewModel.start(namedDrill: namedDrill)

              // Wire pipeline → viewModel
              pipeline.delegate = viewModel

              // Give pipeline session start time
              pipeline.startSession(at: Date().timeIntervalSinceReferenceDate)

              // Give coordinator the pipeline for frame callbacks
              arCoordinator?.pipeline = pipeline
          }
          .onDisappear {
              arCoordinator?.stopSession()
          }
          .fullScreenCover(isPresented: $viewModel.isFinished) {
              if let session = viewModel.session {
                  DribbleSessionSummaryView(session: session) {
                      viewModel.isFinished = false
                      onFinish()
                  }
              }
          }
          .statusBarHidden(true)
      }

      // MARK: - Top HUD

      private var topHUD: some View {
          HStack(alignment: .top) {
              // Dribble count
              VStack(alignment: .leading, spacing: 2) {
                  Text("\(viewModel.totalDribbles)")
                      .font(.system(size: 36, weight: .black, design: .rounded))
                      .foregroundStyle(.white)
                      .shadow(radius: 4)
                  Text("dribbles")
                      .font(.subheadline)
                      .foregroundStyle(.white.opacity(0.8))
              }
              .padding(16)
              .background(.ultraThinMaterial.opacity(0.7),
                          in: RoundedRectangle(cornerRadius: 14, style: .continuous))

              Spacer()

              // BPS + timer
              VStack(alignment: .trailing, spacing: 2) {
                  Text(viewModel.elapsedFormatted)
                      .font(.system(size: 36, weight: .black, design: .monospaced))
                      .foregroundStyle(.white)
                      .shadow(radius: 4)
                  Text(String(format: "%.1f BPS", viewModel.currentBPS))
                      .font(.caption.bold())
                      .foregroundStyle(.yellow)
              }
              .padding(16)
              .background(.ultraThinMaterial.opacity(0.7),
                          in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          }
          .padding(.horizontal)
          .padding(.top, 12)
      }

      // MARK: - Bottom Controls

      private var bottomControls: some View {
          HStack(spacing: 16) {
              // Combo badge
              if viewModel.combosDetected > 0 {
                  Label("\(viewModel.combosDetected) combos", systemImage: "arrow.triangle.swap")
                      .font(.subheadline.bold())
                      .padding(.horizontal, 14)
                      .padding(.vertical, 8)
                      .background(.orange.opacity(0.85), in: Capsule())
                      .foregroundStyle(.white)
              }

              Spacer()

              // End Session (long press)
              Text(isLongPressingEnd ? "Hold…" : "End Session")
                  .font(.subheadline.bold())
                  .padding(.horizontal, 20)
                  .frame(height: 52)
                  .background(
                      ZStack(alignment: .leading) {
                          RoundedRectangle(cornerRadius: 26).fill(Color.red)
                          RoundedRectangle(cornerRadius: 26)
                              .fill(Color.white.opacity(0.25))
                              .frame(width: max(0, endLongPressProgress) * 160)
                              .animation(.linear(duration: 0.05), value: endLongPressProgress)
                      }
                      .clipShape(RoundedRectangle(cornerRadius: 26))
                  )
                  .foregroundStyle(.white)
                  .gesture(
                      DragGesture(minimumDistance: 0)
                          .onChanged { _ in
                              guard !isLongPressingEnd else { return }
                              isLongPressingEnd = true
                              endLongPressProgress = 0
                              withAnimation(.linear(duration: 1.5)) {
                                  endLongPressProgress = 1
                              }
                              endSessionTask = Task {
                                  try? await Task.sleep(nanoseconds: 1_500_000_000)
                                  guard !Task.isCancelled else { return }
                                  viewModel.endSession()
                              }
                          }
                          .onEnded { _ in
                              endSessionTask?.cancel()
                              endSessionTask = nil
                              isLongPressingEnd = false
                              withAnimation(.easeOut(duration: 0.2)) {
                                  endLongPressProgress = 0
                              }
                          }
                  )
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 16)
          .background(.black.opacity(0.4))
      }
  }

  // MARK: - ARView Container

  struct DribbleARViewContainer: UIViewRepresentable {

      @Binding var coordinator: DribbleARCoordinator?

      func makeUIView(context: Context) -> ARView {
          let arView = ARView(frame: .zero)
          let config = ARWorldTrackingConfiguration()
          config.planeDetection = [.horizontal]
          config.videoFormat    = ARWorldTrackingConfiguration
              .supportedVideoFormats
              .first(where: { $0.framesPerSecond >= 60 }) ?? ARWorldTrackingConfiguration
              .supportedVideoFormats[0]

          let c = DribbleARCoordinator(arView: arView)
          arView.session.delegate = c
          arView.session.run(config)
          DispatchQueue.main.async { self.coordinator = c }
          return arView
      }

      func updateUIView(_ uiView: ARView, context: Context) {}
  }

  // MARK: - AR Session Coordinator

  @MainActor
  final class DribbleARCoordinator: NSObject, ARSessionDelegate {

      private let arView: ARView
      var pipeline: DribblePipeline?

      /// Tracks whether we have placed the floor targets yet.
      private var targetsPlaced = false

      init(arView: ARView) {
          self.arView = arView
      }

      func stopSession() {
          arView.session.pause()
      }

      // MARK: ARSessionDelegate — frame processing

      nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
          guard let pipeline else { return }
          let timestamp = frame.timestamp
          let pixelBuffer = frame.capturedImage
          pipeline.processFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
      }

      // MARK: ARSessionDelegate — plane detection

      nonisolated func session(_ session: ARSession,
                               didAdd anchors: [ARAnchor]) {
          DispatchQueue.main.async { [weak self] in
              self?.placeTargetsIfNeeded(anchors: anchors)
          }
      }

      private func placeTargetsIfNeeded(anchors: [ARAnchor]) {
          guard !targetsPlaced else { return }
          guard let planeAnchor = anchors.compactMap({ $0 as? ARPlaneAnchor })
                                         .first(where: { $0.alignment == .horizontal }) else { return }
          targetsPlaced = true
          placeARTargets(on: planeAnchor)
      }

      private func placeARTargets(on planeAnchor: ARPlaneAnchor) {
          let count  = HoopTrack.Dribble.arTargetCount
          let radius = HoopTrack.Dribble.arTargetRadiusM
          // Spread targets in a line in front of the detected plane centre
          for i in 0 ..< count {
              let offsetX = Float(i - count / 2) * (radius * 3)
              let mesh     = MeshResource.generateCylinder(height: 0.005, radius: radius)
              let material = SimpleMaterial(color: .orange.withAlphaComponent(0.75),
                                            isMetallic: false)
              let entity   = ModelEntity(mesh: mesh, materials: [material])
              entity.position = SIMD3<Float>(planeAnchor.center.x + offsetX,
                                             0,
                                             planeAnchor.center.z)
              let anchor = AnchorEntity(anchor: planeAnchor)
              anchor.addChild(entity)
              arView.scene.addAnchor(anchor)
          }
      }
  }
  ```

- [ ] **Step 2: Build to confirm no compile errors**

  Product → Build (⌘B). Expected: Build Succeeded.
  
  **If you see `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` errors** on the `nonisolated` methods in `DribbleARCoordinator`, the `ARSessionDelegate` methods must be `nonisolated`. Verify the class is `@MainActor` and the delegate method signatures match exactly (the `nonisolated` prefix suppresses the isolation inheritance).

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/Views/Train/DribbleDrillView.swift
  git commit -m "feat: add DribbleDrillView with ARKit camera, floor targets, and dribble HUD"
  ```

---

## Task 7: DribbleSessionSummaryView

**Files:**
- Create: `HoopTrack/Views/Train/DribbleSessionSummaryView.swift`

- [ ] **Step 1: Create DribbleSessionSummaryView.swift**

  Create `HoopTrack/Views/Train/DribbleSessionSummaryView.swift`:

  ```swift
  // DribbleSessionSummaryView.swift
  // Post-session summary for dribble drills.
  // Shows total dribbles, average BPS, max BPS, hand balance, and combo count.

  import SwiftUI

  struct DribbleSessionSummaryView: View {

      let session: TrainingSession
      let onDismiss: () -> Void

      var body: some View {
          NavigationStack {
              ScrollView {
                  VStack(spacing: 24) {
                      drillHeader
                      statsGrid
                      handBalanceBar
                  }
                  .padding()
              }
              .navigationTitle("Drill Complete")
              .navigationBarTitleDisplayMode(.inline)
              .toolbar {
                  ToolbarItem(placement: .confirmationAction) {
                      Button("Done") { onDismiss() }
                  }
              }
          }
      }

      // MARK: - Drill Header

      private var drillHeader: some View {
          VStack(spacing: 6) {
              Image(systemName: "hand.point.up.fill")
                  .font(.system(size: 44))
                  .foregroundStyle(.orange)
              Text(session.namedDrill?.rawValue ?? "Dribble Drill")
                  .font(.title2.bold())
              Text(session.formattedDuration)
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
          }
          .padding(.top)
      }

      // MARK: - Stats Grid

      private var statsGrid: some View {
          StatCardGrid {
              StatCard(title: "Dribbles",
                       value: "\(session.totalDribbles ?? 0)")
              StatCard(title: "Avg BPS",
                       value: session.avgDribblesPerSec.map { String(format: "%.1f", $0) } ?? "—",
                       accent: bpsColor(session.avgDribblesPerSec))
              StatCard(title: "Max BPS",
                       value: session.maxDribblesPerSec.map { String(format: "%.1f", $0) } ?? "—",
                       accent: .orange)
              StatCard(title: "Combos",
                       value: "\(session.dribbleCombosDetected ?? 0)",
                       accent: .purple)
          }
      }

      // MARK: - Hand Balance Bar

      private var handBalanceBar: some View {
          VStack(alignment: .leading, spacing: 8) {
              Text("Hand Balance")
                  .font(.headline)

              if let balance = session.handBalanceFraction {
                  GeometryReader { geo in
                      HStack(spacing: 0) {
                          Rectangle()
                              .fill(Color.blue)
                              .frame(width: geo.size.width * balance)
                          Rectangle()
                              .fill(Color.green)
                              .frame(width: geo.size.width * (1 - balance))
                      }
                      .clipShape(Capsule())
                      .frame(height: 20)
                  }
                  .frame(height: 20)

                  HStack {
                      Label(String(format: "Left %.0f%%", balance * 100),
                            systemImage: "hand.raised.fill")
                          .font(.caption)
                          .foregroundStyle(.blue)
                      Spacer()
                      Label(String(format: "Right %.0f%%", (1 - balance) * 100),
                            systemImage: "hand.raised.fill")
                          .font(.caption)
                          .foregroundStyle(.green)
                          .environment(\.layoutDirection, .rightToLeft)
                  }
              } else {
                  Text("No hand data recorded")
                      .font(.caption)
                      .foregroundStyle(.secondary)
              }
          }
          .padding()
          .background(.ultraThinMaterial,
                      in: RoundedRectangle(cornerRadius: HoopTrack.UI.cornerRadius,
                                           style: .continuous))
      }

      private func bpsColor(_ bps: Double?) -> Color {
          guard let bps else { return .secondary }
          return bps >= HoopTrack.Dribble.optimalBPSMin
              && bps <= HoopTrack.Dribble.optimalBPSMax ? .green : .orange
      }
  }
  ```

- [ ] **Step 2: Build to confirm no compile errors**

  Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 3: Commit**

  ```bash
  git add HoopTrack/Views/Train/DribbleSessionSummaryView.swift
  git commit -m "feat: add DribbleSessionSummaryView with dribble stats and hand balance bar"
  ```

---

## Task 8: TrainTabView routing

**Files:**
- Modify: `HoopTrack/Views/Train/TrainTabView.swift`

- [ ] **Step 1: Add DribbleDrillView launch logic to TrainTabView**

  In `HoopTrack/Views/Train/TrainTabView.swift`, the `fullScreenCover` currently launches `LiveSessionView` for all drills. Replace it so dribble drills go to `DribbleDrillView`.

  Find the existing `fullScreenCover` block:

  ```swift
          // Full-screen live session
          .fullScreenCover(isPresented: $isShowingLiveSession) {
              LiveSessionView(
                  drillType: drillToLaunch?.drillType ?? .freeShoot,
                  namedDrill: drillToLaunch
              ) {
                  isShowingLiveSession = false
                  drillToLaunch        = nil
              }
          }
  ```

  Replace it with:

  ```swift
          // Full-screen live session — routes by drill type
          .fullScreenCover(isPresented: $isShowingLiveSession) {
              if drillToLaunch?.drillType == .dribble {
                  DribbleDrillView(namedDrill: drillToLaunch) {
                      isShowingLiveSession = false
                      drillToLaunch        = nil
                  }
              } else {
                  LiveSessionView(
                      drillType: drillToLaunch?.drillType ?? .freeShoot,
                      namedDrill: drillToLaunch
                  ) {
                      isShowingLiveSession = false
                      drillToLaunch        = nil
                  }
              }
          }
  ```

- [ ] **Step 2: Build to confirm no compile errors**

  Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 3: Run all tests**

  Product → Test (⌘U).
  Expected: all tests pass, including the new `DribbleCalculatorTests` suite.

- [ ] **Step 4: Commit**

  ```bash
  git add HoopTrack/Views/Train/TrainTabView.swift
  git commit -m "feat: route dribble drill types to DribbleDrillView in TrainTabView"
  ```

---

## Self-Review Checklist

### Spec coverage

| Spec requirement | Task |
|---|---|
| Front camera for dribble drills | Task 6 — `ARView` with `ARWorldTrackingConfiguration` |
| Hand tracking (left/right count and speed) | Task 2 `HandTrackingService` + Task 4 `DribblePipeline` |
| Dribble speed (BPS, max, avg) | Task 1 `DribbleCalculator` + Task 4 pipeline metrics |
| AR floor targets | Task 6 `DribbleARCoordinator.placeARTargets` |
| Combo detection (crossover) | Task 1 `comboCount` + Task 4 `handHistory` |
| Session metrics: total dribbles, drill time, accuracy | Task 3 `TrainingSession.applyDribbleMetrics` |
| `DrillType.dribble` → `NamedDrill.crossoverSeries` / `.twoBallDribble` | Task 8 routing |
| Ball-handling skill rating updated | Task 3 `updateBallHandlingRating` |
| Post-session dribble summary | Task 7 `DribbleSessionSummaryView` |

### Known limitations (Phase 5 candidates)
- "Accuracy %" for AR target activation is not implemented — targets are visual only; activation detection requires mapping Vision wrist image coords to ARKit world coords (complex raycasting).
- Two-Ball Dribble drill (`NamedDrill.twoBallDribble`) uses the same pipeline as Crossover Series; no simultaneous-hand dribble counting is differentiated.
- `DribbleDrillView` does not use `CameraService` — it bypasses `VideoRecordingService`, so dribble sessions have no replay video.
