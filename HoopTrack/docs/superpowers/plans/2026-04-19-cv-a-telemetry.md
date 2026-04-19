# CV-A Telemetry Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture real HoopTrack footage + per-frame detection metadata from every session and upload it (Wi-Fi only) to a private Supabase Storage bucket so the offline autolabel pipeline can assemble training data for the next `BallDetector` retrain.

**Architecture:** During the live session, a lightweight `DetectionLogger` owned by `CVPipeline` writes one JSONL line per frame to `Documents/Telemetry/<sessionID>/detections.jsonl` — zero main-actor hops, zero frame-rate impact. At session finalization (new step 10 in `SessionFinalizationCoordinator`), a `TelemetryCaptureService` reads the JSONL, applies `FrameSampler` trigger rules, extracts JPEGs from the already-recorded `.mov` via `AVAssetImageGenerator`, writes a `manifest.json`, and creates a `TelemetryUpload` `@Model` row. A `TelemetryUploadService` then uploads the session directory to Supabase Storage on Wi-Fi, using a dedicated `URLSessionConfiguration` with `allowsCellularAccess = false`. On success the local directory is deleted.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Combine, AVFoundation (`AVAssetImageGenerator`), Vision (existing), Supabase Storage product (already linked, add `import Storage`). One new SPM product to wire — no new dependencies.

---

## File structure

### New files
- `HoopTrack/Models/TelemetryUpload.swift` — `@Model`, upload-lifecycle row
- `HoopTrack/Utilities/FrameSampler.swift` — pure sampling logic (TDD)
- `HoopTrack/Utilities/DetectionLogEntry.swift` — `Codable` per-frame record
- `HoopTrack/Services/DetectionLogger.swift` — live-session JSONL writer
- `HoopTrack/Services/TelemetryCaptureService.swift` — post-session frame extractor
- `HoopTrack/Services/TelemetryUploadService.swift` — Wi-Fi-only Supabase Storage uploader
- `HoopTrackTests/FrameSamplerTests.swift` — pure logic TDD
- `HoopTrackTests/DetectionLogEntryTests.swift` — JSONL round-trip
- `HoopTrackTests/TelemetryUploadStateTests.swift` — state-machine transitions
- `HoopTrackTests/TelemetryUploadModelTests.swift` — SwiftData smoke test

### Modified files
- `HoopTrack/Utilities/Constants.swift` — new `HoopTrack.Telemetry` block, `SessionKind` + `UploadState` enums extended
- `HoopTrack/Models/Enums.swift` — add `UploadState`, `SessionKind`
- `HoopTrack/HoopTrackApp.swift` — register `TelemetryUpload.self` with `ModelContainer`
- `HoopTrack/Services/CVPipeline.swift` — hook optional `DetectionLogger` into frame processing
- `HoopTrack/Services/SessionFinalizationCoordinator.swift` — inject telemetry services + call new step 10 from both `finalise*` entry points
- `HoopTrack/CoordinatorHost.swift` (or wherever coordinator is constructed) — wire telemetry services
- `HoopTrack/Auth/SupabaseClient+Shared.swift` — add `storage()` accessor

### Supabase side (SQL applied via MCP or Studio)
- Create private bucket `telemetry-sessions`
- Apply INSERT RLS policy (allow writes under own `user_id` folder only)

---

### Task 1: Enums — `UploadState` and `SessionKind`

**Files:**
- Modify: `HoopTrack/HoopTrack/Models/Enums.swift`

- [ ] **Step 1: Append the two enums to `Enums.swift`**

Open `HoopTrack/HoopTrack/Models/Enums.swift`. At the end of the file add:

```swift
// MARK: - Telemetry (CV-A)

/// Lifecycle of a telemetry upload for one session. Used by `TelemetryUpload.state`.
enum UploadState: String, Codable {
    case pending
    case uploading
    case uploaded
    case failed
    case abandoned
}

/// Which session model the telemetry row refers to. Avoids a table split
/// when looking back at the original session.
enum SessionKind: String, Codable {
    case training
    case game
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Models/Enums.swift
git commit -m "feat(cv-a): add UploadState and SessionKind enums"
```

---

### Task 2: Constants — `HoopTrack.Telemetry`

**Files:**
- Modify: `HoopTrack/HoopTrack/Utilities/Constants.swift`

- [ ] **Step 1: Add nested enum after the existing `Game` block**

Find the existing `enum Game { ... }` block inside `HoopTrack`. Add below it:

```swift
    // MARK: - Telemetry (CV-A)
    enum Telemetry {
        // Sampling
        static let baselineSampleFPS: Double = 1.0
        static let aroundShotPreFrames: Int = 10
        static let aroundShotPostFrames: Int = 10
        static let flickerThresholdHigh: Double = 0.6
        static let flickerThresholdLow: Double = 0.3
        static let flickerMinConsecutiveFrames: Int = 3
        static let boundaryFrames: Int = 5

        // Caps
        static let maxFramesPerSession: Int = 1000
        static let frameMaxLongestEdgePx: Int = 960
        static let frameJpegQuality: CGFloat = 0.7

        // Session eligibility
        static let minSessionDurationSec: Double = 30.0

        // Upload
        static let maxUploadAttempts: Int = 5
        static let concurrentFrameUploads: Int = 4
        static let uploadRequestTimeoutSec: TimeInterval = 60

        // Paths
        static let telemetryDirectoryName = "Telemetry"
        static let supabaseBucketName = "telemetry-sessions"

        // Dataset targets — informational, used by future dev tooling.
        // Not enforced at runtime.
        static let retrainTargetFrames: Int = 2000
        static let retrainTargetSessions: Int = 10
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/Constants.swift
git commit -m "feat(cv-a): add HoopTrack.Telemetry constants block"
```

---

### Task 3: `DetectionLogEntry` Codable — TDD

**Files:**
- Create: `HoopTrack/HoopTrackTests/DetectionLogEntryTests.swift`
- Create: `HoopTrack/HoopTrack/Utilities/DetectionLogEntry.swift`

- [ ] **Step 1: Write the failing tests**

Write `HoopTrack/HoopTrackTests/DetectionLogEntryTests.swift`:

```swift
import XCTest
@testable import HoopTrack

final class DetectionLogEntryTests: XCTestCase {

    func test_fullEntry_roundTripsThroughJSON() throws {
        let entry = DetectionLogEntry(
            timestampSec: 12.345,
            ballConfidence: 0.82,
            ballBox: [0.41, 0.62, 0.08, 0.09],
            rimConfidence: 0.91,
            rimBox: [0.45, 0.10, 0.12, 0.06],
            state: "tracking"
        )
        let line = try entry.jsonLine()
        let decoded = try DetectionLogEntry.decode(jsonLine: line)
        XCTAssertEqual(decoded.timestampSec, 12.345, accuracy: 1e-6)
        XCTAssertEqual(decoded.ballConfidence, 0.82, accuracy: 1e-6)
        XCTAssertEqual(decoded.ballBox, [0.41, 0.62, 0.08, 0.09])
        XCTAssertEqual(decoded.rimConfidence, 0.91, accuracy: 1e-6)
        XCTAssertEqual(decoded.rimBox, [0.45, 0.10, 0.12, 0.06])
        XCTAssertEqual(decoded.state, "tracking")
    }

    func test_entryWithoutBallDetection_encodesNulls() throws {
        let entry = DetectionLogEntry(
            timestampSec: 5.0,
            ballConfidence: nil,
            ballBox: nil,
            rimConfidence: 0.9,
            rimBox: [0.45, 0.10, 0.12, 0.06],
            state: "idle"
        )
        let line = try entry.jsonLine()
        let decoded = try DetectionLogEntry.decode(jsonLine: line)
        XCTAssertNil(decoded.ballConfidence)
        XCTAssertNil(decoded.ballBox)
        XCTAssertEqual(decoded.state, "idle")
    }

    func test_jsonLine_terminatesWithNewline() throws {
        let entry = DetectionLogEntry(
            timestampSec: 0.0,
            ballConfidence: nil,
            ballBox: nil,
            rimConfidence: nil,
            rimBox: nil,
            state: "idle"
        )
        let line = try entry.jsonLine()
        XCTAssertTrue(line.hasSuffix("\n"))
    }

    func test_decode_rejectsMalformedLine() {
        XCTAssertThrowsError(try DetectionLogEntry.decode(jsonLine: "{not valid json"))
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/DetectionLogEntryTests -quiet 2>&1 | tail -5`
Expected: `error: cannot find 'DetectionLogEntry' in scope`

