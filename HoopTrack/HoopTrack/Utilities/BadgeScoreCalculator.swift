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
                               profile: PlayerProfile) -> Double? {
        switch badgeID {
        // MARK: Shooting
        case .deadeye:
            return deadeye(fgPct: session.fgPercent, shotsAttempted: session.shotsAttempted)
        case .sniper:
            return sniper(releaseAngleStdDev: session.consistencyScore, shotsAttempted: session.shotsAttempted)
        case .quickTrigger:
            return quickTrigger(avgReleaseTimeMs: session.avgReleaseTimeMs, shotsAttempted: session.shotsAttempted)
        case .beyondTheArc:
            let attempts = session.shots.filter {
                ($0.zone == .cornerThree || $0.zone == .aboveBreakThree) && $0.result != .pending
            }.count
            return beyondTheArc(threePct: session.threePointPercentage, threeAttempts: attempts)
        case .charityStripe:
            let attempts = session.shots.filter { $0.zone == .freeThrow && $0.result != .pending }.count
            return charityStripe(ftPct: session.freeThrowPercentage, ftAttempts: attempts)
        case .threeLevelScorer:
            let p = session.shots.filter { $0.zone == .paint    && $0.result != .pending }
            let m = session.shots.filter { $0.zone == .midRange && $0.result != .pending }
            let t = session.shots.filter { ($0.zone == .cornerThree || $0.zone == .aboveBreakThree) && $0.result != .pending }
            let pct: ([ShotRecord]) -> Double? = { shots in
                shots.isEmpty ? nil : Double(shots.filter { $0.result == .make }.count) / Double(shots.count) * 100
            }
            return threeLevelScorer(paintFGPct: pct(p), paintAttempts: p.count,
                                    midFGPct:   pct(m), midAttempts:   m.count,
                                    threeFGPct: pct(t), threeAttempts: t.count)
        case .hotHand:
            return hotHand(longestMakeStreak: session.longestMakeStreak)

        // MARK: Ball Handling
        case .handles:
            return handles(avgBPS: session.avgDribblesPerSec)
        case .ambidextrous:
            return ambidextrous(handBalance: session.handBalanceFraction,
                                totalDribbles: session.totalDribbles ?? 0)
        case .comboKing:
            return comboKing(combos: session.dribbleCombosDetected ?? 0,
                             totalDribbles: session.totalDribbles ?? 0)
        case .floorGeneral:
            return floorGeneral(avgBPS: session.avgDribblesPerSec,
                                maxBPS: session.maxDribblesPerSec,
                                durationSeconds: session.durationSeconds)
        case .ballWizard:
            let total = profile.sessions.reduce(0) { $0 + ($1.totalDribbles ?? 0) }
            return ballWizard(careerTotalDribbles: total)

        // MARK: Athleticism
        case .posterizer:
            return posterizer(avgVerticalJumpCm: session.avgVerticalJumpCm)
        case .lightning:
            return lightning(bestShuttleRunSec: session.bestShuttleRunSeconds)
        case .explosive:
            return explosive(ratingAthleticism: profile.ratingAthleticism)
        case .highFlyer:
            return highFlyer(prVerticalJumpCm: profile.prVerticalJumpCm)

        // MARK: Consistency
        case .automatic:
            let recent = profile.sessions
                .filter { $0.drillType == .freeShoot && $0.isComplete }
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(10)
                .map { $0.fgPercent }
            return automatic(recentFGPcts: Array(recent))
        case .metronome:
            let shootingSessions = profile.sessions.filter { $0.drillType == .freeShoot && $0.isComplete }
            let values = shootingSessions.compactMap { $0.consistencyScore }
            let avg: Double? = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            return metronome(avgReleaseAngleStdDev: avg, sessionCount: shootingSessions.count)
        case .iceVeins:
            let ftShots = profile.sessions.flatMap { $0.shots }.filter { $0.zone == .freeThrow && $0.result != .pending }
            let made = ftShots.filter { $0.result == .make }.count
            let pct  = ftShots.isEmpty ? 0.0 : Double(made) / Double(ftShots.count) * 100
            return iceVeins(careerFTPct: pct, totalFTAttempts: ftShots.count)
        case .reliable:
            let streak = profile.sessions
                .filter { $0.drillType == .freeShoot && $0.isComplete }
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(while: { $0.fgPercent >= 40 })
                .count
            return reliable(consecutiveSessionsAbove40FG: streak)

        // MARK: Volume
        case .ironMan:
            return ironMan(longestStreakDays: profile.longestStreakDays)
        case .gymRat:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
            let count  = profile.sessions.filter { $0.startedAt >= cutoff && $0.isComplete }.count
            return gymRat(sessionsLast7Days: count)
        case .workhorse:
            return workhorse(careerShotsAttempted: profile.careerShotsAttempted)
        case .specialist:
            let byType   = Dictionary(grouping: profile.sessions.filter { $0.isComplete }, by: { $0.drillType })
            let maxCount = byType.values.map { $0.count }.max() ?? 0
            return specialist(maxSessionsOfOneDrillType: maxCount)
        case .completePlayer:
            let minRating = [profile.ratingShooting, profile.ratingBallHandling,
                             profile.ratingAthleticism, profile.ratingConsistency,
                             profile.ratingVolume].min() ?? 0
            return completePlayer(minSkillRating: minRating)
        }
    }
}
