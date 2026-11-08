// HoopTrackTests/VideoCutsTests.swift
// Long breaks are cut from the session video; shot times still find their
// place in the file.

import XCTest
@testable import HoopTrack

final class VideoCutsTests: XCTestCase {

    private let frame = 1.0 / 60

    func test_noGaps_nothingMoves() {
        var cuts = VideoCuts()
        XCTAssertEqual(cuts.writing(at: 100, frameInterval: frame), 0)
        XCTAssertEqual(cuts.writing(at: 100 + frame, frameInterval: frame), 0)
        XCTAssertEqual(cuts.fileOffset(of: 130, start: 100), 30, accuracy: 1e-9)
    }

    func test_aGap_isClosedToOneFrame() {
        var cuts = VideoCuts()
        _ = cuts.writing(at: 100, frameInterval: frame)
        _ = cuts.writing(at: 110, frameInterval: frame)        // last frame before the break
        cuts.skipped()
        cuts.skipped()
        let shift = cuts.writing(at: 410, frameInterval: frame) // five minutes later
        XCTAssertEqual(shift, 300 - frame, accuracy: 1e-9)
        XCTAssertEqual(cuts.total, 300 - frame, accuracy: 1e-9)
        // The next frame keeps the same shift.
        XCTAssertEqual(cuts.writing(at: 410 + frame, frameInterval: frame), 300 - frame, accuracy: 1e-9)
    }

    func test_timesAfterAGap_findTheirPlaceInTheFile() {
        var cuts = VideoCuts()
        _ = cuts.writing(at: 100, frameInterval: frame)
        _ = cuts.writing(at: 110, frameInterval: frame)
        cuts.skipped()
        _ = cuts.writing(at: 410, frameInterval: frame)
        XCTAssertEqual(cuts.fileOffset(of: 105, start: 100), 5, accuracy: 1e-9, "before the gap: unchanged")
        XCTAssertEqual(cuts.fileOffset(of: 412, start: 100), 12 + frame, accuracy: 1e-9)
        XCTAssertEqual(cuts.fileOffset(of: 300, start: 100), 10, accuracy: 1e-9, "inside the gap: where it was closed")
    }

    func test_twoGaps_add() {
        var cuts = VideoCuts()
        _ = cuts.writing(at: 0, frameInterval: frame)
        cuts.skipped()
        _ = cuts.writing(at: 100, frameInterval: frame)
        cuts.skipped()
        _ = cuts.writing(at: 300, frameInterval: frame)
        XCTAssertEqual(cuts.total, 300 - 2 * frame, accuracy: 1e-9)
        XCTAssertEqual(cuts.fileOffset(of: 301, start: 0), 1 + 2 * frame, accuracy: 1e-9)
    }

    func test_skippingBeforeTheFirstFrame_cutsNothing() {
        var cuts = VideoCuts()
        cuts.skipped()
        XCTAssertEqual(cuts.writing(at: 50, frameInterval: frame), 0)
        XCTAssertEqual(cuts.total, 0)
    }
}
