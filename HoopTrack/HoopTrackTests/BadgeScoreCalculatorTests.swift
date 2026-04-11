// BadgeScoreCalculatorTests.swift
import XCTest
@testable import HoopTrack

final class BadgeScoreCalculatorTests: XCTestCase {

    // MARK: - affectedDrillTypes

    func test_affectedDrillTypes_deadeye_onlyFreeShoot() {
        XCTAssertEqual(BadgeScoreCalculator.affectedDrillTypes(for: .deadeye), [.freeShoot])
    }

    func test_affectedDrillTypes_handles_onlyDribble() {
        XCTAssertEqual(BadgeScoreCalculator.affectedDrillTypes(for: .handles), [.dribble])
    }

    func test_affectedDrillTypes_explosive_onlyAgility() {
        XCTAssertEqual(BadgeScoreCalculator.affectedDrillTypes(for: .explosive), [.agility])
    }

    func test_affectedDrillTypes_ironMan_allDrillTypes() {
        let types = BadgeScoreCalculator.affectedDrillTypes(for: .ironMan)
        XCTAssertEqual(types, [.freeShoot, .dribble, .agility, .fullWorkout])
    }
}