- [ ] **Step 3: Create the type**

Write `HoopTrack/HoopTrack/Utilities/DetectionLogEntry.swift`:

```swift
// DetectionLogEntry.swift
// One line of detections.jsonl — the per-frame metadata written by
// DetectionLogger during a live session and read back post-session by
// TelemetryCaptureService to find sampling-worthy timestamps.

import Foundation

struct DetectionLogEntry: Codable, Sendable, Equatable {
    /// Seconds since session start (aligned to recorded .mov timeline).
    let timestampSec: Double

    /// Ball detection confidence 0–1; nil when no ball detected.
    let ballConfidence: Double?

    /// Ball bbox normalized [x, y, w, h]; nil when no ball.
    let ballBox: [Double]?

    /// Rim detection confidence; nil when no rim lock.
    let rimConfidence: Double?

    /// Rim bbox normalized; nil when no rim.
    let rimBox: [Double]?

    /// CVPipeline state at the frame.
    let state: String

    enum CodingKeys: String, CodingKey {
        case timestampSec   = "t"
        case ballConfidence = "ci"
        case ballBox        = "bb"
        case rimConfidence  = "ri"
        case rimBox         = "rb"
        case state          = "st"
    }

    /// Encode as a single-line JSON terminated with `\n`. Safe to append
    /// directly to a FileHandle.
    func jsonLine() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let s = String(data: data, encoding: .utf8) else {
            throw DetectionLogEntryError.encodingFailed
        }
        return s + "\n"
    }

    /// Decode a single line (with or without trailing newline).
    static func decode(jsonLine: String) throws -> DetectionLogEntry {
        let trimmed = jsonLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw DetectionLogEntryError.decodingFailed
        }
        return try JSONDecoder().decode(DetectionLogEntry.self, from: data)
    }
}

enum DetectionLogEntryError: Error {
    case encodingFailed
    case decodingFailed
}
```

- [ ] **Step 4: Run — expect pass**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/DetectionLogEntryTests -quiet 2>&1 | tail -3`
Expected: `Test Suite 'DetectionLogEntryTests' passed`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/DetectionLogEntry.swift HoopTrack/HoopTrackTests/DetectionLogEntryTests.swift
git commit -m "feat(cv-a): DetectionLogEntry Codable with JSONL roundtrip tests"
```

---

### Task 4: `FrameSampler` pure logic — TDD

**Files:**
- Create: `HoopTrack/HoopTrackTests/FrameSamplerTests.swift`
- Create: `HoopTrack/HoopTrack/Utilities/FrameSampler.swift`

- [ ] **Step 1: Write the failing tests**

Write `HoopTrack/HoopTrackTests/FrameSamplerTests.swift`:

```swift
import XCTest
@testable import HoopTrack

final class FrameSamplerTests: XCTestCase {

    // Helper — generate a simple all-`tracking` log with no flicker
    private func makeLog(durationSec: Double, fps: Double = 30, ballConf: Double = 0.9) -> [DetectionLogEntry] {
        let step = 1.0 / fps
        return stride(from: 0.0, to: durationSec, by: step).map { t in
            DetectionLogEntry(
                timestampSec: t,
                ballConfidence: ballConf,
                ballBox: [0.5, 0.5, 0.1, 0.1],
                rimConfidence: 0.9,
                rimBox: [0.45, 0.1, 0.12, 0.06],
                state: "tracking"
            )
        }
    }

    func test_baselineTrigger_producesOneFramePerSecond() {
        let log = makeLog(durationSec: 10.0)
        let timestamps = FrameSampler.sampleTimestamps(
            log: log,
            shotTimestamps: [],
            sessionDurationSec: 10.0
        )
        // Baseline (10 × 1fps) + boundary (5 front + 5 back from 30fps log) — deduped
        XCTAssertGreaterThanOrEqual(timestamps.count, 10)
        // Baseline timestamps at t=0,1,2,...9 should all be present
        for t in stride(from: 0.0, through: 9.0, by: 1.0) {
            XCTAssertTrue(timestamps.contains { abs($0 - t) < 1e-6 },
                          "Missing baseline timestamp \(t)")
        }
    }

    func test_aroundShot_adds20FramesPerShot() {
        let log = makeLog(durationSec: 30.0)
        // Shot at t=15, with no baseline overlap in the ±0.33s window
        let shotT = 15.5      // offset from 1fps grid so baseline doesn't dedupe-swallow
        let timestamps = FrameSampler.sampleTimestamps(
            log: log,
            shotTimestamps: [shotT],
            sessionDurationSec: 30.0
        )
        // Count timestamps inside the ±0.333s window around the shot
        let windowStart = shotT - 0.334
        let windowEnd   = shotT + 0.667   // 10 frames post at 30fps = 0.333s, but boundary-inclusive
        let shotFrames = timestamps.filter { $0 >= windowStart && $0 <= windowEnd }
        XCTAssertGreaterThanOrEqual(shotFrames.count, 15, "Expected ~20 around-shot frames")
    }

    func test_flickerWindow_detectedAndSampled() {
        // Build a log where ball confidence dips below 0.3 for frames 90..95
        var log = makeLog(durationSec: 10.0)
        for i in 90..<96 {
            let t = log[i].timestampSec
            log[i] = DetectionLogEntry(
                timestampSec: t,
                ballConfidence: 0.2,
                ballBox: [0.5, 0.5, 0.1, 0.1],
                rimConfidence: 0.9,
                rimBox: nil,
                state: "tracking"
            )
        }
        let timestamps = FrameSampler.sampleTimestamps(
            log: log,
            shotTimestamps: [],
            sessionDurationSec: 10.0
        )
        // The flicker window (~t=3.0–3.17) should contribute at least a few extra samples
        let windowSamples = timestamps.filter { $0 > 2.8 && $0 < 3.4 }.count
        XCTAssertGreaterThanOrEqual(windowSamples, 2, "Flicker trigger should have added samples")
    }

    func test_boundaries_frontAndBackIncluded() {
        let log = makeLog(durationSec: 5.0)
        let timestamps = FrameSampler.sampleTimestamps(
            log: log,
            shotTimestamps: [],
            sessionDurationSec: 5.0
        )
        // First few frames (0, 1/30, 2/30, ...) should be present from the front boundary
        XCTAssertTrue(timestamps.contains { abs($0 - 0.0) < 1e-6 })
        XCTAssertTrue(timestamps.contains { abs($0 - (1.0/30.0)) < 0.01 })
        // Last frames should be near 5.0
        XCTAssertTrue(timestamps.contains { $0 > 4.85 })
    }

    func test_overCap_decimatesBaselineFirst() {
        // 20-minute session → baseline alone is 1200; cap is 1000
        let log = makeLog(durationSec: 1200.0)
        let shots = stride(from: 100.0, through: 1000.0, by: 200.0).map { $0 }   // 5 shots × ~20 = 100
        let timestamps = FrameSampler.sampleTimestamps(
            log: log,
            shotTimestamps: shots,
            sessionDurationSec: 1200.0
        )
        XCTAssertLessThanOrEqual(timestamps.count, HoopTrack.Telemetry.maxFramesPerSession)
        // All shot-window timestamps must still be present — decimation drops baseline first
        for shotT in shots {
            let windowCount = timestamps.filter { abs($0 - shotT) <= 0.334 }.count
            XCTAssertGreaterThanOrEqual(windowCount, 10, "Shot window at \(shotT) should survive decimation")
        }
    }

    func test_emptyLog_returnsEmpty() {
        let timestamps = FrameSampler.sampleTimestamps(
            log: [],
            shotTimestamps: [],
            sessionDurationSec: 0
        )
        XCTAssertEqual(timestamps, [])
    }

    func test_timestampsAreSortedAndUnique() {
        let log = makeLog(durationSec: 30.0)
        let timestamps = FrameSampler.sampleTimestamps(
            log: log,
            shotTimestamps: [5.0, 10.0, 15.0],
            sessionDurationSec: 30.0
        )
        // Sorted
        XCTAssertEqual(timestamps, timestamps.sorted())
        // Unique
        XCTAssertEqual(Set(timestamps).count, timestamps.count)
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/FrameSamplerTests -quiet 2>&1 | tail -5`
Expected: `error: cannot find 'FrameSampler' in scope`

