// HoopTrackTests/CVPipelineStateTests.swift
import XCTest
@testable import HoopTrack

final class CVPipelineStateTests: XCTestCase {

    func testShotDotColorMake() {
        XCTAssertEqual(ShotResult.make.dotColorName, "shotDotGreen")
    }

    func testShotDotColorMiss() {
        XCTAssertEqual(ShotResult.miss.dotColorName, "shotDotRed")
    }

    func testShotDotColorPending() {
        XCTAssertEqual(ShotResult.pending.dotColorName, "shotDotGray")
    }
}
