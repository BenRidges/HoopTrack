# CV-C Ball Tracking Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pure-Swift Kalman-filter-based `BallTracker` that smooths per-frame ball detections and bridges 1–5 frame gaps. Integrate it into `CVPipeline` transparently — no downstream API changes.

**Architecture:** Pure `struct`s throughout. `Utilities/Kalman/` holds tiny matrix helpers. `Services/BallTracker.swift` is the public tracker. `CVPipeline` swaps its `PipelineState.tracking` associated value from `[BallDetection]` to `[BallTrackSample]` and consults the tracker each frame.

**Tech Stack:** Swift 6 strict concurrency, pure Swift matrix math (no Accelerate), XCTest. No new SPM deps.

**Spec:** [docs/superpowers/specs/2026-04-19-cv-c-tracking-design.md](../specs/2026-04-19-cv-c-tracking-design.md)

---

## File Structure

**New files:**
- `HoopTrack/Utilities/Kalman/KalmanMath.swift` — pure `Vector4`, `Matrix4x4`, `Matrix2x2`, `Matrix4x2` helpers
- `HoopTrack/Services/BallTracker.swift` — tracker state machine + Kalman core
- `HoopTrackTests/KalmanMathTests.swift`
- `HoopTrackTests/BallTrackerTests.swift`
- `HoopTrackTests/Fixtures/BallTrackerEval/.gitkeep`
- `HoopTrackTests/BallTrackerEvalTests.swift` — fixture-based, gated by `ENABLE_CV_EVAL=1`

**Modified:**
- `HoopTrack/Utilities/Constants.swift` — add `HoopTrack.Tracking` block
- `HoopTrack/Services/CVPipeline.swift` — consume `BallTrackSample` instead of raw `BallDetection`
- `HoopTrack/Services/ShotScienceCalculator.swift` — small adapter so it still accepts the upstream trajectory (see Task 10)

---

### Task 1: Constants — HoopTrack.Tracking

**Files:**
- Modify: `HoopTrack/Utilities/Constants.swift`

- [ ] **Step 1: Add the Tracking nested enum**

Open `HoopTrack/Utilities/Constants.swift`. After the existing `enum Storage { … }` block (around line 138–), add:

```swift
// MARK: - Ball Tracking (Phase CV-C)
enum Tracking {
    /// Process-noise scalar for the Kalman covariance. Larger = more reactive,
    /// smaller = smoother. Tuned so a 3-frame gap can be bridged without the
    /// predicted box drifting more than ~5% of frame width on a typical shot.
    static let processNoise: Double = 0.015

    /// Floor for measurement noise — detections with confidence 1.0 still get
    /// a small amount of noise so the filter doesn't collapse on perfect frames.
    static let measurementNoiseFloor: Double = 0.005

    /// Maximum number of consecutive frames the filter will run in
    /// predict-only mode before giving up. 5 ≈ 166 ms at 30 fps.
    static let maxPredictedFrames: Int = 5

    /// Max normalised-space distance between a predicted box centre and a new
    /// detection centre for them to be considered the same track. 0.08 ≈ 8% of frame width.
    static let associationDistance: Double = 0.08

    /// Minimum ML detection confidence required to start a brand-new track.
    static let minDetectConfidenceToStart: Float = 0.55
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/Constants.swift
git commit -m "feat(cv-c): add HoopTrack.Tracking constants block"
```

---

### Task 2: KalmanMath — test-first

**Files:**
- Create: `HoopTrackTests/KalmanMathTests.swift`
- Create: `HoopTrack/Utilities/Kalman/KalmanMath.swift`

- [ ] **Step 1: Write the failing tests**

Create `HoopTrackTests/KalmanMathTests.swift`:

```swift
import XCTest
@testable import HoopTrack

final class KalmanMathTests: XCTestCase {

    // MARK: - Matrix4x4

    func test_matrix4x4_identityMultiply_returnsOriginal() {
        let id = Matrix4x4.identity
        let m = Matrix4x4(rows: [
            [1, 2, 3, 4],
            [5, 6, 7, 8],
            [9, 1, 2, 3],
            [4, 5, 6, 7]
        ])
        let product = id.multiply(m)
        XCTAssertEqual(product, m)
    }

    func test_matrix4x4_transpose_swapsRowsAndColumns() {
        let m = Matrix4x4(rows: [
            [1, 2, 3, 4],
            [5, 6, 7, 8],
            [9, 10, 11, 12],
            [13, 14, 15, 16]
        ])
        let t = m.transpose
        XCTAssertEqual(t.value(row: 0, col: 0), 1)
        XCTAssertEqual(t.value(row: 0, col: 3), 13)
        XCTAssertEqual(t.value(row: 3, col: 0), 4)
        XCTAssertEqual(t.value(row: 3, col: 3), 16)
    }

    func test_matrix4x4_multiplyVector_appliesLinearTransform() {
        // Constant-velocity transition F with dt=1
        let F = Matrix4x4(rows: [
            [1, 0, 1, 0],
            [0, 1, 0, 1],
            [0, 0, 1, 0],
            [0, 0, 0, 1]
        ])
        let x = Vector4(0.5, 0.4, 0.1, -0.2)   // px, py, vx, vy
        let out = F.multiply(x)
        XCTAssertEqual(out.v0, 0.6, accuracy: 1e-9)  // 0.5 + 0.1
        XCTAssertEqual(out.v1, 0.2, accuracy: 1e-9)  // 0.4 - 0.2
        XCTAssertEqual(out.v2, 0.1, accuracy: 1e-9)
        XCTAssertEqual(out.v3, -0.2, accuracy: 1e-9)
    }

    // MARK: - Matrix2x2

    func test_matrix2x2_inverse_roundTrips() {
        let m = Matrix2x2(a: 4, b: 7, c: 2, d: 6)  // det = 4*6 - 7*2 = 10
        let inv = m.inverse!
        let product = m.multiply(inv)
        XCTAssertEqual(product.a, 1, accuracy: 1e-9)
        XCTAssertEqual(product.b, 0, accuracy: 1e-9)
        XCTAssertEqual(product.c, 0, accuracy: 1e-9)
        XCTAssertEqual(product.d, 1, accuracy: 1e-9)
    }

    func test_matrix2x2_inverse_singularReturnsNil() {
        let m = Matrix2x2(a: 1, b: 2, c: 2, d: 4)  // det = 0
        XCTAssertNil(m.inverse)
    }
}
```