- [ ] **Step 3: Create the implementation**

Write `HoopTrack/HoopTrack/Utilities/FrameSampler.swift`:

```swift
// FrameSampler.swift
// Pure-logic trigger-rule engine for CV-A. Given a detection log + shot
// timestamps + session duration, returns the sorted, unique list of
// timestamps to extract frames at. Tested in isolation without Vision or
// AVFoundation.

import Foundation

nonisolated enum FrameSampler {

    /// Main entry point. Applies all four triggers, dedupes, decimates if
    /// over cap. Return value is sorted ascending; timestamps in seconds.
    static func sampleTimestamps(
        log: [DetectionLogEntry],
        shotTimestamps: [Double],
        sessionDurationSec: Double
    ) -> [Double] {
        guard !log.isEmpty, sessionDurationSec > 0 else { return [] }

        // Bucket each trigger separately so decimation can drop one without
        // touching the others.
        let baseline  = baselineTimestamps(durationSec: sessionDurationSec)
        let aroundShot = aroundShotTimestamps(log: log, shots: shotTimestamps)
        let flicker    = flickerTimestamps(log: log)
        let boundary   = boundaryTimestamps(log: log)

        // Merge + dedupe with tolerance — two timestamps within one frame
        // interval of each other (at 30fps, ~33ms) are the same frame.
        let merged = dedupe(
            priority: [boundary, aroundShot, flicker, baseline]
        )

        // Decimate if over cap. Priority order: baseline → flicker →
        // around-shot → boundary (drop least-dense first).
        return decimateIfNeeded(
            timestamps: merged,
            baseline: baseline,
            flicker: flicker,
            aroundShot: aroundShot,
            boundary: boundary,
            cap: HoopTrack.Telemetry.maxFramesPerSession
        )
    }

    // MARK: - Triggers

    private static func baselineTimestamps(durationSec: Double) -> [Double] {
        let step = 1.0 / HoopTrack.Telemetry.baselineSampleFPS
        return Array(stride(from: 0.0, to: durationSec, by: step))
    }

    /// Picks the `preFrames` frames ending at the shot timestamp plus
    /// `postFrames` starting at the shot timestamp. Operates on the log so
    /// the timestamps are real frame times (not interpolated).
    private static func aroundShotTimestamps(
        log: [DetectionLogEntry],
        shots: [Double]
    ) -> [Double] {
        var out: [Double] = []
        let pre = HoopTrack.Telemetry.aroundShotPreFrames
        let post = HoopTrack.Telemetry.aroundShotPostFrames
        for shot in shots {
            guard let idx = nearestIndex(in: log, to: shot) else { continue }
            let start = max(0, idx - pre)
            let end = min(log.count - 1, idx + post)
            for i in start...end {
                out.append(log[i].timestampSec)
            }
        }
        return out
    }

    /// Finds runs where `ballConfidence` drops from ≥ high to < low for
    /// ≥ `flickerMinConsecutiveFrames` frames. Samples every 3rd frame in the
    /// run plus a 3-frame shoulder on each side.
    private static func flickerTimestamps(log: [DetectionLogEntry]) -> [Double] {
        let high = HoopTrack.Telemetry.flickerThresholdHigh
        let low = HoopTrack.Telemetry.flickerThresholdLow
        let minRun = HoopTrack.Telemetry.flickerMinConsecutiveFrames

        var out: [Double] = []
        var runStart: Int? = nil
        var i = 0
        while i < log.count {
            let conf = log[i].ballConfidence ?? 0
            if conf < low {
                if runStart == nil { runStart = i }
            } else {
                if let start = runStart, i - start >= minRun, conf >= high {
                    // Run confirmed: start .. i-1 (inclusive). Shoulder ±3.
                    let from = max(0, start - 3)
                    let to = min(log.count - 1, i + 2)
                    // Every 3rd frame of the run, plus the shoulders
                    var j = from
                    while j <= to {
                        out.append(log[j].timestampSec)
                        j += 3
                    }
                }
                runStart = nil
            }
            i += 1
        }
        return out
    }

    private static func boundaryTimestamps(log: [DetectionLogEntry]) -> [Double] {
        let n = HoopTrack.Telemetry.boundaryFrames
        let head = log.prefix(n).map(\.timestampSec)
        let tail = log.suffix(n).map(\.timestampSec)
        return head + tail
    }

    // MARK: - Dedupe + decimate

    private static func nearestIndex(in log: [DetectionLogEntry], to t: Double) -> Int? {
        guard !log.isEmpty else { return nil }
        // Linear scan — log is sorted by timestamp, typically < 20k entries
        var best = 0
        var bestDelta = abs(log[0].timestampSec - t)
        for (i, entry) in log.enumerated() {
            let d = abs(entry.timestampSec - t)
            if d < bestDelta {
                best = i
                bestDelta = d
            }
        }
        return best
    }

    /// Given buckets in priority order (highest first), merge, sort, and
    /// dedupe timestamps that are within one frame-interval of each other.
    private static func dedupe(priority: [[Double]]) -> [Double] {
        let tolerance = 1.0 / 60.0   // 16.7ms — slightly less than one frame at 30fps
        let all = priority.flatMap { $0 }.sorted()
        var result: [Double] = []
        for t in all {
            if let last = result.last, t - last < tolerance { continue }
            result.append(t)
        }
        return result
    }

    private static func decimateIfNeeded(
        timestamps: [Double],
        baseline: [Double],
        flicker: [Double],
        aroundShot: [Double],
        boundary: [Double],
        cap: Int
    ) -> [Double] {
        if timestamps.count <= cap { return timestamps }

        // Over cap — drop baseline first, then flicker, then around-shot,
        // then boundary (never dropped).
        let protectedSet = Set(boundary + aroundShot)
        let baselineSet = Set(baseline)
        let flickerSet = Set(flicker)

        var current = timestamps
        // Tier 1: drop baseline that isn't protected
        var removable = current.filter { baselineSet.contains($0) && !protectedSet.contains($0) }
        while current.count > cap, !removable.isEmpty {
            // Drop evenly-spaced baseline timestamps first
            let step = max(1, removable.count / max(1, current.count - cap))
            var toRemove: Set<Double> = []
            var i = 0
            while i < removable.count, current.count - toRemove.count > cap {
                toRemove.insert(removable[i])
                i += step
            }
            current.removeAll { toRemove.contains($0) }
            removable = current.filter { baselineSet.contains($0) && !protectedSet.contains($0) }
        }
        if current.count <= cap { return current }

        // Tier 2: drop flicker
        removable = current.filter { flickerSet.contains($0) && !protectedSet.contains($0) }
        while current.count > cap, !removable.isEmpty {
            current.removeAll { $0 == removable.removeFirst() }
        }

        return current
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/FrameSamplerTests -quiet 2>&1 | tail -5`
Expected: `Test Suite 'FrameSamplerTests' passed`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/FrameSampler.swift HoopTrack/HoopTrackTests/FrameSamplerTests.swift
git commit -m "feat(cv-a): FrameSampler pure logic with TDD coverage of all 4 triggers + cap"
```

---

### Task 5: `TelemetryUpload` `@Model` + container registration

**Files:**
- Create: `HoopTrack/HoopTrack/Models/TelemetryUpload.swift`
- Create: `HoopTrack/HoopTrackTests/TelemetryUploadModelTests.swift`
- Modify: `HoopTrack/HoopTrack/HoopTrackApp.swift`

- [ ] **Step 1: Create the `@Model`**

Write `HoopTrack/HoopTrack/Models/TelemetryUpload.swift`:

```swift
// TelemetryUpload.swift
// One row per session that has captured telemetry and needs to be (or has
// been) uploaded to Supabase Storage. Deliberately loose-coupled to
// TrainingSession / GameSession via UUID so the upload row outlives the
// session if the user deletes it mid-upload.

import Foundation
import SwiftData

@Model
final class TelemetryUpload {
    @Attribute(.unique) var sessionID: UUID
    var stateRaw: String            // UploadState.rawValue
    var sessionKindRaw: String      // SessionKind.rawValue
    var frameCount: Int
    var totalBytes: Int
    var remoteBucketPath: String?
    var createdAt: Date
    var lastAttemptAt: Date?
    var attemptCount: Int
    var errorMessage: String?

