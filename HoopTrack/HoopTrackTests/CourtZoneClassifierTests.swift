// HoopTrackTests/CourtZoneClassifierTests.swift
// Positions are written in feet (from the left sideline, from the baseline)
// on a 50 × 47 ft half court, then normalised — the same model the shot
// chart draws, with the basket centre at (25, 5.25).
import XCTest
@testable import HoopTrack

final class CourtZoneClassifierTests: XCTestCase {

    private func zone(_ xFt: Double, _ yFt: Double, arc: Double = 23.75) -> CourtZone {
        CourtZoneClassifier.classify(courtX: xFt / 50, courtY: yFt / 47, threePointDistanceFt: arc)
    }

    func test_underTheBasket_isPaint() {
        XCTAssertEqual(zone(25, 6), .paint)
    }

    func test_laneEdges_arePaint_justOutsideIsMidRange() {
        XCTAssertEqual(zone(17.5, 10), .paint)
        XCTAssertEqual(zone(32.5, 10), .paint)
        XCTAssertEqual(zone(16.5, 10), .midRange)
    }

    func test_freeThrowLine_isFreeThrow() {
        XCTAssertEqual(zone(25, 19), .freeThrow)
        XCTAssertEqual(zone(25, 20.5), .freeThrow)
        XCTAssertEqual(zone(25, 17.5), .freeThrow)
    }

    func test_elbowAndTopOfKey_areMidRange() {
        XCTAssertEqual(zone(15, 19), .midRange)
        XCTAssertEqual(zone(25, 24), .midRange)
    }

    func test_corners_areCornerThree() {
        XCTAssertEqual(zone(1.5, 4), .cornerThree)
        XCTAssertEqual(zone(48.5, 10), .cornerThree)
    }

    func test_shortCorner_isMidRange() {
        XCTAssertEqual(zone(6, 4), .midRange)
    }

    func test_topOfArc_isAboveBreakThree() {
        XCTAssertEqual(zone(25, 5.25 + 24.5), .aboveBreakThree)
        XCTAssertEqual(zone(25, 5.25 + 23), .midRange)
    }

    func test_wing_isAboveBreakThree() {
        // 45° wing, 25 ft out.
        let d = 25.0 / 2.0.squareRoot()
        XCTAssertEqual(zone(25 + d, 5.25 + d), .aboveBreakThree)
    }

    func test_shorterArc_movesTheLineIn() {
        // 21 ft straight out: a two on an NBA court, a three on a casual court.
        XCTAssertEqual(zone(25, 5.25 + 21), .midRange)
        XCTAssertEqual(zone(25, 5.25 + 21, arc: CourtType.halfCourt.threePointDistanceFt), .aboveBreakThree)
    }

    func test_invalidInput_isUnknown() {
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: .nan, courtY: 0.5), .unknown)
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 0.5, courtY: -0.1), .unknown)
        XCTAssertEqual(CourtZoneClassifier.classify(courtX: 1.2, courtY: 0.5), .unknown)
    }

    func test_normalisedRoundTrip_matchesOffsets() {
        let p = CourtGeometry.normalised(lateralFt: -6, depthFt: 10)
        let back = CourtGeometry.offsetFromBasket(courtX: p.courtX, courtY: p.courtY)
        XCTAssertEqual(back.lateralFt, -6, accuracy: 1e-9)
        XCTAssertEqual(back.depthFt, 10, accuracy: 1e-9)
    }
}
