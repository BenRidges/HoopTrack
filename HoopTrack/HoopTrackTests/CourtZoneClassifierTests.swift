// HoopTrackTests/CourtZoneClassifierTests.swift
import XCTest
@testable import HoopTrack

final class CourtZoneClassifierTests: XCTestCase {

    // Paint: centred horizontally, below free throw line
    func testPaintCentre() {
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.5, courtY: 0.15), .paint)
    }

    func testPaintLeftEdge() {
        // Just inside paint width (32% of court = ±16% from centre = 0.34–0.66)
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.35, courtY: 0.20), .paint)
    }

    func testPaintRightEdge() {
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.65, courtY: 0.20), .paint)
    }

    // Free throw: centre horizontally, at free throw line Y ± 5%
    func testFreeThrowExact() {
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.5, courtY: 0.38), .freeThrow)
    }

    func testFreeThrowWithinTolerance() {
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.5, courtY: 0.40), .freeThrow)
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.5, courtY: 0.36), .freeThrow)
    }

    // Corner three: outside paint width, below corner depth threshold (28% from baseline)
    func testCornerThreeLeft() {
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.05, courtY: 0.15), .cornerThree)
    }

    func testCornerThreeRight() {
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.95, courtY: 0.15), .cornerThree)
    }

    // Mid-range: inside 3pt arc, outside paint
    // (0.20, 0.45) would be outside the arc; use (0.30, 0.35) which is clearly elbow mid-range
    func testMidRangeLeft() {
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.30, courtY: 0.35), .midRange)
    }

    func testMidRangeRight() {
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.70, courtY: 0.35), .midRange)
    }

    // Above-break three: outside 3pt arc radius, above corner depth
    func testAboveBreakThreeLeft() {
        // Arc radius = 0.47. Distance from (0.5, 0.0):
        // x=0.05, y=0.50 → dist = sqrt(0.45²+0.50²) ≈ 0.67 > 0.47
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.05, courtY: 0.50), .aboveBreakThree)
    }

    func testAboveBreakThreeCentre() {
        // Straight on: x=0.5, y=0.50 → dist = 0.50 > 0.47
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.5, courtY: 0.50), .aboveBreakThree)
    }

    // Boundary: just outside paint → mid-range, not paint
    func testJustOutsidePaintX() {
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.33, courtY: 0.20), .midRange)
    }
}