    init(
        sessionID: UUID,
        sessionKind: SessionKind,
        frameCount: Int,
        totalBytes: Int
    ) {
        self.sessionID = sessionID
        self.stateRaw = UploadState.pending.rawValue
        self.sessionKindRaw = sessionKind.rawValue
        self.frameCount = frameCount
        self.totalBytes = totalBytes
        self.createdAt = .now
        self.attemptCount = 0
    }

    var state: UploadState {
        get { UploadState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    var sessionKind: SessionKind {
        get { SessionKind(rawValue: sessionKindRaw) ?? .training }
        set { sessionKindRaw = newValue.rawValue }
    }
}
```

- [ ] **Step 2: Register with the ModelContainer**

Open `HoopTrack/HoopTrack/HoopTrackApp.swift` and find the `Schema([...])` list (currently includes `PlayerProfile.self, TrainingSession.self, ShotRecord.self, GoalRecord.self, EarnedBadge.self, GamePlayer.self, GameSession.self, GameShotRecord.self`). Add `TelemetryUpload.self`:

```swift
let schema = Schema([
    PlayerProfile.self, TrainingSession.self,
    ShotRecord.self, GoalRecord.self, EarnedBadge.self,
    GamePlayer.self, GameSession.self, GameShotRecord.self,
    TelemetryUpload.self,
])
```

- [ ] **Step 3: Smoke test**

Write `HoopTrack/HoopTrackTests/TelemetryUploadModelTests.swift`:

```swift
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class TelemetryUploadModelTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: TelemetryUpload.self, configurations: config)
    }

    func test_defaultState_isPending() throws {
        let id = UUID()
        let upload = TelemetryUpload(
            sessionID: id, sessionKind: .training,
            frameCount: 500, totalBytes: 25_000_000
        )
        XCTAssertEqual(upload.state, .pending)
        XCTAssertEqual(upload.sessionKind, .training)
        XCTAssertEqual(upload.attemptCount, 0)
        XCTAssertNil(upload.lastAttemptAt)
        XCTAssertNil(upload.remoteBucketPath)
    }

    func test_stateTransitions_persist() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let upload = TelemetryUpload(
            sessionID: UUID(), sessionKind: .game,
            frameCount: 700, totalBytes: 30_000_000
        )
        ctx.insert(upload)
        try ctx.save()

        upload.state = .uploading
        upload.lastAttemptAt = .now
        upload.attemptCount = 1
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<TelemetryUpload>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.state, .uploading)
        XCTAssertEqual(fetched.first?.attemptCount, 1)
    }

    func test_uniqueSessionID_preventsDoubleInsert() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let id = UUID()
        let first = TelemetryUpload(
            sessionID: id, sessionKind: .training, frameCount: 100, totalBytes: 1000
        )
        ctx.insert(first)
        try ctx.save()

        let duplicate = TelemetryUpload(
            sessionID: id, sessionKind: .training, frameCount: 200, totalBytes: 2000
        )
        ctx.insert(duplicate)
        // SwiftData enforces unique — save must throw or collapse
        XCTAssertNoThrow(try ctx.save())
        let fetched = try ctx.fetch(FetchDescriptor<TelemetryUpload>())
        XCTAssertEqual(fetched.count, 1, "Unique attribute should prevent two rows with same sessionID")
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/TelemetryUploadModelTests -quiet 2>&1 | tail -5`
Expected: `Test Suite 'TelemetryUploadModelTests' passed`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Models/TelemetryUpload.swift \
        HoopTrack/HoopTrack/HoopTrackApp.swift \
        HoopTrack/HoopTrackTests/TelemetryUploadModelTests.swift
git commit -m "feat(cv-a): TelemetryUpload @Model + SwiftData container registration"
```

---

### Task 6: `DetectionLogger` — live-session JSONL writer

**Files:**
- Create: `HoopTrack/HoopTrack/Services/DetectionLogger.swift`

- [ ] **Step 1: Write the logger**

Write `HoopTrack/HoopTrack/Services/DetectionLogger.swift`:

```swift
// DetectionLogger.swift
// Lightweight per-frame JSONL writer. Called from CVPipeline's processBuffer
// on the camera sessionQueue. Writes to
// Documents/Telemetry/<sessionID>/detections.jsonl with
// FileProtectionType.complete. Buffered in memory; flushed every N records
// or when the session ends.

import Foundation

nonisolated final class DetectionLogger {

    private let sessionID: UUID
    private let fileURL: URL
    private let fileManager = FileManager.default
    private let flushInterval: Int

    // All mutable state is accessed only from the sessionQueue that drives
    // CVPipeline. Logger is owned by CVPipeline; single-serial-queue access
    // is the runtime contract.
    nonisolated(unsafe) private var buffer: [DetectionLogEntry] = []
    nonisolated(unsafe) private var fileHandle: FileHandle?

    /// - Parameters:
    ///   - sessionID: UUID of the session being recorded.
    ///   - flushInterval: Number of records to accumulate before writing.
    ///     Default 30 ≈ 1 second at 30fps.
    init(sessionID: UUID, flushInterval: Int = 30) throws {
        self.sessionID = sessionID
        self.flushInterval = flushInterval

        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionDir = docs
            .appendingPathComponent(HoopTrack.Telemetry.telemetryDirectoryName)
            .appendingPathComponent(sessionID.uuidString)
        try fileManager.createDirectory(
            at: sessionDir,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )

        self.fileURL = sessionDir.appendingPathComponent("detections.jsonl")
        // Create (empty) so we can open a handle.
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        self.fileHandle = try FileHandle(forWritingTo: fileURL)
        try self.fileHandle?.seekToEnd()
    }

    /// Append one frame's detection state. Flushes to disk when the buffer
    /// reaches `flushInterval`.
    func log(_ entry: DetectionLogEntry) {
        buffer.append(entry)
        if buffer.count >= flushInterval {
            flush()
        }
    }

    /// Force a write of pending records. Called automatically by `close()`
    /// and periodically via `log()`.
    func flush() {
        guard let handle = fileHandle, !buffer.isEmpty else { return }
        for entry in buffer {
            if let line = try? entry.jsonLine(), let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
        buffer.removeAll(keepingCapacity: true)
    }

    /// Final flush + close. Called from CVPipeline.stop().
    func close() {
        flush()
        try? fileHandle?.close()
        fileHandle = nil
    }

    deinit {
        // No async work in deinit — flush is synchronous.
        if fileHandle != nil { close() }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Services/DetectionLogger.swift
git commit -m "feat(cv-a): DetectionLogger — per-frame JSONL writer for live sessions"
```

---

### Task 7: Hook `DetectionLogger` into `CVPipeline`

**Files:**
- Modify: `HoopTrack/HoopTrack/Services/CVPipeline.swift`

- [ ] **Step 1: Add logger storage + setter**

Open `HoopTrack/HoopTrack/Services/CVPipeline.swift`. Inside the `CVPipeline` class, add these fields just after the existing `frameCancellable` property:

```swift
    // MARK: - Telemetry (CV-A)
    nonisolated(unsafe) private var detectionLogger: DetectionLogger?
    nonisolated(unsafe) private var sessionStartCMTime: CMTime = .zero
```

- [ ] **Step 2: Add `attachTelemetry` / `detachTelemetry` entry points**

Inside `CVPipeline`, after the `stop()` method, add:

```swift
    /// Attach a DetectionLogger for the duration of the session. Called by
    /// LiveSessionView at session start; detached by `stop()`.
    func attachTelemetry(logger: DetectionLogger) {
        self.detectionLogger = logger
        self.sessionStartCMTime = .zero   // reset on each session
    }

    /// Called when a session ends without going through `stop()`. Not
    /// strictly required — `stop()` calls `close()` on the logger — but
    /// makes the contract explicit.
    func detachTelemetry() {
        detectionLogger?.close()
        detectionLogger = nil
    }
```

- [ ] **Step 3: Wire `stop()` to close the logger**

Replace the existing `stop()` method body:

```swift
    func stop() {
        frameCancellable?.cancel()
        frameCancellable = nil
        pipelineState = .idle
        detectionLogger?.close()
        detectionLogger = nil
    }
```

- [ ] **Step 4: Log every frame from `processBuffer`**

Inside `processBuffer(_ buffer:)`, immediately after the line `let now = scene.frameTimestamp`, add:

