# Eliminate Build Warnings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive the Xcode warning count from 28 to 0 so that a clean build emits zero warnings, preparing the project for Swift 6 strict-concurrency mode.

**Architecture:** The vast majority of warnings come from a mismatch between the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting and the CV pipeline's legitimate need to run on a background queue. We will opt the CV-side types (CVPipeline and its collaborators) out of main-actor isolation by declaring them `nonisolated` at the type level and marking their value types `Sendable`. We will also fix one AVFoundation main-actor access in `CameraService.buildSession` and migrate the deprecated `HKWorkout` initialiser to `HKWorkoutBuilder`.

**Tech Stack:** Swift 5.10 / Swift 6 concurrency, AVFoundation, Vision, Combine, HealthKit, Xcode 16+, iOS 16+ deployment target.

---

## Warning Inventory (starting point)

Run `xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' clean build 2>&1 | grep warning: | sort -u` to confirm the baseline. Expect 28 distinct warnings clustered as:

| Cluster | File | Count | Root cause |
|---|---|---|---|
| CV pipeline actor isolation | `HoopTrack/Services/CVPipeline.swift` | 24 | `CVPipeline` inherits main-actor isolation by default; its `nonisolated` methods read/write main-actor state and call main-actor methods on `CourtCalibrationService`, `PoseEstimationService`, `BallDetectorProtocol`, `CourtZoneClassifier`, `ShotScienceCalculator`. |
| AVFoundation main-actor | `HoopTrack/Services/CameraService.swift` | 2 | `videoRotationAngle` and `CameraMode.==` touched from a `nonisolated` context. |
| HealthKit deprecation | `HoopTrack/Services/HealthKitService.swift` | 1 | `HKWorkout(activityType:start:end:duration:...)` deprecated in iOS 17 — migrate to `HKWorkoutBuilder`. |
| CameraMode Equatable | `HoopTrack/Services/CameraService.swift:74` | 1 | `CameraMode` has main-actor-isolated `Equatable` conformance because the enum lives in a `@MainActor` default file. |

Total: **28 distinct warnings → 0**.

---

## File Structure

### Files we will modify

1. **`HoopTrack/Models/Enums.swift`** — Mark `CameraMode` explicitly `nonisolated` so its implicit `Equatable` conformance is not main-actor-isolated.
2. **`HoopTrack/ML/BallDetectorProtocol.swift`** — Mark `BallDetection` `Sendable` and `BallDetectorProtocol` `Sendable` so the detector can be safely held by a `nonisolated` class.
3. **`HoopTrack/Services/CourtCalibrationService.swift`** — Mark the class `nonisolated` (it is stateful but is always invoked from the CV session queue — see Task 3 rationale).
4. **`HoopTrack/Services/PoseEstimationService.swift`** — Mark `nonisolated`, and `PoseObservation` `Sendable`.
5. **`HoopTrack/Utilities/CourtZoneClassifier.swift`** — Mark `nonisolated` (pure static function, no state).
6. **`HoopTrack/Utilities/ShotScienceCalculator.swift`** — Mark `nonisolated` (pure static function).
7. **`HoopTrack/Services/CVPipeline.swift`** — Declare the whole class `nonisolated`, remove per-method `nonisolated` qualifiers, and encapsulate mutable state access behind the Combine serial sink (frames already arrive serially on `sessionQueue`).
8. **`HoopTrack/Services/CameraService.swift`** — Fix `videoRotationAngle` access in `buildSession` (use `@preconcurrency` import already present plus an `MainActor.assumeIsolated` shim *only if needed*; otherwise hop via `Task { @MainActor in }`).
9. **`HoopTrack/Services/HealthKitService.swift`** — Rewrite `writeWorkout(for:)` using `HKWorkoutBuilder`.

### Files we will NOT modify

- `LiveSessionViewModel` — still `@MainActor`. The CV pipeline's `Task { @MainActor in ... }` hops remain the only entry point.
- `DataService`, `SessionFinalizationCoordinator`, UI views — untouched by this plan.

---

## Verification Strategy

