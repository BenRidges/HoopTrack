// BenchmarkFloorTests.swift (package-only)
// Regression guards on the simulated benchmark: fixed seeds, floors set a
// little below what the tracker scores today. A tracker change that makes
// these worse fails here; one that makes them better should raise the
// floors. `swift run shot-sim` gives the full picture.

import XCTest
@testable import HoopTrack
@testable import ShotSimulation

final class BenchmarkFloorTests: XCTestCase {

    private func score(_ name: String, shots: Int, seed: UInt64 = 1,
                       edit: (inout Scenario) -> Void = { _ in }) -> ScenarioScore {
        guard var s = Scenario.named(name) else { fatalError("no scenario \(name)") }
        edit(&s)
        let run = Simulator.run(s, shots: shots, seed: seed)
        let score = Benchmark.score(run, calls: Benchmark.calls(run))
        // On failure, the trace says what went wrong.
        addTeardownBlock { [weak self] in
            guard let self, (self.testRun?.totalFailureCount ?? 0) > 0 else { return }
            let replay = TraceReplay.run(run.entries)
            print(TraceReport.failures(run, replay: replay, limit: 5).joined(separator: "\n\n"))
        }
        return score
    }

    /// The sanity check: a clean swish, seen from a sensible distance, is
    /// always found and always a make.
    func test_cleanSwish_isAlwaysAMake() {
        let s = score("swish-clean", shots: 15) {
            $0.placement = .behindShooter(back: 2.5...3.5, height: 1.2...1.5)
        }
        XCTAssertEqual(s.report.labelled, 15)
        XCTAssertEqual(s.report.matched, 15)
        XCTAssertEqual(s.report.correct, 15)
        XCTAssertEqual(s.report.phantomShots, 0)
    }

    func test_naturalShooting_realisticDetector() {
        let s = score("mixed-real", shots: 30)
        XCTAssertGreaterThanOrEqual(s.report.detectionRate, FLOOR_MIXED_DETECTED)
        XCTAssertGreaterThanOrEqual(s.report.callAccuracy, FLOOR_MIXED_RIGHT)
        XCTAssertLessThanOrEqual(s.report.phantomShots, CEIL_MIXED_PHANTOMS)
    }

    func test_cameraThreeMetresBack_findsEveryShot() {
        let s = score("camback3-real", shots: 20)
        XCTAssertGreaterThanOrEqual(s.report.detectionRate, FLOOR_CAMBACK3_DETECTED)
        XCTAssertGreaterThanOrEqual(s.report.callAccuracy, FLOOR_CAMBACK3_RIGHT)
    }

    func test_dribbling_startsNoShots() {
        let s = score("dribble-real", shots: 10)     // 60 s of dribbling
        XCTAssertLessThanOrEqual(s.report.phantomShots, CEIL_DRIBBLE_PHANTOMS)
    }

    func test_passing_phantomsStayBounded() {
        let s = score("pass-real", shots: 15)        // 90 s of passing
        XCTAssertLessThanOrEqual(s.phantomsPerMinute, CEIL_PASS_PHANTOMS_PER_MIN)
    }
}

// Measured with seed 1 when written; floors sit a little below. A change to
// the simulator itself (physics, noise, choreography) moves these too —
// re-measure with `swift run shot-sim --scenario <name> --shots <n>`.
private let FLOOR_MIXED_DETECTED = 0.85        // measured 27/30 = 0.90
private let FLOOR_MIXED_RIGHT = 0.80           // measured 23/27 = 0.85
private let CEIL_MIXED_PHANTOMS = 3            // measured 1
private let FLOOR_CAMBACK3_DETECTED = 0.95     // measured 20/20
private let FLOOR_CAMBACK3_RIGHT = 0.85        // measured 18/20 = 0.90
private let CEIL_DRIBBLE_PHANTOMS = 1          // measured 0 in 60 s
private let CEIL_PASS_PHANTOMS_PER_MIN = 4.0   // measured 2.7/min