- [ ] **Step 2: Run — expect failure (types don't exist)**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/KalmanMathTests -quiet 2>&1 | tail -10`
Expected: `error: cannot find 'Matrix4x4' in scope`

- [ ] **Step 3: Implement KalmanMath.swift**

Create `HoopTrack/Utilities/Kalman/KalmanMath.swift`:

```swift
// KalmanMath.swift
// Tiny pure-Swift matrix helpers for the 4D constant-velocity Kalman filter
// used by BallTracker. No Accelerate dependency — the matrices are small
// enough that SIMD setup overhead would cost more than the work itself.
// See docs/superpowers/specs/2026-04-19-cv-c-tracking-design.md §4.

import Foundation

nonisolated struct Vector4: Sendable, Equatable {
    var v0: Double
    var v1: Double
    var v2: Double
    var v3: Double
    init(_ a: Double, _ b: Double, _ c: Double, _ d: Double) {
        self.v0 = a; self.v1 = b; self.v2 = c; self.v3 = d
    }
    static let zero = Vector4(0, 0, 0, 0)
}

nonisolated struct Matrix4x4: Sendable, Equatable {
    /// Row-major, 4 rows × 4 cols.
    var m: [Double]   // always 16 entries

    init(rows: [[Double]]) {
        precondition(rows.count == 4 && rows.allSatisfy { $0.count == 4 })
        self.m = rows.flatMap { $0 }
    }

    static let identity = Matrix4x4(rows: [
        [1, 0, 0, 0],
        [0, 1, 0, 0],
        [0, 0, 1, 0],
        [0, 0, 0, 1]
    ])

    static func zero() -> Matrix4x4 { Matrix4x4(rows: Array(repeating: Array(repeating: 0.0, count: 4), count: 4)) }

    func value(row: Int, col: Int) -> Double { m[row * 4 + col] }

    var transpose: Matrix4x4 {
        var out = Matrix4x4.zero()
        for r in 0..<4 { for c in 0..<4 { out.m[c * 4 + r] = m[r * 4 + c] } }
        return out
    }

    func multiply(_ rhs: Matrix4x4) -> Matrix4x4 {
        var out = Matrix4x4.zero()
        for r in 0..<4 {
            for c in 0..<4 {
                var sum = 0.0
                for k in 0..<4 { sum += m[r * 4 + k] * rhs.m[k * 4 + c] }
                out.m[r * 4 + c] = sum
            }
        }
        return out
    }

    func multiply(_ v: Vector4) -> Vector4 {
        Vector4(
            m[0]  * v.v0 + m[1]  * v.v1 + m[2]  * v.v2 + m[3]  * v.v3,
            m[4]  * v.v0 + m[5]  * v.v1 + m[6]  * v.v2 + m[7]  * v.v3,
            m[8]  * v.v0 + m[9]  * v.v1 + m[10] * v.v2 + m[11] * v.v3,
            m[12] * v.v0 + m[13] * v.v1 + m[14] * v.v2 + m[15] * v.v3
        )
    }

    func add(_ rhs: Matrix4x4) -> Matrix4x4 {
        var out = self
        for i in 0..<16 { out.m[i] += rhs.m[i] }
        return out
    }

    func subtract(_ rhs: Matrix4x4) -> Matrix4x4 {
        var out = self
        for i in 0..<16 { out.m[i] -= rhs.m[i] }
        return out
    }
}

/// H matrix (position-only measurement): 2 rows × 4 cols.
nonisolated struct Matrix2x4: Sendable, Equatable {
    var m: [Double]   // 8 entries, row-major
    init(rows: [[Double]]) {
        precondition(rows.count == 2 && rows.allSatisfy { $0.count == 4 })
        self.m = rows.flatMap { $0 }
    }
    func multiplyVector(_ v: Vector4) -> (Double, Double) {
        (
            m[0] * v.v0 + m[1] * v.v1 + m[2] * v.v2 + m[3] * v.v3,
            m[4] * v.v0 + m[5] * v.v1 + m[6] * v.v2 + m[7] * v.v3
        )
    }
    /// Returns a 4×2 transpose suitable for H^T uses.
    var transpose: Matrix4x2 {
        Matrix4x2(m: [
            m[0], m[4],
            m[1], m[5],
            m[2], m[6],
            m[3], m[7]
        ])
    }
}

nonisolated struct Matrix4x2: Sendable, Equatable {
    var m: [Double]   // 8 entries, row-major (4 rows × 2 cols)
}

nonisolated struct Matrix2x2: Sendable, Equatable {
    var a: Double; var b: Double
    var c: Double; var d: Double

    var determinant: Double { a * d - b * c }

    var inverse: Matrix2x2? {
        let det = determinant
        guard abs(det) > 1e-12 else { return nil }
        let invDet = 1.0 / det
        return Matrix2x2(a:  d * invDet, b: -b * invDet,
                         c: -c * invDet, d:  a * invDet)
    }

    func multiply(_ rhs: Matrix2x2) -> Matrix2x2 {
        Matrix2x2(
            a: a * rhs.a + b * rhs.c, b: a * rhs.b + b * rhs.d,
            c: c * rhs.a + d * rhs.c, d: c * rhs.b + d * rhs.d
        )
    }
}
```

- [ ] **Step 4: Add the file to Xcode target membership**

The HoopTrack target auto-compiles `.swift` files under the `HoopTrack/` group, but the new `Utilities/Kalman/` subfolder is a fresh directory. Drag-and-drop the `Kalman/` folder into the Xcode project navigator under `HoopTrack/Utilities/`, ensuring **HoopTrack** target membership is checked. (The `Basketball-tracker/`-style Xcode sync might pick it up automatically; verify with the next build step.)

- [ ] **Step 5: Run — expect pass**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/KalmanMathTests -quiet 2>&1 | tail -5`
Expected: `Test Suite 'KalmanMathTests' passed`

- [ ] **Step 6: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/Kalman/KalmanMath.swift \
        HoopTrack/HoopTrackTests/KalmanMathTests.swift
git commit -m "feat(cv-c): pure-Swift Matrix/Vector helpers for Kalman filter"
```

---

### Task 3: BallTrackSample value type

**Files:**
- Create: `HoopTrack/Services/BallTracker.swift` (partial — value type only; tracker follows in Task 5)

- [ ] **Step 1: Create the file with only the sample type**

Create `HoopTrack/Services/BallTracker.swift`:

```swift
// BallTracker.swift
// Kalman-smoothed ball tracking layer. Sits between CoreMLBallDetector and
// CVPipeline; bridges short detection gaps so the pipeline's state machine
// survives 1–5 frame occlusions at release, peak, and rim entry.
//
// Owned by CVPipeline as a nonisolated(unsafe) struct on sessionQueue —
// identical pattern to the existing PipelineState ivar. See
// docs/superpowers/specs/2026-04-19-cv-c-tracking-design.md.

import AVFoundation
import CoreGraphics
import Foundation

// MARK: - BallTrackSample

nonisolated struct BallTrackSample: Sendable, Equatable, Codable {

    enum State: Sendable, Equatable, Codable {
        case noTrack
        case tracking
        case predicted(sinceFrames: Int)
        case lost
    }

    let state: State
    // `CGRect` is Codable in Foundation via bridged SwiftUI/CoreGraphics
    // conformances on iOS 16+. `CGVector` isn't, so we serialise velocity
    // as two Doubles and expose a computed `velocity` accessor.
    let box: CGRect
    let velocityDx: Double
    let velocityDy: Double
    let confidence: Double        // 0..1
    let timestampSeconds: Double  // CMTimeGetSeconds for Codable simplicity

    var velocity: CGVector { CGVector(dx: velocityDx, dy: velocityDy) }

    init(state: State, box: CGRect, velocity: CGVector,
         confidence: Double, timestampSeconds: Double) {
        self.state = state
        self.box = box
        self.velocityDx = velocity.dx
        self.velocityDy = velocity.dy
        self.confidence = confidence
        self.timestampSeconds = timestampSeconds
    }

    static let noTrack = BallTrackSample(
        state: .noTrack,
        box: .zero,
        velocity: .zero,
        confidence: 0,
        timestampSeconds: 0
    )
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Services/BallTracker.swift
git commit -m "feat(cv-c): add BallTrackSample value type"
```

---

### Task 4: BallTracker — Kalman core, test-first

**Files:**
- Create: `HoopTrackTests/BallTrackerTests.swift`
- Extend: `HoopTrack/Services/BallTracker.swift`

- [ ] **Step 1: Write the failing tests covering predict, update, and basic smoothing**

Create `HoopTrackTests/BallTrackerTests.swift`:

```swift
import XCTest
import AVFoundation
import CoreGraphics
@testable import HoopTrack

final class BallTrackerTests: XCTestCase {

    // MARK: - Helpers

    private func detection(cx: Double, cy: Double, size: Double = 0.05,
                           conf: Float = 0.9, timeSec: Double) -> BallDetection {
        let box = CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
        return BallDetection(
            boundingBox: box,
            confidence: conf,
            frameTimestamp: CMTime(seconds: timeSec, preferredTimescale: 600)
        )
    }

    private func ts(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    // MARK: - Initial state

    func test_initialState_isNoTrack() {
        let tracker = BallTracker()
        XCTAssertEqual(tracker.sample.state, .noTrack)
    }

    // MARK: - First detection

    func test_firstDetection_aboveMinConfidence_transitionsToTracking() {
        var tracker = BallTracker()
        let d = detection(cx: 0.5, cy: 0.5, timeSec: 0.0)
        let s = tracker.update(ball: d, timestamp: ts(0.0))
        XCTAssertEqual(s.state, .tracking)
        XCTAssertEqual(s.box.midX, 0.5, accuracy: 1e-6)
        XCTAssertEqual(s.box.midY, 0.5, accuracy: 1e-6)
    }

    func test_firstDetection_belowMinConfidence_staysNoTrack() {
        var tracker = BallTracker()
        let weak = detection(cx: 0.5, cy: 0.5, conf: 0.3, timeSec: 0.0)
        let s = tracker.update(ball: weak, timestamp: ts(0.0))
        XCTAssertEqual(s.state, .noTrack)
    }

    func test_nilDetectionWhileNoTrack_staysNoTrack() {
        var tracker = BallTracker()
        let s = tracker.update(ball: nil, timestamp: ts(0.0))
        XCTAssertEqual(s.state, .noTrack)
    }

    // MARK: - Predicted frames

    func test_missedFrameAfterTracking_transitionsToPredicted1() {
        var tracker = BallTracker()
        _ = tracker.update(ball: detection(cx: 0.5, cy: 0.5, timeSec: 0.00), timestamp: ts(0.00))
        _ = tracker.update(ball: detection(cx: 0.52, cy: 0.55, timeSec: 0.033), timestamp: ts(0.033))
        let s = tracker.update(ball: nil, timestamp: ts(0.066))
        guard case .predicted(let n) = s.state else {
            return XCTFail("expected .predicted, got \(s.state)")
        }
        XCTAssertEqual(n, 1)
    }

    func test_missedFramesBeyondLimit_transitionsToLost() {
        var tracker = BallTracker(maxPredictedFrames: 3)
        _ = tracker.update(ball: detection(cx: 0.5, cy: 0.5, timeSec: 0.00), timestamp: ts(0.00))
        _ = tracker.update(ball: detection(cx: 0.52, cy: 0.55, timeSec: 0.033), timestamp: ts(0.033))
        _ = tracker.update(ball: nil, timestamp: ts(0.066))   // predicted(1)
        _ = tracker.update(ball: nil, timestamp: ts(0.099))   // predicted(2)
        _ = tracker.update(ball: nil, timestamp: ts(0.132))   // predicted(3)
        let s = tracker.update(ball: nil, timestamp: ts(0.165))
        XCTAssertEqual(s.state, .lost)
    }

    // MARK: - Recovery

    func test_detectionInsideAssociationDistance_returnsToTracking() {
        var tracker = BallTracker()
        _ = tracker.update(ball: detection(cx: 0.5, cy: 0.5, timeSec: 0.00), timestamp: ts(0.00))
        _ = tracker.update(ball: detection(cx: 0.55, cy: 0.5, timeSec: 0.033), timestamp: ts(0.033))
        _ = tracker.update(ball: nil, timestamp: ts(0.066))

        // ball now around predicted ~0.60 @ t=0.099 — real detection within 2% of that
        let s = tracker.update(ball: detection(cx: 0.60, cy: 0.50, timeSec: 0.099), timestamp: ts(0.099))
        XCTAssertEqual(s.state, .tracking)
    }

    func test_detectionOutsideAssociationDistance_whileTracking_isRejected() {
        var tracker = BallTracker(associationDistance: 0.08)
        _ = tracker.update(ball: detection(cx: 0.5, cy: 0.5, timeSec: 0.00), timestamp: ts(0.00))
        _ = tracker.update(ball: detection(cx: 0.52, cy: 0.5, timeSec: 0.033), timestamp: ts(0.033))

        // New detection is at (0.9, 0.9) — far from where we predicted
        let far = detection(cx: 0.9, cy: 0.9, timeSec: 0.066)
        let s = tracker.update(ball: far, timestamp: ts(0.066))
        // Far detection is not associated; this frame is treated as "no ball"
        // so we transition to predicted.
        if case .predicted = s.state { /* ok */ }
        else { XCTFail("expected .predicted after far detection, got \(s.state)") }
    }

    // MARK: - Velocity

    func test_linearTrajectory_velocityConverges() {
        var tracker = BallTracker()
        // Ball moves right at 1.0 units/sec (e.g. 0.033 per frame at 30fps)
        var x = 0.2
        var t = 0.0
        var last = BallTrackSample.noTrack
        for _ in 0..<10 {
            last = tracker.update(ball: detection(cx: x, cy: 0.5, timeSec: t), timestamp: ts(t))
            x += 0.033
            t += 0.033
        }
        XCTAssertEqual(last.velocity.dx, 1.0, accuracy: 0.15)
        XCTAssertEqual(last.velocity.dy, 0.0, accuracy: 0.05)
    }

    // MARK: - Reset

    func test_reset_returnsToNoTrack() {
        var tracker = BallTracker()
        _ = tracker.update(ball: detection(cx: 0.5, cy: 0.5, timeSec: 0.00), timestamp: ts(0.00))
        tracker.reset()
        XCTAssertEqual(tracker.sample.state, .noTrack)
    }
}
```

- [ ] **Step 2: Run — expect failure (BallTracker not implemented)**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/BallTrackerTests -quiet 2>&1 | tail -10`
Expected: build errors referencing `BallTracker`.

- [ ] **Step 3: Implement BallTracker**

Append to `HoopTrack/Services/BallTracker.swift` (after the existing `BallTrackSample` definition):

```swift
// MARK: - BallTracker

nonisolated struct BallTracker: Sendable {

    // MARK: - Configuration
    let processNoise: Double
    let measurementNoiseFloor: Double
    let maxPredictedFrames: Int
    let associationDistance: Double
    let minDetectConfidenceToStart: Float

    // MARK: - Public state
    private(set) var sample: BallTrackSample

    // MARK: - Kalman state
    private var x: Vector4          // [px, py, vx, vy]
    private var P: Matrix4x4        // covariance
    private var lastTimestampSec: Double
    private var predictedFrameCount: Int
    private var lastBoxSize: CGSize

    // MARK: - Init
    init(processNoise: Double = HoopTrack.Tracking.processNoise,
         measurementNoiseFloor: Double = HoopTrack.Tracking.measurementNoiseFloor,
         maxPredictedFrames: Int = HoopTrack.Tracking.maxPredictedFrames,
         associationDistance: Double = HoopTrack.Tracking.associationDistance,
         minDetectConfidenceToStart: Float = HoopTrack.Tracking.minDetectConfidenceToStart) {
        self.processNoise = processNoise
        self.measurementNoiseFloor = measurementNoiseFloor
        self.maxPredictedFrames = maxPredictedFrames
        self.associationDistance = associationDistance
        self.minDetectConfidenceToStart = minDetectConfidenceToStart
        self.sample = .noTrack
        self.x = .zero
        self.P = Matrix4x4.identity
        self.lastTimestampSec = 0
        self.predictedFrameCount = 0
        self.lastBoxSize = .zero
    }

    // MARK: - Per-frame entry point
    mutating func update(ball: BallDetection?, timestamp: CMTime) -> BallTrackSample {
        let nowSec = CMTimeGetSeconds(timestamp)

        // Case A: currently noTrack or lost — only a strong new detection wakes us up.
        if sample.state == .noTrack || sample.state == .lost {
            guard let d = ball, d.confidence >= minDetectConfidenceToStart else {
                sample = BallTrackSample(state: .noTrack, box: .zero, velocity: .zero,
                                         confidence: 0, timestampSeconds: nowSec)
                return sample
            }
            initialise(with: d, nowSec: nowSec)
            return sample
        }

        // Case B: we have an active filter. Predict forward.
        let dt = max(1e-4, nowSec - lastTimestampSec)
        predict(dt: dt)

        // Try to associate the new detection to the predicted position.
        if let d = ball, isAssociable(d) {
            updateWithMeasurement(d, nowSec: nowSec)
        } else {
            predictedFrameCount += 1
            if predictedFrameCount > maxPredictedFrames {
                sample = BallTrackSample(
                    state: .lost,
                    box: sample.box,
                    velocity: sample.velocity,
                    confidence: 0,
                    timestampSeconds: nowSec
                )
            } else {
                sample = BallTrackSample(
                    state: .predicted(sinceFrames: predictedFrameCount),
                    box: boxFromState(),
                    velocity: CGVector(dx: x.v2, dy: x.v3),
                    confidence: max(0, sample.confidence - 0.15),
                    timestampSeconds: nowSec
                )
            }
        }

        lastTimestampSec = nowSec
        return sample
    }

    mutating func reset() {
        sample = .noTrack
        x = .zero
        P = Matrix4x4.identity
        lastTimestampSec = 0
        predictedFrameCount = 0
        lastBoxSize = .zero
    }

    // MARK: - Private

    private mutating func initialise(with d: BallDetection, nowSec: Double) {
        let cx = d.boundingBox.midX
        let cy = d.boundingBox.midY
        x = Vector4(cx, cy, 0, 0)
        // Start covariance modestly optimistic on position, wide on velocity.
        P = Matrix4x4(rows: [
            [processNoise, 0,            0,   0],
            [0,            processNoise, 0,   0],
            [0,            0,            1.0, 0],
            [0,            0,            0,   1.0]
        ])
        lastTimestampSec = nowSec
        predictedFrameCount = 0
        lastBoxSize = d.boundingBox.size
        sample = BallTrackSample(
            state: .tracking,
            box: d.boundingBox,
            velocity: .zero,
            confidence: Double(d.confidence),
            timestampSeconds: nowSec
        )
    }

    private mutating func predict(dt: Double) {
        let F = Matrix4x4(rows: [
            [1, 0, dt, 0],
            [0, 1, 0, dt],
            [0, 0, 1,  0],
            [0, 0, 0,  1]
        ])
        x = F.multiply(x)
        // P' = F P Fᵀ + Q (scalar process noise on the diagonal)
        let FP = F.multiply(P)
        var Pnext = FP.multiply(F.transpose)
        for i in 0..<4 { Pnext.m[i * 4 + i] += processNoise }
        P = Pnext
    }

    private func isAssociable(_ d: BallDetection) -> Bool {
        // Guard on detection confidence: anything below the start threshold
        // is too weak even for association in flight.
        guard d.confidence >= HoopTrack.Camera.ballDetectionConfidenceThreshold else { return false }
        let predCX = x.v0
        let predCY = x.v1
        let dx = d.boundingBox.midX - predCX
        let dy = d.boundingBox.midY - predCY
        let dist = (dx * dx + dy * dy).squareRoot()
        return dist <= associationDistance
    }

    private mutating func updateWithMeasurement(_ d: BallDetection, nowSec: Double) {
        let zx = Double(d.boundingBox.midX)
        let zy = Double(d.boundingBox.midY)

        // Measurement-noise R scales inversely with detection confidence.
        let r = max(measurementNoiseFloor,
                    measurementNoiseFloor * (2.0 - Double(d.confidence)))
        let R = Matrix2x2(a: r, b: 0, c: 0, d: r)

        // Innovation y = z - H x
        let yx = zx - x.v0
        let yy = zy - x.v1

        // S = H P Hᵀ + R  (H picks rows/cols 0 and 1 of P)
        let s00 = P.value(row: 0, col: 0) + R.a
        let s01 = P.value(row: 0, col: 1)
        let s10 = P.value(row: 1, col: 0)
        let s11 = P.value(row: 1, col: 1) + R.d
        let S = Matrix2x2(a: s00, b: s01, c: s10, d: s11)

        guard let Sinv = S.inverse else {
            // Non-invertible — skip update this frame, just roll prediction.
            predictedFrameCount += 1
            sample = BallTrackSample(
                state: .predicted(sinceFrames: predictedFrameCount),
                box: boxFromState(),
                velocity: CGVector(dx: x.v2, dy: x.v3),
                confidence: Double(d.confidence) * 0.5,
                timestampSeconds: nowSec
            )
            return
        }

        // K = P Hᵀ Sinv — because H is [I_2 | 0_2], P Hᵀ is columns 0..1 of P.
        // Build the 4×2 K matrix directly.
        var K = [Double](repeating: 0, count: 8)   // row-major 4×2
        for r in 0..<4 {
            let p0 = P.value(row: r, col: 0)
            let p1 = P.value(row: r, col: 1)
            K[r * 2 + 0] = p0 * Sinv.a + p1 * Sinv.c
            K[r * 2 + 1] = p0 * Sinv.b + p1 * Sinv.d
        }

        // x = x + K y
        x.v0 += K[0] * yx + K[1] * yy
        x.v1 += K[2] * yx + K[3] * yy
        x.v2 += K[4] * yx + K[5] * yy
        x.v3 += K[6] * yx + K[7] * yy

        // P = (I - K H) P — K H is a 4×4 matrix with columns 0..1 = K, columns 2..3 = 0
        var KH = Matrix4x4.zero()
        for r in 0..<4 {
            KH.m[r * 4 + 0] = K[r * 2 + 0]
            KH.m[r * 4 + 1] = K[r * 2 + 1]
        }
        let IminusKH = Matrix4x4.identity.subtract(KH)
        P = IminusKH.multiply(P)

        lastBoxSize = d.boundingBox.size
        predictedFrameCount = 0
        sample = BallTrackSample(
            state: .tracking,
            box: boxFromState(),
            velocity: CGVector(dx: x.v2, dy: x.v3),
            confidence: Double(d.confidence),
            timestampSeconds: nowSec
        )
    }

    private func boxFromState() -> CGRect {
        let w = lastBoxSize.width
        let h = lastBoxSize.height
        return CGRect(x: x.v0 - w / 2, y: x.v1 - h / 2, width: w, height: h)
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/BallTrackerTests -quiet 2>&1 | tail -5`
Expected: `Test Suite 'BallTrackerTests' passed`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Services/BallTracker.swift \
        HoopTrack/HoopTrackTests/BallTrackerTests.swift
git commit -m "feat(cv-c): BallTracker with constant-velocity Kalman core"
```

---

### Task 5: CVPipeline integration — migrate PipelineState

**Files:**
- Modify: `HoopTrack/Services/CVPipeline.swift`

No new unit tests. Integration is verified by the existing test suite continuing to pass plus manual QA in Task 9.

- [ ] **Step 1: Change the trajectory associated value**

Open `HoopTrack/Services/CVPipeline.swift`. Replace the `PipelineState` definition near the top:

```swift
private enum PipelineState: Sendable {
    case idle
    case tracking(trajectory: [BallTrackSample])
    case releaseDetected(releaseBox: CGRect, trajectory: [BallTrackSample])
}
```

- [ ] **Step 2: Add the tracker as pipeline state**

Inside `CVPipeline`, alongside the other `nonisolated(unsafe) private var` state (near the `pipelineState` declaration):

```swift
nonisolated(unsafe) private var tracker = BallTracker()
```

And extend `stop()` to reset it:

```swift
func stop() {
    frameCancellable?.cancel()
    frameCancellable = nil
    pipelineState = .idle
    tracker.reset()
}
```

- [ ] **Step 3: Rewrite `processBuffer` to consult the tracker**

Replace the body of `processBuffer(_:)` with:

```swift
private func processBuffer(_ buffer: CMSampleBuffer) {
    guard let scene = detector.detectScene(buffer: buffer) else { return }
    let now = scene.frameTimestamp

    calibration.updateBasket(scene.basket, timestamp: now)

    // Debug overlay: always use the RAW detection so what the user sees
    // matches what the ML model actually produced this frame.
    let overlayBox = scene.ball?.boundingBox
    let overlayConfidence = scene.ball?.confidence
    Task { @MainActor [weak viewModel] in
        viewModel?.updateBallDetection(box: overlayBox, confidence: overlayConfidence)
    }

    // Feed the detection (or lack thereof) to the Kalman tracker.
    let trackSample = tracker.update(ball: scene.ball, timestamp: now)

    // Shot detection requires a tracked (or recently-tracked) hoop rect.
    guard let hoopRect = calibration.state.hoopRect else { return }

    switch pipelineState {

    case .idle:
        if trackSample.state == .tracking {
            pipelineState = .tracking(trajectory: [trackSample])
        }

    case .tracking(var trajectory):
        switch trackSample.state {
        case .tracking, .predicted(_):
            trajectory.append(trackSample)

            if isAtPeak(trajectory: trajectory) {
                let releaseBox = trajectory.first!.box

                // Shot Science: feed only real measurement samples (no predicted-only).
                let science: ShotScienceMetrics?
                if let ps = poseService {
                    let observation = ps.detectPose(buffer: buffer)
                    let measuredTrajectory = trajectory
                        .filter { if case .tracking = $0.state { return true } else { return false } }
                        .map { $0.asBallDetection() }
                    science = ShotScienceCalculator.compute(
                        trajectory: measuredTrajectory,
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

        case .noTrack, .lost:
            pipelineState = .idle
        }

    case .releaseDetected(let releaseBox, _):
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, releaseTimestamp))

        // Use the smoothed box for entry/below checks on any live sample
        // (tracking or still-predicting). Once the tracker goes noTrack/lost,
        // fall through to the timeout branch.
        let isLive: Bool = {
            switch trackSample.state {
            case .tracking, .predicted(_): return true
            case .noTrack, .lost:          return false
            }
        }()
        if isLive {
            let probeBox = trackSample.box
            if isEnteringHoop(ballBox: probeBox, hoopRect: hoopRect) {
                resolveShot(result: .make, releaseBox: releaseBox)
                return
            }
            if isBelowHoop(ballBox: probeBox, hoopRect: hoopRect) {
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

- [ ] **Step 4: Update `isAtPeak` to accept `[BallTrackSample]`**

Replace the `isAtPeak` function:

```swift
private func isAtPeak(trajectory: [BallTrackSample]) -> Bool {
    guard trajectory.count >= 5 else { return false }
    let ys      = trajectory.suffix(5).map { $0.box.midY }
    let peak    = ys.max()!
    let current = ys.last!
    let first   = ys.first!
    let wasRising = peak - first   > 0.05
    let hasPeaked = peak - current > 0.03
    return wasRising && hasPeaked
}
```

`isEnteringHoop` and `isBelowHoop` already accept `CGRect` — no change needed.

- [ ] **Step 5: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -10`
Expected: `BUILD SUCCEEDED`. If failures reference `asBallDetection` (not added yet), continue to Task 6 before building.

- [ ] **Step 6: Commit**

```bash
git add HoopTrack/HoopTrack/Services/CVPipeline.swift
git commit -m "feat(cv-c): consume BallTracker samples inside CVPipeline"
```

---

### Task 6: BallTrackSample → BallDetection adapter

**Files:**
- Modify: `HoopTrack/Services/BallTracker.swift`

- [ ] **Step 1: Add the adapter method**

Append to `BallTrackSample` (inside its definition in `BallTracker.swift`, before the closing brace):

```swift
    /// Backwards-compat view for APIs still shaped around raw per-frame
    /// detections — specifically ShotScienceCalculator. Confidence is mapped
    /// through directly; timestamps are reconstructed from seconds.
    func asBallDetection() -> BallDetection {
        BallDetection(
            boundingBox: box,
            confidence: Float(confidence),
            frameTimestamp: CMTime(seconds: timestampSeconds, preferredTimescale: 600)
        )
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Services/BallTracker.swift
git commit -m "feat(cv-c): BallTrackSample.asBallDetection() adapter for ShotScience"
```

---

### Task 7: Run full test suite

**Files:** none

- [ ] **Step 1: Run all tests**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | grep -E "(Test Suite 'All tests'|failed|passed at)" | tail -5`
Expected: `Test Suite 'All tests' passed` + zero failures.

- [ ] **Step 2: If anything regressed, diagnose before proceeding**

The common breakage path is `ShotScienceCalculatorTests` — it passes `[BallDetection]` directly, which is unchanged, so the tests should pass. If they don't, check for typo'd import or target-membership problems on the new files.

Do not proceed to the eval-fixture task until the suite is green.

- [ ] **Step 3: Commit any small fixes inline with a conventional message**

Example:

```bash
git add <files>
git commit -m "fix(cv-c): <what was wrong>"
```

---

### Task 8: Eval-fixture scaffolding

**Files:**
- Create: `HoopTrackTests/Fixtures/BallTrackerEval/.gitkeep`
- Create: `HoopTrackTests/Fixtures/BallTrackerEval/README.md`
- Create: `HoopTrackTests/BallTrackerEvalTests.swift`

- [ ] **Step 1: Create the fixture folder and a placeholder README**

```bash
mkdir -p HoopTrack/HoopTrackTests/Fixtures/BallTrackerEval
touch HoopTrack/HoopTrackTests/Fixtures/BallTrackerEval/.gitkeep
```

Create `HoopTrack/HoopTrackTests/Fixtures/BallTrackerEval/README.md`:

```markdown
# BallTracker Eval Fixtures

Drop short `.mov` clips here alongside a `.json` sidecar with the same basename.

Sidecar format:

```json
{
  "fps": 30,
  "ground_truth": [
    { "frame_index": 12, "box_norm": [0.42, 0.55, 0.05, 0.05] },
    { "frame_index": 15, "box_norm": [0.46, 0.52, 0.05, 0.05] }
  ]
}
```

`box_norm` is `[x, y, width, height]` in Vision-normalised 0–1 coordinates.

These fixtures feed `BallTrackerEvalTests`. They are **not** run on every CI build — see the `ENABLE_CV_EVAL` env gate in that test file.

Initial seed: 3–5 clips hand-picked from dev recordings until CV-A telemetry delivers structured real data.
```

- [ ] **Step 2: Create the eval-test target file**

Create `HoopTrack/HoopTrackTests/BallTrackerEvalTests.swift`:

```swift
// BallTrackerEvalTests.swift
// Fixture-driven eval for BallTracker. Gated behind `ENABLE_CV_EVAL=1` so it
// does not run on default CI. Mirrors the pattern described in
// docs/upgrade-cv-detection.md Phase A7.

import XCTest
import AVFoundation
import CoreGraphics
@testable import HoopTrack

final class BallTrackerEvalTests: XCTestCase {

    private struct GroundTruthFrame: Decodable {
        let frame_index: Int
        let box_norm: [Double]
    }

    private struct Sidecar: Decodable {
        let fps: Double
        let ground_truth: [GroundTruthFrame]
    }

    override func setUpWithError() throws {
        let enabled = ProcessInfo.processInfo.environment["ENABLE_CV_EVAL"] == "1"
        try XCTSkipUnless(enabled, "Set ENABLE_CV_EVAL=1 to run the ball-tracker eval")
    }

    func test_trackingCoverage_onSeedFixtures() throws {
        let bundle = Bundle(for: Self.self)
        let fixtureURLs = (bundle.urls(forResourcesWithExtension: "json",
                                       subdirectory: "Fixtures/BallTrackerEval") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        try XCTSkipIf(fixtureURLs.isEmpty,
                      "No eval fixtures found under HoopTrackTests/Fixtures/BallTrackerEval/")

        for jsonURL in fixtureURLs {
            let data = try Data(contentsOf: jsonURL)
            let sidecar = try JSONDecoder().decode(Sidecar.self, from: data)
            let movURL = jsonURL.deletingPathExtension().appendingPathExtension("mov")
            guard FileManager.default.fileExists(atPath: movURL.path) else {
                XCTFail("Missing companion clip for \(jsonURL.lastPathComponent)")
                continue
            }

            // Drive the tracker over the ground-truth boxes as synthetic
            // detections, measuring position error. (Full video-decode eval
            // is a follow-up — this isolates the Kalman layer from the ML model.)
            var tracker = BallTracker()
            var errors: [Double] = []
            let dt = 1.0 / sidecar.fps
            for (i, gt) in sidecar.ground_truth.enumerated() {
                let t = Double(gt.frame_index) * dt
                let box = CGRect(x: gt.box_norm[0], y: gt.box_norm[1],
                                 width: gt.box_norm[2], height: gt.box_norm[3])
                let det = BallDetection(
                    boundingBox: box,
                    confidence: 0.9,
                    frameTimestamp: CMTime(seconds: t, preferredTimescale: 600)
                )
                // Simulate occlusion: drop every 4th frame after the first 3.
                let drop = (i > 2) && (i % 4 == 0)
                let s = tracker.update(ball: drop ? nil : det,
                                       timestamp: CMTime(seconds: t, preferredTimescale: 600))
                let dx = s.box.midX - box.midX
                let dy = s.box.midY - box.midY
                errors.append((dx * dx + dy * dy).squareRoot())
            }

            let meanErr = errors.reduce(0, +) / Double(errors.count)
            XCTAssertLessThan(meanErr, 0.05,
                              "Mean predicted-position error too high on \(jsonURL.lastPathComponent): \(meanErr)")
        }
    }
}
```

- [ ] **Step 3: Wire fixture-folder + README + test file into the test target**

In Xcode, drag `Fixtures/BallTrackerEval/` under the `HoopTrackTests` group. Ensure:
- The folder is added as a **Folder Reference** (blue icon), not a Group — this way future clips auto-enumerate via `bundle.urls(forResourcesWithExtension:subdirectory:)`.
- Target Membership = `HoopTrackTests` only.

For `BallTrackerEvalTests.swift`, target membership = `HoopTrackTests`.

- [ ] **Step 4: Run with the env var set to confirm the skip-on-missing-fixtures path works**

Run: `ENABLE_CV_EVAL=1 xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/BallTrackerEvalTests -quiet 2>&1 | tail -10`
Expected: one test skipped (no fixtures yet) OR passes if seed fixtures were already dropped in.

- [ ] **Step 5: Run without the env var to confirm the skip-by-default path**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/BallTrackerEvalTests -quiet 2>&1 | tail -10`
Expected: `BallTrackerEvalTests` skipped.

- [ ] **Step 6: Commit**

```bash
git add HoopTrack/HoopTrackTests/Fixtures/BallTrackerEval/ \
        HoopTrack/HoopTrackTests/BallTrackerEvalTests.swift
git commit -m "test(cv-c): scaffold on-demand BallTrackerEvalTests + fixture folder"
```

---

### Task 9: Manual device QA

**Files:** none.

- [ ] **Step 1: Deploy to a physical device**

iPhone SE 2 if available (represents the worst-case perf target). Otherwise any iPhone 12+.

- [ ] **Step 2: Walk through a free-shoot session**

1. Start a `Free Shoot` session from the Train tab.
2. Wait for the rim calibration to lock (green hoop outline).
3. Shoot 5 shots. For each, watch that:
   - The pipeline transitions to `releaseDetected` at the peak (court-position logging fires).
   - The shot resolves to `make` or `miss` within 2 s.
   - The detection overlay continues to show raw detection boxes (they should still flicker occasionally — the smoother is internal).
4. Look for regressions: any shot that used to work and now fails should be diagnosed before merging.

- [ ] **Step 3: Profile in Instruments (Time Profiler)**

Launch Instruments → Time Profiler. Attach to the HoopTrack process, start a Free Shoot session, collect ~30 s of data. Look for `BallTracker.update(ball:timestamp:)` in the call tree.

Expected: `BallTracker.update` p99 latency < 0.5 ms / call. If materially higher, capture a trace file and flag the issue before merging.

- [ ] **Step 4: Summarise findings in a commit**

If QA passes cleanly, commit an empty-scope marker so the phase has a clear end:

```bash
git commit --allow-empty -m "chore(cv-c): manual QA pass — tracker integrates cleanly on iPhone SE 2"
```

If QA surfaced any issues, fix them inline, then commit `fix(cv-c): <description>` and re-run Step 2–3 before the final commit.

---

### Task 10: Finish branch + push

**Files:** none.

- [ ] **Step 1: Run the full suite one more time**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | grep -E "(Test Suite 'All tests'|failed|passed at)" | tail -5`
Expected: all green.

- [ ] **Step 2: Push to origin**

```bash
git push origin main
```

- [ ] **Step 3: Update ROADMAP + production-readiness as a follow-up commit**

Open `docs/ROADMAP.md`. In the CV parallel-track table, mark **CV-C** status ✅ Complete and add a short "Completed Phases" style paragraph summarising:
- `BallTracker` + `KalmanMath` added under `Services/` and `Utilities/Kalman/`
- `CVPipeline` migrated to `[BallTrackSample]` trajectory
- Constants block `HoopTrack.Tracking`
- Eval fixture scaffolding (gated behind `ENABLE_CV_EVAL=1`)

Commit:

```bash
git add docs/ROADMAP.md
git commit -m "docs(roadmap): mark CV-C tracking layer complete"
git push origin main
```

---

## Notes for the Implementer

- **Read the spec first.** [docs/superpowers/specs/2026-04-19-cv-c-tracking-design.md](../specs/2026-04-19-cv-c-tracking-design.md) — especially §6 (lifecycle) and §7 (integration contract). The diff vs. current `CVPipeline` is larger than it looks.
- **`nonisolated(unsafe)` on the tracker ivar.** This is intentional and matches the existing `pipelineState` pattern in `CVPipeline`. The tracker is mutated only from the Combine sink closure that runs on `CameraService.sessionQueue`. Don't try to make it `@MainActor`.
- **No Accelerate.** The hand-rolled `Matrix4x4` is the right call at this scale. If a future phase decides otherwise, it should come with a benchmark showing measurable gain — not a "feels cleaner" argument.
- **Predicted boxes in the overlay.** `DetectionOverlay` still shows raw detections only. If a reviewer pushes for predicted-box rendering, defer to the spec §12 open question — the answer is "not in this phase."
- **ShotScience trajectory filter.** Task 5 Step 3 passes only `.tracking` samples to `ShotScienceCalculator`. This is deliberate — predicted-only frames have no real pose signal associated with them. If Shot Science consistency scores regress, revisit the filter, don't delete it.
- **Telemetry handoff.** When CV-A lands, the ring buffer there should capture `BallTrackSample` alongside `BallDetection`. That's CV-A's problem, not CV-C's — no work needed here beyond making `BallTrackSample` `Codable` (already done in Task 3).