```swift
        // CV-A — Telemetry per-frame log (only when logger attached)
        if let logger = detectionLogger {
            if sessionStartCMTime == .zero { sessionStartCMTime = now }
            let sessionTime = CMTimeGetSeconds(CMTimeSubtract(now, sessionStartCMTime))
            let stateStr: String = {
                switch pipelineState {
                case .idle:             return "idle"
                case .tracking:         return "tracking"
                case .releaseDetected:  return "release_detected"
                }
            }()
            logger.log(DetectionLogEntry(
                timestampSec:   sessionTime,
                ballConfidence: scene.ball.map { Double($0.confidence) },
                ballBox:        scene.ball.map { [Double($0.boundingBox.origin.x),
                                                   Double($0.boundingBox.origin.y),
                                                   Double($0.boundingBox.size.width),
                                                   Double($0.boundingBox.size.height)] },
                rimConfidence:  scene.basket.map { Double($0.confidence) },
                rimBox:         scene.basket.map { [Double($0.boundingBox.origin.x),
                                                    Double($0.boundingBox.origin.y),
                                                    Double($0.boundingBox.size.width),
                                                    Double($0.boundingBox.size.height)] },
                state:          stateStr
            ))
        }
```

- [ ] **Step 5: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add HoopTrack/HoopTrack/Services/CVPipeline.swift
git commit -m "feat(cv-a): attachTelemetry hook in CVPipeline logs every frame to JSONL"
```

---

### Task 8: `TelemetryCaptureService` — post-session frame extraction

**Files:**
- Create: `HoopTrack/HoopTrack/Services/TelemetryCaptureService.swift`

- [ ] **Step 1: Write the service**

Write `HoopTrack/HoopTrack/Services/TelemetryCaptureService.swift`:

```swift
// TelemetryCaptureService.swift
// Post-session: reads detections.jsonl, applies FrameSampler rules,
// extracts JPEGs from the recorded .mov, writes manifest.json, creates a
// TelemetryUpload @Model row in .pending state.
//
// Runs off-main via Task.detached so it doesn't block session summary.

import Foundation
import AVFoundation
import UIKit
import SwiftData

@MainActor
final class TelemetryCaptureService {

    private let modelContext: ModelContext
    private let fileManager = FileManager.default

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    struct CaptureResult: Sendable {
        let frameCount: Int
        let totalBytes: Int
    }

    /// Main entry point. Called from SessionFinalizationCoordinator step 10.
    /// Returns a CaptureResult if work happened, nil if skipped.
    /// Runs the heavy extraction off-main but touches the modelContext
    /// only on main.
    func capture(
        sessionID: UUID,
        sessionKind: SessionKind,
        videoURL: URL,
        shotTimestamps: [Double],
        sessionStartedAt: Date,
        sessionDurationSec: Double,
        modelVersion: String,
        appVersion: String
    ) async -> CaptureResult? {

        // Short-circuit if session is too trivial to be useful.
        guard sessionDurationSec >= HoopTrack.Telemetry.minSessionDurationSec else {
            return nil
        }

        // Short-circuit if detections.jsonl is missing.
        let sessionDir = telemetryDir(sessionID: sessionID)
        let logURL = sessionDir.appendingPathComponent("detections.jsonl")
        guard fileManager.fileExists(atPath: logURL.path) else { return nil }

        // Phase A — off-main: read log + extract frames.
        let extraction: (timestamps: [Double], triggerSummary: [String: Int], frameBytes: [(name: String, bytes: Int)])?
        = await Task.detached { [fileManager] in
            do {
                let log = try Self.readLog(at: logURL)
                let timestamps = FrameSampler.sampleTimestamps(
                    log: log,
                    shotTimestamps: shotTimestamps,
                    sessionDurationSec: sessionDurationSec
                )
                let triggerSummary = Self.computeTriggerSummary(
                    log: log,
                    shotTimestamps: shotTimestamps,
                    selected: timestamps,
                    sessionDurationSec: sessionDurationSec
                )
                let frameBytes = try Self.extractFrames(
                    videoURL: videoURL,
                    timestamps: timestamps,
                    outputDir: sessionDir,
                    fileManager: fileManager
                )
                return (timestamps, triggerSummary, frameBytes)
            } catch {
                return nil
            }
        }.value

        guard let extraction else { return nil }

        // Phase B — on main: write manifest + TelemetryUpload row.
        do {
            try writeManifest(
                sessionDir: sessionDir,
                sessionID: sessionID,
                sessionKind: sessionKind,
                sessionStartedAt: sessionStartedAt,
                sessionDurationSec: sessionDurationSec,
                shotCount: shotTimestamps.count,
                modelVersion: modelVersion,
                appVersion: appVersion,
                triggerSummary: extraction.triggerSummary,
                frames: extraction.frameBytes,
                timestamps: extraction.timestamps
            )
        } catch {
            return nil
        }

        let manifestBytes = (try? Data(contentsOf: sessionDir.appendingPathComponent("manifest.json")).count) ?? 0
        let logBytes = (try? Data(contentsOf: logURL).count) ?? 0
        let totalBytes = extraction.frameBytes.reduce(0, { $0 + $1.bytes }) + manifestBytes + logBytes

        let row = TelemetryUpload(
            sessionID: sessionID,
            sessionKind: sessionKind,
            frameCount: extraction.frameBytes.count,
            totalBytes: totalBytes
        )
        modelContext.insert(row)
        try? modelContext.save()

        return CaptureResult(
            frameCount: extraction.frameBytes.count,
            totalBytes: totalBytes
        )
    }

    // MARK: - Helpers

