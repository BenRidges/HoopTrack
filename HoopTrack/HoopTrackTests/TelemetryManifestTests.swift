// HoopTrackTests/TelemetryManifestTests.swift

import XCTest
@testable import HoopTrack

final class TelemetryManifestTests: XCTestCase {

    private func entry(_ t: Double, balls: [[Double]]? = nil, rim: [Double]? = nil) -> DetectionLogEntry {
        var e = DetectionLogEntry(timestampSec: t, ballConfidence: balls?.first?[4],
                                  ballBox: balls?.first.map { Array($0.prefix(4)) },
                                  rimConfidence: rim == nil ? nil : 0.9, rimBox: rim, state: "idle")
        e.balls = balls
        return e
    }

    func test_topLeft_flipsTheVerticalOrigin() {
        XCTAssertEqual(TelemetryManifest.topLeft([0.1, 0.7, 0.2, 0.1])!, [0.1, 0.2, 0.2, 0.1], accuracy: 1e-12)
        XCTAssertNil(TelemetryManifest.topLeft([0.1, 0.2, 0, 0.1]))
    }

    func test_detections_comeFromTheNearestLogFrame() {
        let log = [
            entry(1.000, balls: [[0.5, 0.5, 0.03, 0.05, 0.9]]),
            entry(1.017, balls: [[0.6, 0.5, 0.03, 0.05, 0.8], [0.2, 0.3, 0.03, 0.05, 0.4]],
                  rim: [0.45, 0.7, 0.1, 0.1]),
            entry(1.033),
        ]
        let found = TelemetryManifest.detections(near: 1.02, in: log)
        XCTAssertEqual(found.map(\.label), ["ball", "ball", "basket"])
        XCTAssertEqual(found[0].confidence, 0.8)
        XCTAssertEqual(found[2].box[1], 0.2, accuracy: 1e-12)
        XCTAssertTrue(TelemetryManifest.detections(near: 1.033, in: log).isEmpty)
    }

    func test_detections_nothingNearby_isEmpty() {
        XCTAssertTrue(TelemetryManifest.detections(near: 5, in: [entry(1, balls: [[0.5, 0.5, 0.03, 0.05, 0.9]])]).isEmpty)
        XCTAssertTrue(TelemetryManifest.detections(near: 1, in: []).isEmpty)
    }

    func test_detections_olderLogsWithOnlyTheTopBall() {
        let old = DetectionLogEntry(timestampSec: 2.0, ballConfidence: 0.7, ballBox: [0.5, 0.5, 0.03, 0.05],
                                    rimConfidence: nil, rimBox: nil, state: "idle")
        let found = TelemetryManifest.detections(near: 2.0, in: [old])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].confidence, 0.7)
    }

    func test_trigger_namesWhyAFrameWasPicked() {
        let log = (0..<600).map { entry(Double($0) / 60) }
        XCTAssertEqual(TelemetryManifest.trigger(for: 0, log: log, shotTimes: []), "boundaries")
        XCTAssertEqual(TelemetryManifest.trigger(for: 4.1, log: log, shotTimes: [4.0]), "around_shot")
        XCTAssertEqual(TelemetryManifest.trigger(for: 3.0, log: log, shotTimes: []), "baseline")
        XCTAssertEqual(TelemetryManifest.trigger(for: 3.5, log: log, shotTimes: []), "flicker")
    }

    func test_manifest_usesSnakeCaseKeysAndRoundTrips() throws {
        let manifest = TelemetryManifest(
            sessionId: "S", sessionKind: "training", appVersion: "1.0", modelVersion: "m",
            sessionStartedAt: "2026-11-07T00:00:00Z", sessionDurationSec: 60, totalShots: 1, frameCount: 1,
            triggerSummary: ["around_shot": 1],
            frames: [.init(file: "frame_0000.jpg", timestampSec: 1, width: 960, height: 540,
                           trigger: "around_shot", detections: [])],
            shots: [.init(videoSec: 1, result: "make", autoConfidence: nil, needsReview: false, userCorrected: true)])
        let data = try TelemetryManifest.encoder().encode(manifest)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"schema_version\" : 2"))
        XCTAssertTrue(text.contains("\"user_corrected\" : true"))
        XCTAssertTrue(text.contains("\"around_shot\" : 1"))
        XCTAssertEqual(try JSONDecoder().decode(TelemetryManifest.self, from: data), manifest)
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
