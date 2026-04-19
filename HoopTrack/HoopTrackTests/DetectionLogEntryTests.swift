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
        XCTAssertEqual(decoded.ballConfidence ?? -1, 0.82, accuracy: 1e-6)
        XCTAssertEqual(decoded.ballBox, [0.41, 0.62, 0.08, 0.09])
        XCTAssertEqual(decoded.rimConfidence ?? -1, 0.91, accuracy: 1e-6)
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