Most warnings here are concurrency diagnostics that the Swift compiler produces at build time. Unit tests cannot detect the presence or absence of a warning — the verification gate is `xcodebuild`. Every task therefore ends in a build step whose expected output is a reduced warning count.

The baseline command used in every task:

```bash
xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' \
  clean build 2>&1 | grep -c "warning:"
```

This prints the total warning count. The task specifies the expected count after the change.

Unit tests should still pass throughout. Run the full suite at the end:

```bash
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14'
```

---

## Task 1: Record Baseline Warning Count

**Files:**
- None (observation only)

- [ ] **Step 1: Capture baseline warning set**

Run:
```bash
xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' \
  clean build 2>&1 | grep "warning:" | sort -u > /tmp/hooptrack-warnings-baseline.txt
wc -l /tmp/hooptrack-warnings-baseline.txt
```

Expected: `28 /tmp/hooptrack-warnings-baseline.txt`

If the number differs, investigate which warnings have been added or removed since this plan was written before proceeding — the plan's fix groupings may no longer match.

- [ ] **Step 2: Commit the baseline snapshot reference (optional)**

Do not commit `/tmp/...` paths. Note the count in the PR description instead. No commit in this task.

---

## Task 2: Mark `CameraMode` as `nonisolated` (+1 warning gone)

**Files:**
- Modify: `HoopTrack/Models/Enums.swift:163-166`

- [ ] **Step 1: Change the enum declaration**

Replace:

```swift
enum CameraMode {
    case rear    // Shot tracking (default)
    case front   // Dribble drills (front camera, phone on floor)
}
```

With:

```swift
enum CameraMode: Sendable {
    case rear    // Shot tracking (default)
    case front   // Dribble drills (front camera, phone on floor)
}
```

Rationale: a `Sendable` enum with no associated values automatically gets a non-isolated `Equatable` conformance, which lets `CameraService.buildSession` (nonisolated context) compare `mode == .rear` without tripping the isolation checker.

- [ ] **Step 2: Build and confirm the CameraMode Equatable warning is gone**

Run the baseline command. Expected: the warning `main actor-isolated conformance of 'CameraMode' to 'Equatable' cannot be used in nonisolated context` no longer appears.

Expected total count: **27**.

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/Models/Enums.swift
git commit -m "fix: make CameraMode Sendable to allow nonisolated comparison"
```

---

## Task 3: Mark CV-side value types `Sendable` (enables Task 4)

**Files:**
- Modify: `HoopTrack/ML/BallDetectorProtocol.swift`

- [ ] **Step 1: Update `BallDetection` and `BallDetectorProtocol`**

Replace the full file contents with:

```swift
// HoopTrack/ML/BallDetectorProtocol.swift
import AVFoundation
import CoreGraphics

/// A single ball detection result from one camera frame.
struct BallDetection: Sendable {
    /// Bounding box in Vision normalised coordinates: origin bottom-left, 0–1 range.
    let boundingBox: CGRect
    /// Model confidence score 0–1.
    let confidence: Float
    /// Presentation timestamp of the source frame, used for trajectory timing.
    let frameTimestamp: CMTime
}

/// Protocol that both the real Core ML wrapper and the debug stub conform to.
/// Kept on the background session queue — must NOT touch the main actor.
protocol BallDetectorProtocol: Sendable {
    func detect(buffer: CMSampleBuffer) -> BallDetection?
}
```

Rationale: `CVPipeline` will hold a `BallDetectorProtocol` as stored property. Once `CVPipeline` is `nonisolated`, that property must itself be `Sendable`. `CGRect`, `Float`, and `CMTime` are all already `Sendable`, so the composite struct trivially qualifies.

- [ ] **Step 2: Confirm all concrete detectors compile**

Run:
```bash
xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' \
  build 2>&1 | grep -E "(error:|warning:)" | sort -u
```

Expected: no new errors. If a concrete detector (e.g. `CoreMLBallDetector`, `StubBallDetector`) complains about non-`Sendable` stored properties, that detector must also be audited. Fix any new warnings before continuing.

Expected total count: **27** (unchanged — this is a prep task).

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/ML/BallDetectorProtocol.swift
git commit -m "refactor: mark BallDetection and BallDetectorProtocol Sendable"
```