    private func telemetryDir(sessionID: UUID) -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent(HoopTrack.Telemetry.telemetryDirectoryName)
            .appendingPathComponent(sessionID.uuidString)
    }

    private static func readLog(at url: URL) throws -> [DetectionLogEntry] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                try? DetectionLogEntry.decode(jsonLine: String(line))
            }
    }

    private static func computeTriggerSummary(
        log: [DetectionLogEntry],
        shotTimestamps: [Double],
        selected: [Double],
        sessionDurationSec: Double
    ) -> [String: Int] {
        // Rough attribution — count each selected timestamp against its
        // most-likely source. Not exact (overlap is ambiguous) but useful
        // for the manifest summary.
        var summary: [String: Int] = ["baseline": 0, "around_shot": 0, "flicker": 0, "boundaries": 0]
        let step = 1.0 / HoopTrack.Telemetry.baselineSampleFPS
        let boundary = Set(log.prefix(HoopTrack.Telemetry.boundaryFrames).map(\.timestampSec)
            + log.suffix(HoopTrack.Telemetry.boundaryFrames).map(\.timestampSec))
        for t in selected {
            if boundary.contains(t) {
                summary["boundaries", default: 0] += 1
            } else if shotTimestamps.contains(where: { abs($0 - t) <= 0.334 }) {
                summary["around_shot", default: 0] += 1
            } else if abs(t.truncatingRemainder(dividingBy: step)) < 1e-3 ||
                      abs(step - t.truncatingRemainder(dividingBy: step)) < 1e-3 {
                summary["baseline", default: 0] += 1
            } else {
                summary["flicker", default: 0] += 1
            }
        }
        return summary
    }

    private static func extractFrames(
        videoURL: URL,
        timestamps: [Double],
        outputDir: URL,
        fileManager: FileManager
    ) throws -> [(name: String, bytes: Int)] {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let edge = CGFloat(HoopTrack.Telemetry.frameMaxLongestEdgePx)
        generator.maximumSize = CGSize(width: edge, height: edge)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter  = CMTime(value: 1, timescale: 30)

        var out: [(name: String, bytes: Int)] = []
        for (idx, ts) in timestamps.enumerated() {
            let cmTime = CMTime(seconds: ts, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else {
                continue
            }
            let image = UIImage(cgImage: cgImage)
            guard let jpeg = image.jpegData(compressionQuality: HoopTrack.Telemetry.frameJpegQuality) else {
                continue
            }
            let name = String(format: "frame_%04d.jpg", idx)
            let url = outputDir.appendingPathComponent(name)
            try jpeg.write(to: url, options: [.completeFileProtection])
            out.append((name, jpeg.count))
        }
        return out
    }

    private struct ManifestFrame: Encodable {
        let file: String
        let timestamp_sec: Double
        let width: Int
        let height: Int
    }

    private struct Manifest: Encodable {
        let session_id: String
        let session_kind: String
        let app_version: String
        let model_version: String
        let session_started_at: String
        let session_duration_sec: Double
        let total_shots: Int
        let frame_count: Int
        let trigger_summary: [String: Int]
        let frames: [ManifestFrame]
    }

    private func writeManifest(
        sessionDir: URL,
        sessionID: UUID,
        sessionKind: SessionKind,
        sessionStartedAt: Date,
        sessionDurationSec: Double,
        shotCount: Int,
        modelVersion: String,
        appVersion: String,
        triggerSummary: [String: Int],
        frames: [(name: String, bytes: Int)],
        timestamps: [Double]
    ) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let manifestFrames = zip(frames, timestamps).map { (pair, ts) in
            ManifestFrame(
                file: pair.name,
                timestamp_sec: ts,
                width: HoopTrack.Telemetry.frameMaxLongestEdgePx,
                height: HoopTrack.Telemetry.frameMaxLongestEdgePx
            )
        }

        let manifest = Manifest(
            session_id: sessionID.uuidString,
            session_kind: sessionKind.rawValue,
            app_version: appVersion,
            model_version: modelVersion,
            session_started_at: iso.string(from: sessionStartedAt),
            session_duration_sec: sessionDurationSec,
            total_shots: shotCount,
            frame_count: frames.count,
            trigger_summary: triggerSummary,
            frames: manifestFrames
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: sessionDir.appendingPathComponent("manifest.json"),
                       options: [.completeFileProtection])
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Services/TelemetryCaptureService.swift
git commit -m "feat(cv-a): TelemetryCaptureService — reads JSONL, extracts JPEGs, writes manifest"
```

---

### Task 9: Supabase Storage accessor

**Files:**
- Modify: `HoopTrack/HoopTrack/Auth/SupabaseClient+Shared.swift`

- [ ] **Step 1: Add Storage import + accessor**

Open `HoopTrack/HoopTrack/Auth/SupabaseClient+Shared.swift`. At the top, alongside the existing `import Auth` and `import PostgREST`, add:

```swift
import Storage
```

Inside the `SupabaseContainer` enum, below the existing `postgrest()` function, add:

```swift
    /// Fresh SupabaseStorageClient per call — same pattern as postgrest(),
    /// uses the current session's access token so bucket RLS resolves
    /// against the authenticated user.
    static func storage() async throws -> SupabaseStorageClient {
        let accessToken = try await auth.session.accessToken
        var headers = anonHeaders
        headers["Authorization"] = "Bearer \(accessToken)"
        return SupabaseStorageClient(
            url: HoopTrack.Backend.supabaseURL.appendingPathComponent("storage/v1").absoluteString,
            headers: headers,
            session: URLSession.shared,
            logger: nil
        )
    }
```

Note: if the `SupabaseStorageClient` initializer signature in the installed version of `supabase-swift` differs, adapt the arguments. The concept (URL + headers + session) is stable across versions.

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

If the build fails on the `SupabaseStorageClient` init, open the module (`⌘-click` on `SupabaseStorageClient` in Xcode) to inspect available initializers and adjust accordingly.

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Auth/SupabaseClient+Shared.swift
git commit -m "feat(cv-a): SupabaseContainer.storage() accessor for the telemetry upload service"
```

---

### Task 10: `TelemetryUploadService` — Wi-Fi-only upload

**Files:**
- Create: `HoopTrack/HoopTrack/Services/TelemetryUploadService.swift`
- Create: `HoopTrack/HoopTrackTests/TelemetryUploadStateTests.swift`

- [ ] **Step 1: Write state-machine tests first**

Write `HoopTrack/HoopTrackTests/TelemetryUploadStateTests.swift`:

```swift
import XCTest
@testable import HoopTrack

final class TelemetryUploadStateTests: XCTestCase {

    func test_nextStateAfterFailure_belowCap_isFailed() {
        let state = TelemetryUploadService.nextStateAfterFailure(
            currentAttempts: 2,
            maxAttempts: HoopTrack.Telemetry.maxUploadAttempts
        )
        XCTAssertEqual(state, .failed)
    }

    func test_nextStateAfterFailure_atCap_isAbandoned() {
        let state = TelemetryUploadService.nextStateAfterFailure(
            currentAttempts: HoopTrack.Telemetry.maxUploadAttempts,
            maxAttempts: HoopTrack.Telemetry.maxUploadAttempts
        )
        XCTAssertEqual(state, .abandoned)
    }

    func test_isEligibleForRetry_pendingAndFailed_areEligible() {
        XCTAssertTrue(TelemetryUploadService.isEligibleForRetry(state: .pending, attempts: 0))
        XCTAssertTrue(TelemetryUploadService.isEligibleForRetry(state: .failed, attempts: 2))
    }

    func test_isEligibleForRetry_uploadingUploadedAbandoned_areNot() {
        XCTAssertFalse(TelemetryUploadService.isEligibleForRetry(state: .uploading, attempts: 1))
        XCTAssertFalse(TelemetryUploadService.isEligibleForRetry(state: .uploaded, attempts: 1))
        XCTAssertFalse(TelemetryUploadService.isEligibleForRetry(state: .abandoned, attempts: 5))
    }

    func test_isEligibleForRetry_failedAtCap_isNotEligible() {
        XCTAssertFalse(TelemetryUploadService.isEligibleForRetry(
            state: .failed,
            attempts: HoopTrack.Telemetry.maxUploadAttempts
        ))
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/TelemetryUploadStateTests -quiet 2>&1 | tail -5`
Expected: `error: cannot find 'TelemetryUploadService' in scope`

- [ ] **Step 3: Create the service**

Write `HoopTrack/HoopTrack/Services/TelemetryUploadService.swift`:

```swift
// TelemetryUploadService.swift
// Uploads pending TelemetryUpload rows to the Supabase `telemetry-sessions`
// bucket. Wi-Fi-only, waits for connectivity, 60s timeout per request.
// On success: deletes the local session directory, updates the row.
// On failure: increments attempt count, records error; abandoned after 5.

import Foundation
import SwiftData
import Storage

@MainActor
final class TelemetryUploadService {

    private let modelContext: ModelContext
    private let fileManager = FileManager.default
    nonisolated(unsafe) private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = HoopTrack.Telemetry.uploadRequestTimeoutSec
        return URLSession(configuration: config)
    }()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Walk pending/failed rows and attempt upload for each. Safe to call
    /// repeatedly; rows already in .uploading are skipped.
    func uploadPending(userID: UUID) async {
        let rows = (try? fetchEligible()) ?? []
        for row in rows {
            await upload(row: row, userID: userID)
        }
    }

    // MARK: - Per-row upload

    private func upload(row: TelemetryUpload, userID: UUID) async {
        guard Self.isEligibleForRetry(state: row.state, attempts: row.attemptCount) else { return }

        row.state = .uploading
        row.lastAttemptAt = .now
        row.attemptCount += 1
        try? modelContext.save()

        let sessionDir = telemetryDir(sessionID: row.sessionID)
        let remotePrefix = "\(userID.uuidString)/\(row.sessionID.uuidString)/"

        do {
            let storage = try await SupabaseContainer.storage()
            let bucket = storage.from(HoopTrack.Telemetry.supabaseBucketName)

            // 1. Upload manifest + detections.jsonl first (tiny — smoke tests
            //    the network before we spend time on 30 MB of frames).
            for name in ["manifest.json", "detections.jsonl"] {
                let localURL = sessionDir.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: localURL.path) else { continue }
                let data = try Data(contentsOf: localURL)
                _ = try await bucket.upload(
                    "\(remotePrefix)\(name)",
                    data: data,
                    options: FileOptions(contentType: name.hasSuffix(".json") ? "application/json" : "application/x-ndjson",
                                         upsert: true)
                )
            }

            // 2. Upload frames in parallel with a bounded concurrency.
            let frameURLs = try fileManager.contentsOfDirectory(
                at: sessionDir,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "jpg" }

            try await withThrowingTaskGroup(of: Void.self) { group in
                var inFlight = 0
                for url in frameURLs {
                    if inFlight >= HoopTrack.Telemetry.concurrentFrameUploads {
                        try await group.next()
                        inFlight -= 1
                    }
                    let filename = url.lastPathComponent
                    let data = try Data(contentsOf: url)
                    group.addTask {
                        _ = try await bucket.upload(
                            "\(remotePrefix)\(filename)",
                            data: data,
                            options: FileOptions(contentType: "image/jpeg", upsert: true)
                        )
                    }
                    inFlight += 1
                }
                try await group.waitForAll()
            }

            // 3. All succeeded — mark row, delete local dir.
            row.state = .uploaded
            row.remoteBucketPath = remotePrefix
            row.errorMessage = nil
            try? modelContext.save()

            try? fileManager.removeItem(at: sessionDir)

        } catch {
            row.state = Self.nextStateAfterFailure(
                currentAttempts: row.attemptCount,
                maxAttempts: HoopTrack.Telemetry.maxUploadAttempts
            )
            row.errorMessage = String(describing: error)
            try? modelContext.save()
        }
    }

    // MARK: - Pure helpers (testable)

    /// Given a row's current attempt count, decide the state to move to
    /// after a failed upload. Exposed for tests.
    static func nextStateAfterFailure(currentAttempts: Int, maxAttempts: Int) -> UploadState {
        currentAttempts >= maxAttempts ? .abandoned : .failed
    }

    /// Whether a row is eligible for another upload attempt.
    static func isEligibleForRetry(state: UploadState, attempts: Int) -> Bool {
        switch state {
        case .pending:   return true
        case .failed:    return attempts < HoopTrack.Telemetry.maxUploadAttempts
        case .uploading, .uploaded, .abandoned: return false
        }
    }

    // MARK: - Private helpers

    private func fetchEligible() throws -> [TelemetryUpload] {
        let descriptor = FetchDescriptor<TelemetryUpload>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let all = try modelContext.fetch(descriptor)
        return all.filter { Self.isEligibleForRetry(state: $0.state, attempts: $0.attemptCount) }
    }

    private func telemetryDir(sessionID: UUID) -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent(HoopTrack.Telemetry.telemetryDirectoryName)
            .appendingPathComponent(sessionID.uuidString)
    }
}
```

- [ ] **Step 4: Run — expect pass on state tests**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/TelemetryUploadStateTests -quiet 2>&1 | tail -5`
Expected: `Test Suite 'TelemetryUploadStateTests' passed`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Services/TelemetryUploadService.swift \
        HoopTrack/HoopTrackTests/TelemetryUploadStateTests.swift
git commit -m "feat(cv-a): TelemetryUploadService with Wi-Fi-only URLSession + retry/abandonment"
```

---

### Task 11: Wire telemetry services into `SessionFinalizationCoordinator`

**Files:**
- Modify: `HoopTrack/HoopTrack/Services/SessionFinalizationCoordinator.swift`

- [ ] **Step 1: Add service properties + init arguments**

Open `HoopTrack/HoopTrack/Services/SessionFinalizationCoordinator.swift`. At the top of the class, alongside existing services, add:

```swift
    private let telemetryCaptureService: TelemetryCaptureService?
    private let telemetryUploadService: TelemetryUploadService?
```

Update the `init`:

```swift
    init(
        dataService:            DataService,
        goalUpdateService:      GoalUpdateServiceProtocol,
        healthKitService:       HealthKitServiceProtocol,
        skillRatingService:     SkillRatingServiceProtocol,
        badgeEvaluationService: BadgeEvaluationServiceProtocol,
        notificationService:    NotificationService,
        syncCoordinator:        SyncCoordinator? = nil,
        telemetryCaptureService: TelemetryCaptureService? = nil,
        telemetryUploadService:  TelemetryUploadService? = nil
    ) {
        self.dataService            = dataService
        self.goalUpdateService      = goalUpdateService
        self.healthKitService       = healthKitService
        self.skillRatingService     = skillRatingService
        self.badgeEvaluationService = badgeEvaluationService
        self.notificationService    = notificationService
        self.syncCoordinator        = syncCoordinator
        self.telemetryCaptureService = telemetryCaptureService
        self.telemetryUploadService  = telemetryUploadService
    }
```

- [ ] **Step 2: Add the step 10 helper**

Below the existing `kickOffSync` method, add:

```swift
    /// Step 10 — CV-A Telemetry Capture & Upload.
    /// Fire-and-forget after sync so it never blocks the session summary.
    /// Skips silently if any prerequisite is missing (no video, no user,
    /// no services wired, session too short).
    private func kickOffTelemetry(
        sessionID: UUID,
        sessionKind: SessionKind,
        videoURL: URL?,
        shotTimestamps: [Double],
        sessionStartedAt: Date,
        sessionDurationSec: Double,
        modelVersion: String,
        profile: PlayerProfile
    ) {
        guard let capture = telemetryCaptureService,
              let upload = telemetryUploadService,
              let videoURL,
              sessionDurationSec >= HoopTrack.Telemetry.minSessionDurationSec,
              let uidString = profile.supabaseUserID,
              let userID = UUID(uuidString: uidString)
        else { return }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        Task { @MainActor in
            let result = await capture.capture(
                sessionID: sessionID,
                sessionKind: sessionKind,
                videoURL: videoURL,
                shotTimestamps: shotTimestamps,
                sessionStartedAt: sessionStartedAt,
                sessionDurationSec: sessionDurationSec,
                modelVersion: modelVersion,
                appVersion: appVersion
            )
            if result != nil {
                await upload.uploadPending(userID: userID)
            }
        }
    }
```

- [ ] **Step 3: Call the helper from every finalise entry point**

Find the existing `finaliseSession(...)` method. After the `kickOffSync(...)` call, add:

```swift
        kickOffTelemetry(
            sessionID: session.id,
            sessionKind: .training,
            videoURL: session.videoFileName.flatMap { Self.sessionVideoURL(filename: $0) },
            shotTimestamps: session.shots.map { $0.timestamp.timeIntervalSince(session.startedAt) },
            sessionStartedAt: session.startedAt,
            sessionDurationSec: session.durationSeconds,
            modelVersion: HoopTrack.ML.modelVersion,
            profile: profile
        )
```

Do the same for `finaliseDribbleSession(...)` and any other entry points (check the file — there may be additional ones for agility / game).

Also add the helper `sessionVideoURL` static, near the bottom of the class:

```swift
    private static func sessionVideoURL(filename: String) -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory)
            .appendingPathComponent(filename)
    }
```

- [ ] **Step 4: Ensure `HoopTrack.ML.modelVersion` exists**

Check `HoopTrack/HoopTrack/Utilities/Constants.swift` for a `ML` block with `modelVersion`. If absent, add it near the existing `ML` detector-label constants:

```swift
        /// Human-readable version string written into telemetry manifests so
        /// future retrains can correlate data with the model that was in use.
        /// Update whenever BallDetector.mlmodel is retrained/replaced.
        static let modelVersion = "BallDetector-yolo11m-2026-04-19"
```

- [ ] **Step 5: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

If the build fails because `finaliseSession` takes different parameters than what the above code references (e.g. no `profile` argument) or because `session.shots` structure differs, check the existing signature and adjust timestamps extraction to match. The shape of the change is: after existing `kickOffSync`, add the new `kickOffTelemetry` call with session-derived inputs.

- [ ] **Step 6: Commit**

```bash
git add HoopTrack/HoopTrack/Services/SessionFinalizationCoordinator.swift \
        HoopTrack/HoopTrack/Utilities/Constants.swift
git commit -m "feat(cv-a): SessionFinalizationCoordinator step 10 — kick off telemetry capture + upload"
```

---

### Task 12: Wire telemetry services in `CoordinatorBox`

**Files:**
- Modify: `HoopTrack/HoopTrack/CoordinatorHost.swift`

- [ ] **Step 1: Construct + inject the telemetry services**

Open `HoopTrack/HoopTrack/CoordinatorHost.swift`. Find the `CoordinatorBox.build(...)` method that constructs `SessionFinalizationCoordinator`. After the existing `DataService` is created, add:

```swift
        let telemetryCapture = TelemetryCaptureService(modelContext: modelContext)
        let telemetryUpload  = TelemetryUploadService(modelContext: modelContext)
```

Update the `SessionFinalizationCoordinator` init call to pass them in:

```swift
        value = SessionFinalizationCoordinator(
            dataService:            ds,
            goalUpdateService:      GoalUpdateService(modelContext: modelContext),
            healthKitService:       HealthKitService(),
            skillRatingService:     SkillRatingService(modelContext: modelContext),
            badgeEvaluationService: BadgeEvaluationService(modelContext: modelContext),
            notificationService:    notificationService,
            syncCoordinator:        SyncCoordinator(),
            telemetryCaptureService: telemetryCapture,
            telemetryUploadService:  telemetryUpload
        )
```

- [ ] **Step 2: Launch-time retry sweep**

At the end of `CoordinatorBox.build(...)` — same place the existing `try? ds.purgeOldVideos(...)` call lives — add a launch-time retry sweep:

```swift
        // CV-A — attempt to drain any pending telemetry uploads left from a
        // previous launch (e.g. app killed mid-upload).
        Task { @MainActor in
            if let profile = try? ds.fetchOrCreateProfile(),
               let uidString = profile.supabaseUserID,
               let userID = UUID(uuidString: uidString) {
                await telemetryUpload.uploadPending(userID: userID)
            }
        }
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/CoordinatorHost.swift
git commit -m "feat(cv-a): wire telemetry services in CoordinatorBox + launch-time retry sweep"
```

---

### Task 13: Wire `DetectionLogger` into `LiveSessionView` session start

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Train/LiveSessionView.swift`

- [ ] **Step 1: Create the logger when the session starts**

Open `HoopTrack/HoopTrack/Views/Train/LiveSessionView.swift`. Find where `CVPipeline.start(framePublisher:viewModel:)` is called (grep for `pipeline.start`). Immediately before that call, add:

```swift
                // CV-A — attach telemetry logger for this session
                if let session = viewModel.session {
                    if let logger = try? DetectionLogger(sessionID: session.id) {
                        pipeline.attachTelemetry(logger: logger)
                    }
                }
```

`pipeline` and `viewModel` reference names should match what's already in scope — adjust if the local variable is called something different.

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Train/LiveSessionView.swift
git commit -m "feat(cv-a): attach DetectionLogger at LiveSessionView's pipeline start"
```

---

### Task 14: Supabase — create bucket + RLS policy

**Files:** none in the iOS repo — this is a Supabase-side change.

- [ ] **Step 1: Create the bucket via Supabase MCP or Studio**

Using the Supabase MCP tools (preferred) or the Supabase Studio UI:

- Bucket name: `telemetry-sessions`
- Public: **NO** (private)
- File size limit: default (50 MB is plenty per frame)
- Allowed MIME types: leave empty (accept anything)

- [ ] **Step 2: Apply the RLS INSERT policy**

Run this SQL against the Supabase project (via MCP `execute_sql` or Studio SQL Editor):

```sql
-- Allow authenticated users to INSERT objects into their own folder only.
CREATE POLICY "telemetry_insert_own"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'telemetry-sessions'
    AND (storage.foldername(name))[1] = auth.uid()::text
);
```

No SELECT / UPDATE / DELETE policies — the defaults (deny) are exactly what we want. Admin access uses the service-role key.

- [ ] **Step 3: Confirm**

Run:

```sql
SELECT policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'storage' AND tablename = 'objects'
AND policyname = 'telemetry_insert_own';
```

Expected: one row, `cmd = INSERT`, `roles = {authenticated}`.

- [ ] **Step 4: Note the change in commit metadata**

No code files change in this task — but record the decision:

```bash
git commit --allow-empty -m "chore(cv-a): document Supabase telemetry-sessions bucket + INSERT RLS policy applied

Bucket: telemetry-sessions (private, no MIME restriction)
Policy: telemetry_insert_own — authenticated users may INSERT objects only
under their own auth.uid() prefix. SELECT/UPDATE/DELETE implicitly denied;
admin access via service-role key.
"
```

---

### Task 15: End-to-end manual QA

**Files:** none (manual QA on device).

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' 2>&1 | grep -E "Test Suite 'All tests'|failed|passed at" | tail -5`
Expected: `Test Suite 'All tests' passed` with zero failures.

- [ ] **Step 2: Install on device + walk the happy path**

Build + install on physical iPhone (simulator has no camera). Sign in. Then:

1. Start a Free Shoot session → take 3–5 shots → end session
2. Open the app's Documents directory via Xcode → Devices → HoopTrack → Download Container. Verify `Documents/Telemetry/<sessionID>/` exists with:
   - `detections.jsonl` (non-empty, ~18k lines for 10-min session)
   - `manifest.json` (parse it; `frame_count` > 0)
   - `frame_NNNN.jpg` files matching the manifest
3. Wait ~30s on Wi-Fi. Open Supabase Studio → Storage → `telemetry-sessions` bucket. Under `<your-user-id>/<sessionID>/` should see all the same files.
4. Re-download the container. Verify `Documents/Telemetry/<sessionID>/` is now gone (local cleanup ran).
5. Query the app's SwiftData store: the `TelemetryUpload` row for this session should be in `.uploaded` state with a non-nil `remoteBucketPath`.

- [ ] **Step 3: Test offline + retry path**

1. Put the device in Airplane Mode
2. Start + end a Free Shoot session
3. Local dir should be populated; `TelemetryUpload` row in `.pending` (upload attempt silently failed due to no network)
4. Turn Wi-Fi back on, relaunch the app
5. Launch-time retry sweep should kick in. Within ~30s, Supabase Storage should have the new session and local dir should be gone.

- [ ] **Step 4: Test kill mid-upload**

1. Start + end a session. As soon as the session summary appears (upload has started), kill the app from the app switcher.
2. Relaunch. Launch sweep should pick up the partially-uploaded row (state = `.uploading` was set mid-flight; on fresh launch it's effectively `.failed` logically — the service re-uploads the whole session regardless of partial state; Supabase's `upsert: true` flag on the upload options means re-uploading the same file is idempotent).
3. Verify bucket has the full session.

- [ ] **Step 5: Test minimum duration guard**

1. Start a Free Shoot session → immediately end it (< 30 seconds)
2. Verify no `Documents/Telemetry/<sessionID>/` directory was created
3. Verify no `TelemetryUpload` row was created

- [ ] **Step 6: Document results**

Record in a new commit (even if no code changes):

```bash
git commit --allow-empty -m "test(cv-a): manual QA pass on device

- Free Shoot happy path: local dir + manifest.json + jpgs + Supabase upload + cleanup all worked ✓
- Offline + Wi-Fi retry sweep: ✓
- Kill mid-upload + relaunch: ✓
- Sub-30s session correctly skipped ✓

Ready to accumulate the target 2000 frames × 10 diverse sessions before
triggering the next CV-B retrain."
```

---

## Notes for the implementer

- **CV-A covers Free Shoot sessions only in this plan.** Game-mode sessions (SP1) end via `GameSessionViewModel.endSession()`, which does not go through `SessionFinalizationCoordinator` and therefore does not trigger telemetry. Extending CV-A to game mode is a trivial follow-up once this lands — either add a parallel `finaliseGame(...)` entry point on the coordinator or inject the telemetry services into `GameSessionViewModel`. Deliberately out of scope here to keep the plan focused on Free Shoot, which is where CV-B will improve the most.
- **CV-A runs every session that qualifies.** There is no in-app opt-in or debug toggle in this version — that lives under production-readiness for App Store prep. If you want to temporarily disable telemetry during unrelated debugging, comment out the `attachTelemetry(...)` call in `LiveSessionView` (Task 13) rather than adding a runtime toggle.
- **Session queue ownership of `DetectionLogger`.** `CVPipeline` is `nonisolated` and processes on the camera session queue. `DetectionLogger` is also `nonisolated`; single-queue access is the runtime contract. Don't introduce additional callers from other actors.
- **CV-C compatibility.** When the CV-C Kalman tracking branch lands, the `DetectionLogEntry.ballBox` + `ballConfidence` fields become the *raw detection* values. To also record the smoothed track state, add optional fields to `DetectionLogEntry` — additive JSON change, no breakage. Nothing in this plan requires CV-C to exist.
- **Supabase Storage client init signature.** The sample code uses `SupabaseStorageClient(url:headers:session:logger:)` which matches `supabase-swift` ≥ 2.0. If the linked version differs, the initialiser parameters will too; adapt without changing the structure.
- **App version lookup.** `Bundle.main.infoDictionary?["CFBundleShortVersionString"]` is the canonical SwiftUI lookup and matches how the rest of the codebase formats it (spot-check the Phase 9 sync DTOs for reference).
- **SessionFinalizationCoordinator parameter plumbing.** Expect minor mismatches between Task 11's example code and the actual method signatures — check every finalise* entry point you find in the file and pass equivalent data. The shape is always: "after `kickOffSync`, call `kickOffTelemetry`".
- **No eval fixture in this phase.** The reference spec's §A7 `BallDetectorEvalTests` is a follow-up once real telemetry has accumulated enough to hand-label a fixture set. Out of scope here.
