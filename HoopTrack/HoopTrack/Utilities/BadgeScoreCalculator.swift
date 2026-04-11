// BadgeScoreCalculator.swift
// Public entry point handles SwiftData model extraction.
// Internal per-badge functions take only primitive value types — directly unit-testable.

import Foundation

enum BadgeScoreCalculator {

    // MARK: - Public API

    /// Returns 0–100 score (nil = session type not relevant to this badge).
    static func score(for badgeID: BadgeID,
                      session: TrainingSession,
                      profile: PlayerProfile) -> Double? {
        guard affectedDrillTypes(for: badgeID).contains(session.drillType) else { return nil }
        return route(badgeID: badgeID, session: session, profile: profile)
    }

    /// DrillTypes whose sessions affect this badge's MMR.
    static func affectedDrillTypes(for badgeID: BadgeID) -> Set<DrillType> {
        switch badgeID {
        // Shooting-only badges
        case .deadeye, .sniper, .quickTrigger, .beyondTheArc, .charityStripe,
             .threeLevelScorer, .hotHand, .automatic, .metronome, .iceVeins,
             .reliable, .workhorse:
            return [.freeShoot]
        // Dribble-only badges
        case .handles, .ambidextrous, .comboKing, .floorGeneral, .ballWizard:
            return [.dribble]
        // Agility-only badges
        case .posterizer, .lightning, .explosive, .highFlyer:
            return [.agility]
        // Any-session badges
        case .ironMan, .gymRat, .specialist, .completePlayer:
            return [.freeShoot, .dribble, .agility, .fullWorkout]
        }
    }

    // MARK: - Shooting Badge Internals

    static func deadeye(fgPct: Double, shotsAttempted: Int) -> Double? {
        guard shotsAttempted >= 20 else { return nil }
        return SkillRatingCalculator.normalize(fgPct, min: 0, max: 100)
    }

    static func sniper(releaseAngleStdDev: Double?, shotsAttempted: Int) -> Double? {
        guard shotsAttempted >= 20, let sd = releaseAngleStdDev else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(R.releaseAngleStdDevMax - sd,
                                               min: 0, max: R.releaseAngleStdDevMax)
    }

    static func quickTrigger(avgReleaseTimeMs: Double?, shotsAttempted: Int) -> Double? {
        guard shotsAttempted >= 20, let ms = avgReleaseTimeMs else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(R.releaseTimeSlowMs - ms,
                                               min: 0,
                                               max: R.releaseTimeSlowMs - R.releaseTimeEliteMs)
    }

    static func beyondTheArc(threePct: Double?, threeAttempts: Int) -> Double? {
        guard threeAttempts >= 10, let pct = threePct else { return nil }
        return SkillRatingCalculator.normalize(pct, min: 0, max: 100)
    }

    static func charityStripe(ftPct: Double?, ftAttempts: Int) -> Double? {
        guard ftAttempts >= 10, let pct = ftPct else { return nil }
        return SkillRatingCalculator.normalize(pct, min: 0, max: 100)
    }

    static func threeLevelScorer(paintFGPct: Double?, paintAttempts: Int,
                                  midFGPct: Double?,   midAttempts: Int,
                                  threeFGPct: Double?, threeAttempts: Int) -> Double? {
        guard paintAttempts >= 3 || midAttempts >= 3 || threeAttempts >= 3 else { return nil }
        let p = paintAttempts >= 3 ? SkillRatingCalculator.normalize(paintFGPct ?? 0, min: 0, max: 100) : 0.0
        let m = midAttempts   >= 3 ? SkillRatingCalculator.normalize(midFGPct   ?? 0, min: 0, max: 100) : 0.0
        let t = threeAttempts >= 3 ? SkillRatingCalculator.normalize(threeFGPct ?? 0, min: 0, max: 100) : 0.0
        return (p + m + t) / 3.0
    }

    static func hotHand(longestMakeStreak: Int) -> Double {
        SkillRatingCalculator.normalize(Double(longestMakeStreak), min: 0, max: 15)
    }

    // MARK: - Ball Handling Badge Internals

    static func handles(avgBPS: Double?) -> Double? {
        guard let bps = avgBPS else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(bps, min: R.bpsAvgMin, max: R.bpsAvgMax)
    }