---

## Task 4: Make `CourtZoneClassifier` and `ShotScienceCalculator` `nonisolated`

**Files:**
- Modify: `HoopTrack/Utilities/CourtZoneClassifier.swift`
- Modify: `HoopTrack/Utilities/ShotScienceCalculator.swift`

- [ ] **Step 1: Annotate `CourtZoneClassifier`**

Open `HoopTrack/Utilities/CourtZoneClassifier.swift` and change the type declaration line from:

```swift
enum CourtZoneClassifier {
```

to:

```swift
nonisolated enum CourtZoneClassifier {
```

If the type is currently `struct CourtZoneClassifier` or `final class CourtZoneClassifier`, prepend `nonisolated` to that declaration instead.

- [ ] **Step 2: Annotate `ShotScienceCalculator`**

Open `HoopTrack/Utilities/ShotScienceCalculator.swift` and apply the same `nonisolated` prefix to the type declaration. Mark `ShotScienceMetrics` (the return type) `Sendable` at its declaration:

```swift
struct ShotScienceMetrics: Sendable {
    // existing fields unchanged
}
```

All fields of `ShotScienceMetrics` should already be value types (`Double`, `CGFloat`, optional numeric). If one isn't, add `Sendable` to that nested type too.

- [ ] **Step 3: Build to confirm no regression**

