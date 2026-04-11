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

    // MARK: - ballHandlingScore

    func test_ballHandlingScore_noDribbles_returnsNil() {
        XCTAssertNil(SkillRatingCalculator.ballHandlingScore(
            avgBPS: nil, maxBPS: nil, handBalance: nil, combos: 0, totalDribbles: 0))
    }

    func test_ballHandlingScore_eliteBPS_returnsHighScore() {
        let score = SkillRatingCalculator.ballHandlingScore(
            avgBPS: 8.0, maxBPS: 10.0, handBalance: 0.5,
            combos: 15, totalDribbles: 200)
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score!, 70)
    }

    func test_ballHandlingScore_equalHandBalance_maximisesHandScore() {
        let balanced = SkillRatingCalculator.ballHandlingScore(
            avgBPS: 5.0, maxBPS: 7.0, handBalance: 0.5, combos: 5, totalDribbles: 100)!
        let unbalanced = SkillRatingCalculator.ballHandlingScore(
            avgBPS: 5.0, maxBPS: 7.0, handBalance: 0.9, combos: 5, totalDribbles: 100)!
        XCTAssertGreaterThan(balanced, unbalanced)
    }

    // MARK: - athleticismScore

    func test_athleticismScore_bothNil_returnsNil() {
        XCTAssertNil(SkillRatingCalculator.athleticismScore(verticalJumpCm: nil, shuttleRunSec: nil))
    }

    func test_athleticismScore_eliteVertical_returnsHigh() {
        let score = SkillRatingCalculator.athleticismScore(verticalJumpCm: 90, shuttleRunSec: nil)
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 100, accuracy: 1.0)
    }

    func test_athleticismScore_fastShuttle_returnsHigh() {
        let score = SkillRatingCalculator.athleticismScore(verticalJumpCm: nil, shuttleRunSec: 5.5)
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 100, accuracy: 1.0)
    }

    func test_athleticismScore_jumpOnlyUsesFullWeight() {
        let jumpOnly = SkillRatingCalculator.athleticismScore(verticalJumpCm: 55, shuttleRunSec: nil)!
        let bothData = SkillRatingCalculator.athleticismScore(verticalJumpCm: 55, shuttleRunSec: 7.5)!
        XCTAssertNotEqual(jumpOnly, bothData, accuracy: 5.0)
    }
}