    static func ambidextrous(handBalance: Double?, totalDribbles: Int) -> Double? {
        guard totalDribbles >= 100, let balance = handBalance else { return nil }
        return (1 - abs(balance - 0.5) * 2) * 100
    }

    static func comboKing(combos: Int, totalDribbles: Int) -> Double? {
        guard totalDribbles >= 100 else { return nil }
        return SkillRatingCalculator.normalize(Double(combos), min: 0, max: 50)
    }

    static func floorGeneral(avgBPS: Double?, maxBPS: Double?, durationSeconds: Double) -> Double? {
        guard durationSeconds >= 60,
              let avg = avgBPS, avg >= 3.0,
              let mx = maxBPS, mx > 0 else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(avg / mx, min: R.bpsSustainedMin, max: R.bpsSustainedMax)
    }

    static func ballWizard(careerTotalDribbles: Int) -> Double {
        SkillRatingCalculator.normalize(Double(careerTotalDribbles), min: 0, max: 50_000)
    }

    // MARK: - Athleticism Badge Internals

    static func posterizer(avgVerticalJumpCm: Double?) -> Double? {
        guard let jump = avgVerticalJumpCm else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(jump, min: R.verticalJumpMinCm, max: R.verticalJumpMaxCm)
    }

    static func lightning(bestShuttleRunSec: Double?) -> Double? {
        guard let sec = bestShuttleRunSec else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(R.shuttleRunWorstSec - sec,
                                               min: 0,
                                               max: R.shuttleRunWorstSec - R.shuttleRunBestSec)
    }

    static func explosive(ratingAthleticism: Double) -> Double {
        SkillRatingCalculator.normalize(ratingAthleticism, min: 0, max: 100)
    }

    static func highFlyer(prVerticalJumpCm: Double) -> Double {
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(prVerticalJumpCm,
                                               min: R.verticalJumpMinCm, max: R.verticalJumpMaxCm)
    }

    // MARK: - Consistency Badge Internals

    static func automatic(recentFGPcts: [Double]) -> Double? {
        let history = Array(recentFGPcts.suffix(10))
        guard history.count >= HoopTrack.SkillRating.crossSessionMinCount else { return nil }
        let mean     = history.reduce(0, +) / Double(history.count)
        let variance = history.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(history.count)
        let stdDev   = sqrt(variance)
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(R.fgPctSessionStdDevMax - stdDev,
                                               min: 0, max: R.fgPctSessionStdDevMax)
    }

    static func metronome(avgReleaseAngleStdDev: Double?, sessionCount: Int) -> Double? {
        guard sessionCount >= 10, let sd = avgReleaseAngleStdDev else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(R.releaseAngleStdDevMax - sd,
                                               min: 0, max: R.releaseAngleStdDevMax)
    }

    static func iceVeins(careerFTPct: Double, totalFTAttempts: Int) -> Double? {
        guard totalFTAttempts >= 50 else { return nil }
        return SkillRatingCalculator.normalize(careerFTPct, min: 0, max: 100)
    }

    static func reliable(consecutiveSessionsAbove40FG: Int) -> Double {
        SkillRatingCalculator.normalize(Double(consecutiveSessionsAbove40FG), min: 0, max: 12)
    }

    // MARK: - Volume Badge Internals

    static func ironMan(longestStreakDays: Int) -> Double {
        SkillRatingCalculator.normalize(Double(longestStreakDays), min: 0, max: 60)
    }

    static func gymRat(sessionsLast7Days: Int) -> Double {
        SkillRatingCalculator.normalize(Double(sessionsLast7Days),
                                         min: 0, max: HoopTrack.SkillRating.sessionsPerWeekCap)
    }

    static func workhorse(careerShotsAttempted: Int) -> Double {
        SkillRatingCalculator.normalize(Double(careerShotsAttempted), min: 0, max: 15_000)
    }

    static func specialist(maxSessionsOfOneDrillType: Int) -> Double {
        SkillRatingCalculator.normalize(Double(maxSessionsOfOneDrillType), min: 0, max: 100)
    }

    static func completePlayer(minSkillRating: Double) -> Double {
        SkillRatingCalculator.normalize(minSkillRating, min: 0, max: 100)
    }

    // MARK: - Route

    private static func route(badgeID: BadgeID,
                               session: TrainingSession,
                               profile: PlayerProfile) -> Double? { nil }
}