Run the baseline command. Expected total count: **27** (still — these utilities aren't yet called from a nonisolated context that existed before; we are prepping for Task 6).

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/Utilities/CourtZoneClassifier.swift HoopTrack/Utilities/ShotScienceCalculator.swift
git commit -m "refactor: mark court/shot-science pure utilities nonisolated + Sendable"
```

---

## Task 5: Make `CourtCalibrationService` and `PoseEstimationService` `nonisolated`

**Files:**
- Modify: `HoopTrack/Services/CourtCalibrationService.swift:21`
- Modify: `HoopTrack/Services/PoseEstimationService.swift:8`

- [ ] **Step 1: Annotate `CourtCalibrationService`**

Change the class declaration at `HoopTrack/Services/CourtCalibrationService.swift:21` from:

```swift
final class CourtCalibrationService {
```

to:

```swift
nonisolated final class CourtCalibrationService {
```

Rationale: `CourtCalibrationService` is only used inside `CVPipeline.processBuffer` (which runs on `sessionQueue`) and via `onStateChange` (which we already documented as "fired on main thread"). All mutation of `state`, `candidates`, and the Vision request happens from the same serial queue. Swift's isolation checker doesn't understand runtime serial-queue guarantees, but marking the class `nonisolated` correctly expresses "not bound to the main actor" and the serialisation via `sessionQueue` keeps it data-race-free.

- [ ] **Step 2: Ensure the `onStateChange` callback hop is explicit**

Open `HoopTrack/Services/CourtCalibrationService.swift` and locate the `setState(_:)` helper (or wherever `onStateChange` is invoked). If the current invocation is a direct `onStateChange?(state)`, wrap it so the hop to main is explicit:

```swift
private func setState(_ newState: CalibrationState) {
    state = newState
    if let callback = onStateChange {
        Task { @MainActor in callback(newState) }
    }
}
```

`CalibrationState` must be `Sendable`. Add `Sendable` to its declaration at `HoopTrack/Services/CourtCalibrationService.swift:9`:

```swift
enum CalibrationState: Sendable {
    case uncalibrated
    case detecting
    case calibrated(hoopRect: CGRect)
    case failed(reason: String)
    // existing isCalibrated accessor unchanged
}
```

Also declare the callback explicitly `Sendable`:

```swift
var onStateChange: (@Sendable (CalibrationState) -> Void)?
```

- [ ] **Step 3: Annotate `PoseEstimationService`**

Change the class declaration at `HoopTrack/Services/PoseEstimationService.swift:8` from:

```swift
final class PoseEstimationService {
```

to:

```swift
nonisolated final class PoseEstimationService {
```

Open the file and confirm the return type of `detectPose(buffer:)` is `Sendable`. If it returns `VNHumanBodyPoseObservation` (Apple type), that type is already `Sendable` in SDKs that ship with Xcode 16+. If it returns a custom wrapper, add `Sendable` to that wrapper's declaration.

- [ ] **Step 4: Build**

Run the baseline command. Expected total count: **27** (CVPipeline still produces 24 warnings, CameraService 2 — CourtCalibration/Pose warnings bundled under CVPipeline will disappear in Task 6).

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/Services/CourtCalibrationService.swift HoopTrack/Services/PoseEstimationService.swift
git commit -m "refactor: mark CV services nonisolated for background-queue use"
```

---

## Task 6: Convert `CVPipeline` to a `nonisolated` class

**Files:**
- Modify: `HoopTrack/Services/CVPipeline.swift` (whole file)

This is the largest task. It eliminates the 24-warning CVPipeline cluster.

- [ ] **Step 1: Change the class declaration and drop per-method `nonisolated`**

At `HoopTrack/Services/CVPipeline.swift:21`, replace:

```swift
final class CVPipeline {
```

With:

```swift
nonisolated final class CVPipeline {
```

Then remove the word `nonisolated` from every method declaration that currently has it (`start`, `stop`, `processBuffer`, `isAtPeak`, `isEnteringHoop`, `isBelowHoop`, `logPendingShot`, `resolveShot`). The class-level `nonisolated` now applies to every member.

Also add `Sendable` conformance to the private state enum to satisfy the isolation checker on the stored property:

```swift
private enum PipelineState: Sendable {
    case idle
    case tracking(trajectory: [BallDetection])
    case releaseDetected(releaseBox: CGRect, trajectory: [BallDetection])
}
```

- [ ] **Step 2: Audit mutable stored properties for data-race safety**

The mutable stored properties are:
- `pipelineState: PipelineState`
- `frameCancellable: AnyCancellable?`
- `lastDetectionTimestamp: CMTime`
- `releaseTimestamp: CMTime`
- `viewModel: LiveSessionViewModel?` (weak)

All of these are mutated only inside `processBuffer` or the Combine `.sink` closure, both of which are driven by the serial `sessionQueue` that `CameraService` uses when delivering frames. That gives us serial access at runtime. The Swift 6 checker cannot prove this, however. Add `nonisolated(unsafe)` to each stored property to tell the compiler "I've checked — it's safe":

```swift
// MARK: - State
nonisolated(unsafe) private var pipelineState: PipelineState = .idle
nonisolated(unsafe) private var frameCancellable: AnyCancellable?

// Tracking: if no ball seen for 0.3s, return to IDLE
nonisolated(unsafe) private var lastDetectionTimestamp: CMTime = .zero
private let trackingTimeoutSec: Double = 0.3

// Release resolved: 2s timeout → MISS
nonisolated(unsafe) private var releaseTimestamp: CMTime = .zero
private let shotTimeoutSec: Double = 2.0
```

The weak `viewModel` reference is set once from `start(framePublisher:viewModel:)`, which is called from the main thread during view `.task`. Since it is a weak reference to a `@MainActor` class, mark it likewise:

```swift
nonisolated(unsafe) private weak var viewModel: LiveSessionViewModel?
```

The immutable `let detector`, `let calibration`, `let poseService` properties do not need annotation: now that they point to `Sendable`/`nonisolated` types (Tasks 3 + 5), they are fine on a `nonisolated` class.

- [ ] **Step 3: Keep the existing `Task { @MainActor in ... }` hops**

The existing hops at `logPendingShot` (line 180) and `resolveShot` (line 192) are already correct. Do not change them. The pipeline continues to call the view-model on the main actor; only the CV-side work is now officially off-main.

- [ ] **Step 4: Build and confirm the CVPipeline cluster is gone**

Run the baseline command. Expected total count: **3** (the 24 CVPipeline warnings are gone; 2 CameraService warnings and 1 HealthKit warning remain).

If any CVPipeline warning remains, re-read the warning text — it will name a specific property or method that still needs `nonisolated(unsafe)` or `Sendable`.

- [ ] **Step 5: Run the test suite**

```bash
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14'
```

Expected: all existing tests pass. No CV tests exist, but the `ShotScienceCalculatorTests` and `CourtZoneClassifierTests` touch the now-`nonisolated` utilities and must continue to compile and pass.

- [ ] **Step 6: Commit**

```bash
git add HoopTrack/Services/CVPipeline.swift
git commit -m "refactor(cv): make CVPipeline nonisolated to run off main thread cleanly"
```

---

## Task 7: Fix `CameraService.buildSession` `videoRotationAngle` warning

**Files:**
- Modify: `HoopTrack/Services/CameraService.swift:101-107`

- [ ] **Step 1: Inspect the warning**

The warning is: `main actor-isolated property 'videoRotationAngle' can not be referenced from a nonisolated context` at line 103. This is because `AVCaptureConnection.videoRotationAngle` is declared `@MainActor` in the Xcode 16+ SDK, but `buildSession` is called on `sessionQueue` (explicitly `nonisolated`).

The correct fix: `videoRotationAngle` is actually safe to set from any queue on a connection that is part of a session currently being configured (we hold `beginConfiguration/commitConfiguration`). We can tell the compiler this with `MainActor.assumeIsolated` — but that would block the session queue on main. A better fix is to set the rotation angle on the main actor after `commitConfiguration` returns.

- [ ] **Step 2: Replace the rotation block with an async hop**

At `HoopTrack/Services/CameraService.swift:101-107`, replace:

```swift
        // Set video rotation for the requested orientation
        if let connection = videoOutput.connection(with: .video) {
            let angle = orientation.videoRotationAngle
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }
```

With:

```swift
        // Rotation must be applied on the main actor (SDK isolation). Safe to
        // schedule post-commit: frame delivery is still paused until capture
        // resumes, and the rotation applies to all subsequent frames.
        let targetAngle = orientation.videoRotationAngle
        let connection = videoOutput.connection(with: .video)
        Task { @MainActor in
            if let connection, connection.isVideoRotationAngleSupported(targetAngle) {
                connection.videoRotationAngle = targetAngle
            }
        }
    }
```

The `connection` capture is safe because `AVCaptureConnection` conforms to `Sendable` in the `@preconcurrency import AVFoundation` context already declared at the top of this file.

- [ ] **Step 3: Build to confirm the CameraService warnings are gone**

Run the baseline command. Expected total count: **1** (only the HealthKit deprecation warning remains).

If the `CameraMode` conformance warning is still present, verify Task 2 was committed; the warning should have disappeared there.

- [ ] **Step 4: Manual smoke (optional but recommended)**

If the iPhone 14 simulator is available, launch the app and open the Train tab → Free Shoot. Verify the camera preview appears in landscape orientation. No behavioural change is expected.

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/Services/CameraService.swift
git commit -m "fix: apply AVCaptureConnection rotation on main actor"
```

---

## Task 8: Migrate `HealthKitService` from `HKWorkout` init to `HKWorkoutBuilder`

**Files:**
- Modify: `HoopTrack/Services/HealthKitService.swift` (whole file)

`HKWorkout.init(activityType:start:end:duration:totalEnergyBurned:totalDistance:metadata:)` was deprecated in iOS 17 in favour of `HKWorkoutBuilder`, which lets the system compute duration and supports adding samples.

- [ ] **Step 1: Replace the service implementation**

Replace the full contents of `HoopTrack/Services/HealthKitService.swift` with:

```swift
// HealthKitService.swift
import Foundation
import HealthKit

@MainActor final class HealthKitService: HealthKitServiceProtocol {

    private let store = HKHealthStore()

    func requestPermission() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
    }

    func writeWorkout(for session: TrainingSession) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else { return }
        guard let endedAt = session.endedAt else { return }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .basketball

        let builder = HKWorkoutBuilder(healthStore: store,
                                        configuration: configuration,
                                        device: .local())

        try await builder.beginCollection(at: session.startedAt)
        try await builder.endCollection(at: endedAt)
        _ = try await builder.finishWorkout()
    }
}
```

Notes:
- `HKWorkoutBuilder.beginCollection(at:)` and `endCollection(at:)` replace the explicit `start`/`end`/`duration` arguments.
- We do not add distance or energy samples in this version — the old init also passed `nil` for both, so behaviour is preserved.
- `finishWorkout()` returns `HKWorkout?`; the `_ =` discards it as before.

- [ ] **Step 2: Build to confirm the deprecation warning is gone**

Run the baseline command. Expected total count: **0**.

- [ ] **Step 3: Run the test suite**

```bash
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14'
```

Expected: all tests pass. `HealthKitService` has no direct unit-test coverage (it is not a pure function), so no test changes are needed.

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/Services/HealthKitService.swift
git commit -m "refactor(healthkit): migrate HKWorkout init to HKWorkoutBuilder"
```

---

## Task 9: Final Verification and Regression Sweep

**Files:**
- None (verification only)

- [ ] **Step 1: Clean build, zero warnings**

```bash
xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' \
  clean build 2>&1 | grep -c "warning:"
```

Expected: `0`

- [ ] **Step 2: Full test suite passes**

```bash
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: Manual smoke of the CV pipeline**

Launch the app on the iPhone 14 simulator. Open Train → Free Shoot. Confirm:
- The camera preview appears in landscape.
- The calibration overlay shows "Aim at the hoop" (the simulator has no real camera, so calibration will remain in the detecting state — that is expected).
- Manual make/miss buttons are tappable and the sidebar FG% updates.
- The "End Session" hold-button ends the session and navigates to the summary.

If any of these regress, the pipeline's main-actor hops may have been lost — revisit Task 6 Step 3.

- [ ] **Step 4: Dispatch `cv-pipeline-reviewer` subagent**

CLAUDE.md designates a dedicated `cv-pipeline-reviewer` agent for CV pipeline changes. Dispatch it with the diff from Task 6 in scope:

```
Review the Task 6 changes to HoopTrack/Services/CVPipeline.swift,
HoopTrack/Services/CourtCalibrationService.swift,
HoopTrack/Services/PoseEstimationService.swift, and
HoopTrack/ML/BallDetectorProtocol.swift for concurrency correctness,
memory safety, and pipeline contract compliance. Flag any CRITICAL
or HIGH findings.
```

If the reviewer raises CRITICAL/HIGH findings, fix them before merging.

- [ ] **Step 5: Final commit and PR**

Use the `superpowers:finishing-a-development-branch` skill to open the merge PR. PR description should link back to this plan and include the before/after warning counts (28 → 0).

---

## Risk Notes

**`nonisolated(unsafe)` in Task 6.** This is a deliberate escape hatch. The runtime safety argument is: `CameraService.framePublisher` is a `PassthroughSubject` whose `send` is invoked from `sessionQueue`, which is serial. Combine delivers values to sinks synchronously on the same thread that called `send`. Therefore every mutation of `pipelineState`, `lastDetectionTimestamp`, and `releaseTimestamp` happens on `sessionQueue` and cannot race. If future work adds a second frame source (e.g. a parallel ML pipeline), this invariant breaks and the state must be wrapped in an actor or a custom serial executor. Leave a comment at the top of `CVPipeline` recording this assumption.

**CameraService rotation hop in Task 7.** Dispatching rotation to the main actor introduces a one-frame window where the first frames after configuration use the previous rotation. Given `configureSession` is only called during view `.task` (before the preview is visible), this is invisible in practice.

**HealthKitBuilder behaviour in Task 8.** `HKWorkoutBuilder.finishWorkout` computes duration from `beginCollection`/`endCollection` timestamps rather than from an explicit duration argument. `TrainingSession.durationSeconds` is passed implicitly by the `(startedAt, endedAt)` pair, so the saved workout's duration equals `endedAt - startedAt` exactly, matching the old behaviour.

---

## Self-Review Summary

- **Spec coverage:** All four warning clusters from the inventory are addressed (Tasks 2 / 6 / 7 / 8 cover them). Preparation Tasks 3–5 are prerequisites for Task 6.
- **Placeholder scan:** No "TBD" or "handle edge cases" language; every code change is shown in full.
- **Type consistency:** `CameraMode: Sendable`, `BallDetection: Sendable`, `BallDetectorProtocol: Sendable`, `PipelineState: Sendable`, `CalibrationState: Sendable` — all referenced consistently between tasks.
