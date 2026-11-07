// SimulatorTests.swift (package-only)
// The simulator is deterministic, writes logs shot-eval reads back the same
// way, and the trace replay makes exactly ShotReplay.run's calls.

import XCTest
@testable import HoopTrack
@testable import ShotSimulation

final class SimulatorTests: XCTestCase {

    private func scenario(_ name: String) -> Scenario {
        guard let s = Scenario.named(name) else { fatalError("no scenario \(name)") }
        return s
    }

    func test_sameSeed_sameFootage() {
        let a = Simulator.run(scenario("mixed-real"), shots: 3, seed: 7)
        let b = Simulator.run(scenario("mixed-real"), shots: 3, seed: 7)
        XCTAssertEqual(a.entries, b.entries)
        XCTAssertEqual(a.labels, b.labels)
        let c = Simulator.run(scenario("mixed-real"), shots: 3, seed: 8)
        XCTAssertNotEqual(a.labels, c.labels)
    }

    func test_noiseLevels_shareTheSameShots() {
        // Same world key and seed: only the detector differs.
        let clean = Simulator.run(scenario("mixed-clean"), shots: 4, seed: 3)
        let harsh = Simulator.run(scenario("mixed-harsh"), shots: 4, seed: 3)
        XCTAssertEqual(clean.labels, harsh.labels)
        XCTAssertNotEqual(clean.entries.count, 0)
    }

    func test_dumpRoundTrip_scoresTheSame() throws {
        let run = Simulator.run(scenario("mixed-real"), shots: 6, seed: 2)
        let entries = ShotReplay.entries(fromJSONL: try Dump.jsonl(run.entries))
        XCTAssertEqual(entries.count, run.entries.count)
        let labels = ShotEvaluation.labels(fromCSV: Dump.labelsCSV(run.labels))
        XCTAssertEqual(labels.count, run.labels.count)
        let direct = ShotEvaluation.score(calls: ShotReplay.run(run.entries), labels: run.labels)
        let viaFiles = ShotEvaluation.score(calls: ShotReplay.run(entries), labels: labels)
        XCTAssertEqual(direct, viaFiles)
    }

    func test_traceReplay_makesShotReplaysCalls() {
        for name in ["mixed-real", "pass-real", "rebounder-real"] {
            let run = Simulator.run(scenario(name), shots: 3, seed: 5)
            let expected = ShotReplay.run(run.entries)
            let traced = TraceReplay.run(run.entries).calls
            XCTAssertEqual(traced, expected, name)
        }
    }

    func test_liveApp_andReplay_agree() {
        // One basket in view: the replay sees what the app saw.
        let run = Simulator.run(scenario("mixed-real"), shots: 6, seed: 4)
        XCTAssertEqual(run.liveCalls, ShotReplay.run(run.entries))
    }

    func test_logLooksLikeThePhones() {
        let run = Simulator.run(scenario("mixed-real"), shots: 3, seed: 1)
        let times = run.entries.map(\.timestampSec)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(times[1] - times[0], 1.0 / 60, accuracy: 1e-9)
        XCTAssertTrue(run.entries.contains { $0.rimBox != nil })
        XCTAssertTrue(run.entries.contains { $0.netActivity != nil })
        XCTAssertTrue(run.entries.contains { $0.region != nil }, "crops while a shot is in flight")
        for entry in run.entries {
            for ball in entry.balls ?? [] {
                XCTAssertEqual(ball.count, 5)
                XCTAssertGreaterThanOrEqual(ball[4], Double(HoopTrack.CV.ballConfidence))
            }
            XCTAssertLessThanOrEqual(entry.balls?.count ?? 0, 4)
        }
    }

    func test_thermal_logsEveryOtherFrame() {
        let run = Simulator.run(scenario("thermal-real"), shots: 2, seed: 1)
        XCTAssertEqual(run.entries[1].timestampSec - run.entries[0].timestampSec, 2.0 / 60, accuracy: 1e-9)
    }
}
