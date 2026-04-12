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

    // MARK: - Shooting badges

    func test_deadeye_perfectFG_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.deadeye(fgPct: 100, shotsAttempted: 20)!, 100, accuracy: 0.1)
    }
    func test_deadeye_tooFewShots_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.deadeye(fgPct: 50, shotsAttempted: 19))
    }

    func test_sniper_zeroStdDev_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.sniper(releaseAngleStdDev: 0, shotsAttempted: 20)!, 100, accuracy: 0.1)
    }
    func test_sniper_nilStdDev_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.sniper(releaseAngleStdDev: nil, shotsAttempted: 20))
    }
    func test_sniper_tooFewShots_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.sniper(releaseAngleStdDev: 2, shotsAttempted: 15))
    }

    func test_quickTrigger_eliteTime_returnsHigh() {
        let score = BadgeScoreCalculator.quickTrigger(avgReleaseTimeMs: 300, shotsAttempted: 20)!
        XCTAssertEqual(score, 100, accuracy: 0.1)
    }
    func test_quickTrigger_nilTime_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.quickTrigger(avgReleaseTimeMs: nil, shotsAttempted: 20))
    }

    func test_beyondTheArc_perfect3PT_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.beyondTheArc(threePct: 100, threeAttempts: 10)!, 100, accuracy: 0.1)
    }
    func test_beyondTheArc_fewerThan10_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.beyondTheArc(threePct: 50, threeAttempts: 9))
    }

    func test_charityStripe_perfectFT_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.charityStripe(ftPct: 100, ftAttempts: 10)!, 100, accuracy: 0.1)
    }
    func test_charityStripe_fewerThan10_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.charityStripe(ftPct: 80, ftAttempts: 9))
    }

    func test_threeLevelScorer_allZonesAbsent_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.threeLevelScorer(
            paintFGPct: nil, paintAttempts: 0,
            midFGPct: nil, midAttempts: 0,
            threeFGPct: nil, threeAttempts: 0))
    }
    func test_threeLevelScorer_oneZonePresent_returnsScore() {
        let score = BadgeScoreCalculator.threeLevelScorer(
            paintFGPct: 100, paintAttempts: 5,
            midFGPct: nil, midAttempts: 0,
            threeFGPct: nil, threeAttempts: 0)
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 100.0/3.0, accuracy: 1.0)
    }

    func test_hotHand_streak15_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.hotHand(longestMakeStreak: 15), 100, accuracy: 0.1)
    }
    func test_hotHand_streak0_returns0() {
        XCTAssertEqual(BadgeScoreCalculator.hotHand(longestMakeStreak: 0), 0, accuracy: 0.1)
    }

    // MARK: - Ball Handling badges

    func test_handles_eliteBPS_returnsHigh() {
        let score = BadgeScoreCalculator.handles(avgBPS: 8.0)!
        XCTAssertEqual(score, 100, accuracy: 1.0)
    }
    func test_handles_nilBPS_returnsNil() { XCTAssertNil(BadgeScoreCalculator.handles(avgBPS: nil)) }

    func test_ambidextrous_equalHands_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.ambidextrous(handBalance: 0.5, totalDribbles: 100)!, 100, accuracy: 0.1)
    }
    func test_ambidextrous_fewerThan100_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.ambidextrous(handBalance: 0.5, totalDribbles: 99))
    }

    func test_comboKing_50combos_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.comboKing(combos: 50, totalDribbles: 200)!, 100, accuracy: 0.1)
    }
    func test_comboKing_fewerThan100Dribbles_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.comboKing(combos: 10, totalDribbles: 99))
    }

    func test_floorGeneral_highRatio_returnsHigh() {
        let score = BadgeScoreCalculator.floorGeneral(avgBPS: 7.0, maxBPS: 8.0, durationSeconds: 60)!
        XCTAssertGreaterThan(score, 50)
    }
    func test_floorGeneral_underMinDuration_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.floorGeneral(avgBPS: 5.0, maxBPS: 7.0, durationSeconds: 59))
    }
    func test_floorGeneral_avgBPSUnder3_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.floorGeneral(avgBPS: 2.9, maxBPS: 5.0, durationSeconds: 120))
    }

    func test_ballWizard_career50k_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.ballWizard(careerTotalDribbles: 50_000), 100, accuracy: 0.1)
    }

    // MARK: - Athleticism badges

    func test_posterizer_nilJump_returnsNil() { XCTAssertNil(BadgeScoreCalculator.posterizer(avgVerticalJumpCm: nil)) }
    func test_posterizer_eliteJump_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.posterizer(avgVerticalJumpCm: 90)!, 100, accuracy: 0.1)
    }

    func test_lightning_nilShuttle_returnsNil() { XCTAssertNil(BadgeScoreCalculator.lightning(bestShuttleRunSec: nil)) }
    func test_lightning_eliteShuttle_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.lightning(bestShuttleRunSec: 5.5)!, 100, accuracy: 0.1)
    }

    func test_explosive_100rating_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.explosive(ratingAthleticism: 100), 100, accuracy: 0.1)
    }

    func test_highFlyer_prJump90_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.highFlyer(prVerticalJumpCm: 90), 100, accuracy: 0.1)
    }

    // MARK: - Consistency badges

    func test_automatic_fewerThan3_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.automatic(recentFGPcts: [50, 55]))
    }
    func test_automatic_perfectConsistency_returnsHigh() {
        let score = BadgeScoreCalculator.automatic(recentFGPcts: [50, 50, 50, 50, 50])!
        XCTAssertEqual(score, 100, accuracy: 0.1)
    }

    func test_metronome_fewerThan10Sessions_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.metronome(avgReleaseAngleStdDev: 2.0, sessionCount: 9))
    }
    func test_metronome_zeroStdDev_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.metronome(avgReleaseAngleStdDev: 0, sessionCount: 10)!, 100, accuracy: 0.1)
    }

    func test_iceVeins_fewerThan50FT_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.iceVeins(careerFTPct: 90, totalFTAttempts: 49))
    }
    func test_iceVeins_perfect_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.iceVeins(careerFTPct: 100, totalFTAttempts: 50)!, 100, accuracy: 0.1)
    }

    func test_reliable_streak12_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.reliable(consecutiveSessionsAbove40FG: 12), 100, accuracy: 0.1)
    }
    func test_reliable_streak0_returns0() {
        XCTAssertEqual(BadgeScoreCalculator.reliable(consecutiveSessionsAbove40FG: 0), 0, accuracy: 0.1)
    }

    // MARK: - Volume badges

    func test_ironMan_60days_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.ironMan(longestStreakDays: 60), 100, accuracy: 0.1)
    }

    func test_gymRat_5sessions_returns100() {
        let cap = Int(HoopTrack.SkillRating.sessionsPerWeekCap)
        XCTAssertEqual(BadgeScoreCalculator.gymRat(sessionsLast7Days: cap), 100, accuracy: 0.1)
    }

    func test_workhorse_15k_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.workhorse(careerShotsAttempted: 15_000), 100, accuracy: 0.1)
    }

    func test_specialist_100sessions_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.specialist(maxSessionsOfOneDrillType: 100), 100, accuracy: 0.1)
    }

    func test_completePlayer_100rating_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.completePlayer(minSkillRating: 100), 100, accuracy: 0.1)
    }
}
