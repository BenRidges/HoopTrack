// ShotReplayTests.swift (package-only)
// Replays synthetic detection logs and checks the scoring maths.

import XCTest
@testable import HoopTrack

final class ShotReplayTests: XCTestCase {

    private let rim = [0.45, 0.70, 0.10, 0.10]

    /// A logged make: lob from y 0.40 through the hoop at x 0.5, starting at `start`.
    private func shotLog(start: Double, x: (Double) -> Double = { _ in 0.5 }) -> [DetectionLogEntry] {
        stride(from: 0.0, through: 1.6, by: 1.0 / 60).map { t in
            let y = 0.40 + 2.0 * t - 1.6667 * t * t
            let ball: [Double]? = t <= 1.2 ? [x(t) - 0.015, y - 0.0267, 0.03, 0.0533] : nil
            var entry = DetectionLogEntry(timestampSec: start + t,
                                          ballConfidence: ball == nil ? nil : 0.8,
                                          ballBox: ball, rimConfidence: 0.9, rimBox: rim, state: "idle")
            entry.balls = ball.map { [$0 + [0.8]] } ?? []
            return entry
        }
    }

    func test_replay_callsLoggedShots() {
        let log = shotLog(start: 0) + shotLog(start: 3, x: { 0.5 + 0.13 * $0 })
        let calls = ShotReplay.run(log)
        XCTAssertEqual(calls.map(\.result), [.make, .miss])
        XCTAssertEqual(calls.first?.time ?? 0, 0.96, accuracy: 0.05)
    }

    func test_replay_readsOlderLogsWithOnlyTheTopBall() {
        let log = shotLog(start: 0).map { entry -> DetectionLogEntry in
            var old = entry
            old.balls = nil
            return old
        }
        XCTAssertEqual(ShotReplay.run(log).map(\.result), [.make])
    }

    func test_replay_netSwingRescuesABallLostAtTheRim() {
        // Off-centre and lost just above the rim (behind it, say), then the net jumps.
        let log = stride(from: 0.0, through: 2.0, by: 1.0 / 60).map { t -> DetectionLogEntry in
            let y = 0.40 + 2.0 * t - 1.6667 * t * t
            let ball: [Double]? = t <= 0.85 ? [0.57 - 0.015, y - 0.0267, 0.03, 0.0533] : nil
            var entry = DetectionLogEntry(timestampSec: t,
                                          ballConfidence: ball == nil ? nil : 0.8,
                                          ballBox: ball, rimConfidence: 0.9, rimBox: rim, state: "idle")
            entry.balls = ball.map { [$0 + [0.8]] } ?? []
            entry.netActivity = t >= 0.95 && t <= 1.6 ? 0.06 : 0.01
            return entry
        }
        XCTAssertEqual(ShotReplay.run(log, netCheck: false).map(\.result), [.miss])
        let calls = ShotReplay.run(log)
        XCTAssertEqual(calls.map(\.result), [.make])
        XCTAssertLessThan(calls[0].confidence, HoopTrack.CV.lowConfidence)
        XCTAssertEqual(calls[0].time, 0.85, accuracy: 0.02)
    }

    func test_replay_parsesJSONL() throws {
        let text = try shotLog(start: 0).map { try $0.jsonLine() }.joined() + "garbage line\n"
        XCTAssertEqual(ShotReplay.entries(fromJSONL: text).count, shotLog(start: 0).count)
    }

    func test_score_countsEveryKindOfError() {
        let calls = [
            ShotReplay.Call(time: 1.0, result: .make, confidence: 0.9),   // right
            ShotReplay.Call(time: 5.1, result: .make, confidence: 0.7),   // was a miss
            ShotReplay.Call(time: 20, result: .miss, confidence: 0.4),    // nothing there
        ]
        let labels = [
            ShotEvaluation.Label(time: 1.2, result: .make),
            ShotEvaluation.Label(time: 5.0, result: .miss),
            ShotEvaluation.Label(time: 9.0, result: .make),               // never called
        ]
        let report = ShotEvaluation.score(calls: calls, labels: labels)
        XCTAssertEqual(report.matched, 2)
        XCTAssertEqual(report.correct, 1)
        XCTAssertEqual(report.missesCalledMake, 1)
        XCTAssertEqual(report.makesCalledMiss, 0)
        XCTAssertEqual(report.phantomShots, 1)
        XCTAssertEqual(report.missedShots, 1)
        XCTAssertEqual(report.detectionRate, 2.0 / 3.0, accuracy: 1e-9)
    }

    func test_score_pairsClosestFirst() {
        // Two calls near one label: the closer one gets it.
        let calls = [ShotReplay.Call(time: 2.0, result: .miss, confidence: 0.9),
                     ShotReplay.Call(time: 2.9, result: .make, confidence: 0.9)]
        let report = ShotEvaluation.score(calls: calls, labels: [.init(time: 3.0, result: .make)])
        XCTAssertEqual(report.correct, 1)
        XCTAssertEqual(report.phantomShots, 1)
    }

    func test_labelsCSV() {
        let csv = """
        seconds,result
        # warm-up
        12.5, make
        20,x

        31.25,MISS
        40,maybe
        """
        XCTAssertEqual(ShotEvaluation.labels(fromCSV: csv),
                       [.init(time: 12.5, result: .make), .init(time: 20, result: .miss),
                        .init(time: 31.25, result: .miss)])
    }
}
