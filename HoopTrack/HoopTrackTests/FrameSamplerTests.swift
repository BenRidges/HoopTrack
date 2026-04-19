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
        XCTAssertGreaterThanOrEqual(timestamps.count, 10)
        for t in stride(from: 0.0, through: 9.0, by: 1.0) {
            XCTAssertTrue(timestamps.contains { abs($0 - t) < 1e-6 },
                          "Missing baseline timestamp \(t)")
        }
    }

    func test_aroundShot_adds20FramesPerShot() {
        let log = makeLog(durationSec: 30.0)
        let shotT = 15.5
        let timestamps = FrameSampler.sampleTimestamps(
            log: log,
            shotTimestamps: [shotT],
            sessionDurationSec: 30.0
        )
        let windowStart = shotT - 0.334
        let windowEnd   = shotT + 0.667
        let shotFrames = timestamps.filter { $0 >= windowStart && $0 <= windowEnd }
        XCTAssertGreaterThanOrEqual(shotFrames.count, 15, "Expected ~20 around-shot frames")
    }

    func test_flickerWindow_detectedAndSampled() {
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
        XCTAssertTrue(timestamps.contains { abs($0 - 0.0) < 1e-6 })
        XCTAssertTrue(timestamps.contains { $0 > 4.85 })
    }

    func test_overCap_decimatesBaselineFirst() {
        let log = makeLog(durationSec: 1200.0)
        let shots = Array(stride(from: 100.0, through: 1000.0, by: 200.0))
        let timestamps = FrameSampler.sampleTimestamps(
            log: log,
            shotTimestamps: shots,
            sessionDurationSec: 1200.0
        )
        XCTAssertLessThanOrEqual(timestamps.count, HoopTrack.Telemetry.maxFramesPerSession)
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
        XCTAssertEqual(timestamps, timestamps.sorted())
        XCTAssertEqual(Set(timestamps).count, timestamps.count)
    }
}
