// HoopTrackTests/ExtensionsTests.swift
import XCTest
@testable import HoopTrack

final class ExtensionsTests: XCTestCase {

    func test_counted_singularOnlyForOne() {
        XCTAssertEqual(0.counted("day"), "0 days")
        XCTAssertEqual(1.counted("day"), "1 day")
        XCTAssertEqual(7.counted("game"), "7 games")
        XCTAssertEqual(2.counted("match", plural: "matches"), "2 matches")
    }

    func test_clockText() {
        XCTAssertEqual(TimeInterval(0).clockText, "0:00")
        XCTAssertEqual(TimeInterval(247.9).clockText, "4:07")
    }
}
