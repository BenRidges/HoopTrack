// RealClipFixtureTests.swift (package-only)
// Regression floors on real footage. Tests/Fixtures/RealClips holds the
// detections.jsonl the shipped pipeline wrote for four hand-labelled CC BY
// clips (118 shots; see ATTRIBUTION.md there), gzipped. Each is replayed
// through ShotReplay.run — what shot-eval does — and scored against its
// labels. The floors are what the tracker scores today: a change that does
// worse on any clip fails here; one that does better should raise them.
//
// The logs were written by cv-replay on a Mac, so the detector's output is
// fixed in them: these hold the tracker (and the replay) to account, not
// the model.

import XCTest
import Foundation
@testable import HoopTrack

final class RealClipFixtureTests: XCTestCase {

    private struct Floor {
        let labelled: Int
        /// Labelled shots called at all (ShotEvaluation.Report.matched).
        let detected: Int
        /// Of those, called right.
        let right: Int
        /// Calls with no labelled shot nearby.
        let maxPhantoms: Int
    }

    /// Measured on the logs as committed (cv-replay at this commit's
    /// pipeline); see the commit message for the full scores.
    private let floors: [String: Floor] = [
        "somorin-dusk-cam1":    Floor(labelled: 27, detected: FLOOR_CAM1_DET, right: FLOOR_CAM1_RIGHT, maxPhantoms: CEIL_CAM1_PHANTOMS),
        "somorin-dusk-cam2":    Floor(labelled: 29, detected: FLOOR_CAM2_DET, right: FLOOR_CAM2_RIGHT, maxPhantoms: CEIL_CAM2_PHANTOMS),
        "alec-park-2020-07-11": Floor(labelled: 22, detected: FLOOR_A0711_DET, right: FLOOR_A0711_RIGHT, maxPhantoms: CEIL_A0711_PHANTOMS),
        "alec-park-2020-08-01": Floor(labelled: 40, detected: FLOOR_A0801_DET, right: FLOOR_A0801_RIGHT, maxPhantoms: CEIL_A0801_PHANTOMS),
    ]

    /// Tests/Fixtures/RealClips, found from this file so `swift test` finds
    /// it from any working directory (CI runs it on macOS).
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // HoopTrackTests
        .deletingLastPathComponent()      // Tests
        .appendingPathComponent("Fixtures/RealClips", isDirectory: true)

    func test_somorinDuskCam1_holdsItsFloor() throws { try check("somorin-dusk-cam1") }
    func test_somorinDuskCam2_holdsItsFloor() throws { try check("somorin-dusk-cam2") }
    func test_alecPark20200711_holdsItsFloor() throws { try check("alec-park-2020-07-11") }
    func test_alecPark20200801_holdsItsFloor() throws { try check("alec-park-2020-08-01") }

    func test_fixtures_logEveryBasket() throws {
        // Written after the log kept every basket ("rs"), so the replay's
        // hoop smoother chooses as the app's did.
        let entries = try Self.entries("somorin-dusk-cam1")
        XCTAssertTrue(entries.allSatisfy { $0.baskets != nil })
    }

    // MARK: - Helpers

    private func check(_ clip: String) throws {
        let floor = try XCTUnwrap(floors[clip])
        let entries = try Self.entries(clip)
        let labelsText = try String(contentsOf: Self.directory.appendingPathComponent("\(clip).labels.csv"), encoding: .utf8)
        let labels = ShotEvaluation.labels(fromCSV: labelsText)
        XCTAssertEqual(labels.count, floor.labelled, "\(clip): labels")

        let report = ShotEvaluation.score(calls: ShotReplay.run(entries), labels: labels)
        let summary = "\(clip):\n\(report.summary)"
        XCTAssertGreaterThanOrEqual(report.matched, floor.detected, summary)
        XCTAssertGreaterThanOrEqual(report.correct, floor.right, summary)
        XCTAssertLessThanOrEqual(report.phantomShots, floor.maxPhantoms, summary)
    }

    /// The clip's log, decompressed with the system's gzip (on macOS and
    /// Linux alike) and decoded in one go.
    private static func entries(_ clip: String) throws -> [DetectionLogEntry] {
        let file = directory.appendingPathComponent("\(clip).detections.jsonl.gz")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw FixtureError("missing fixture \(file.path)")
        }
        guard let gzip = ["/usr/bin/gzip", "/bin/gzip"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw FixtureError("no gzip in /usr/bin or /bin")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gzip)
        process.arguments = ["-dc", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError("gzip -dc \(file.lastPathComponent) failed") }

        // One JSON array instead of a decoder per line: the four logs are
        // ~64k lines, and this keeps the test to a few seconds.
        let lines = data.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }
        var array = Data("[".utf8)
        for (i, line) in lines.enumerated() {
            if i > 0 { array.append(UInt8(ascii: ",")) }
            array.append(contentsOf: line)
        }
        array.append(UInt8(ascii: "]"))
        let entries = try JSONDecoder().decode([DetectionLogEntry].self, from: array)
        XCTAssertEqual(entries.count, lines.count)
        return entries
    }

    private struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

// Measured on the committed logs (ShotReplay.run, the same calls the live
// pipeline made on each: cv-replay's log-replay consistency was MATCH on
// all four). The logs were rewritten on 2026-11-07 by the pipeline after
// the cv-fix round (rim-shaped boxes, physical link limits, gravity in the
// ball filter, depth doubts), since the tracker decides when the detector
// runs on a close-up crop and so what it sees. These are today's scores,
// not targets: raise them as the tracker improves. Before the round:
// cam1 27/25/0, cam2 26/25/9, alec-07-11 18/18/12, alec-08-01 6/4/5
// (detected / right / phantoms).
private let FLOOR_CAM1_DET = 27       // 27/27 detected
private let FLOOR_CAM1_RIGHT = 27     // 27/27 right
private let CEIL_CAM1_PHANTOMS = 0
private let FLOOR_CAM2_DET = 29       // 29/29 (rim-as-ball phantoms no longer block shots)
private let FLOOR_CAM2_RIGHT = 29     // 29/29
private let CEIL_CAM2_PHANTOMS = 2
private let FLOOR_A0711_DET = 17      // 17/22: 153.05 was a lucky match before (a phantom's
                                      // close-up crop happened to catch the real release);
                                      // releases against the trees are a detector limit
private let FLOOR_A0711_RIGHT = 17    // 17/17
private let CEIL_A0711_PHANTOMS = 6
private let FLOOR_A0801_DET = 6       // 6/40: the model calls this rim a ball until 430 s
private let FLOOR_A0801_RIGHT = 2     // 2/6: hoop found in 1% of frames (camera far below
                                      // the rim); 464.05 miss is a flagged make, 559.50 a
                                      // stale partial hoop box (see cv-review-2026-11.md)
private let CEIL_A0801_PHANTOMS = 3
