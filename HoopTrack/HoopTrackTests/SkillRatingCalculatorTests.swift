// SkillRatingCalculatorTests.swift
import XCTest
@testable import HoopTrack

final class SkillRatingCalculatorTests: XCTestCase {

    // MARK: - normalize

    func test_normalize_midpoint_returns50() {
        XCTAssertEqual(SkillRatingCalculator.normalize(5, min: 0, max: 10), 50, accuracy: 0.001)
    }

    func test_normalize_atMin_returns0() {
        XCTAssertEqual(SkillRatingCalculator.normalize(0, min: 0, max: 10), 0, accuracy: 0.001)
    }

    func test_normalize_atMax_returns100() {
        XCTAssertEqual(SkillRatingCalculator.normalize(10, min: 0, max: 10), 100, accuracy: 0.001)
    }

    func test_normalize_belowMin_clampsTo0() {
        XCTAssertEqual(SkillRatingCalculator.normalize(-5, min: 0, max: 10), 0, accuracy: 0.001)
    }

    func test_normalize_aboveMax_clampsTo100() {
        XCTAssertEqual(SkillRatingCalculator.normalize(15, min: 0, max: 10), 100, accuracy: 0.001)
    }

    func test_normalize_equalMinMax_returns0() {
        XCTAssertEqual(SkillRatingCalculator.normalize(5, min: 5, max: 5), 0, accuracy: 0.001)
    }

    // MARK: - shootingScore

    func test_shootingScore_perfect_fgOnly_returns100() {
        let score = SkillRatingCalculator.shootingScore(
            fgPct: 100, threePct: nil, ftPct: nil,
            releaseAngleDeg: nil, releaseAngleStdDev: nil,
            releaseTimeMs: nil, shotSpeedMph: nil,
            shotSpeedStdDev: nil, threeAttemptFraction: nil
        )
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 100, accuracy: 0.1)
    }

    func test_shootingScore_zero_fgOnly_returns0() {
        let score = SkillRatingCalculator.shootingScore(
            fgPct: 0, threePct: nil, ftPct: nil,
            releaseAngleDeg: nil, releaseAngleStdDev: nil,
            releaseTimeMs: nil, shotSpeedMph: nil,
            shotSpeedStdDev: nil, threeAttemptFraction: nil
        )
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 0, accuracy: 0.1)
    }

    func test_shootingScore_optimalAngle_boostsScore() {
        let withAngle = SkillRatingCalculator.shootingScore(
            fgPct: 50, threePct: nil, ftPct: nil,
            releaseAngleDeg: 50, releaseAngleStdDev: nil,
            releaseTimeMs: nil, shotSpeedMph: nil,
            shotSpeedStdDev: nil, threeAttemptFraction: nil
        )!
        let withoutAngle = SkillRatingCalculator.shootingScore(
            fgPct: 50, threePct: nil, ftPct: nil,
            releaseAngleDeg: nil, releaseAngleStdDev: nil,
            releaseTimeMs: nil, shotSpeedMph: nil,
            shotSpeedStdDev: nil, threeAttemptFraction: nil
        )!
        XCTAssertGreaterThanOrEqual(withAngle, withoutAngle)
    }

    func test_shootingScore_badAngle_penalisesScore() {
        let badAngle = SkillRatingCalculator.shootingScore(
            fgPct: 50, threePct: nil, ftPct: nil,
            releaseAngleDeg: 20, releaseAngleStdDev: nil,
            releaseTimeMs: nil, shotSpeedMph: nil,
            shotSpeedStdDev: nil, threeAttemptFraction: nil
        )!
        let noAngle = SkillRatingCalculator.shootingScore(
            fgPct: 50, threePct: nil, ftPct: nil,
            releaseAngleDeg: nil, releaseAngleStdDev: nil,
            releaseTimeMs: nil, shotSpeedMph: nil,
            shotSpeedStdDev: nil, threeAttemptFraction: nil
        )!
        XCTAssertLessThan(badAngle, noAngle)
    }
}
