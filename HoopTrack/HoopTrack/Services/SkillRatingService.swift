// SkillRatingService.swift
import Foundation
import SwiftData

@MainActor final class SkillRatingService: SkillRatingServiceProtocol {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    func recalculate(for profile: PlayerProfile, session: TrainingSession) throws {
        let alpha = HoopTrack.SkillRating.emaAlpha

        // Extract primitives for calculators
        let recentFGPcts = profile.sessions
            .filter { $0.drillType == .freeShoot && $0.isComplete }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(10)
            .map { $0.fgPercent }

        let threeAttemptFrac: Double? = {
            guard session.shotsAttempted > 0 else { return nil }
            let n = session.shots.filter {
                ($0.zone == .cornerThree || $0.zone == .aboveBreakThree) && $0.result != .pending
            }.count
            return Double(n) / Double(session.shotsAttempted)
        }()

        let shootingScore = SkillRatingCalculator.shootingScore(
            fgPct:                session.fgPercent,
            threePct:             session.threePointPercentage,
            ftPct:                session.freeThrowPercentage,
            releaseAngleDeg:      session.avgReleaseAngleDeg,
            releaseAngleStdDev:   session.consistencyScore,
            releaseTimeMs:        session.avgReleaseTimeMs,
            shotSpeedMph:         session.avgShotSpeedMph,
            shotSpeedStdDev:      session.shotSpeedStdDev,
            threeAttemptFraction: threeAttemptFrac
        )

        let handlingScore = SkillRatingCalculator.ballHandlingScore(
            avgBPS:        session.avgDribblesPerSec,
            maxBPS:        session.maxDribblesPerSec,
            handBalance:   session.handBalanceFraction,
            combos:        session.dribbleCombosDetected ?? 0,
            totalDribbles: session.totalDribbles ?? 0
        )

        let athleticismScore = SkillRatingCalculator.athleticismScore(
            verticalJumpCm: session.avgVerticalJumpCm,
            shuttleRunSec:  session.bestShuttleRunSeconds
        )

        let consistencyScore = SkillRatingCalculator.consistencyScore(
            releaseAngleStdDev: session.consistencyScore,
            fgPctHistory:       Array(recentFGPcts),
            ftPct:              session.freeThrowPercentage,
            shotSpeedStdDev:    session.shotSpeedStdDev
        )

        let cutoff28 = Calendar.current.date(byAdding: .day, value: -28, to: .now)!
        let cutoff14 = Calendar.current.date(byAdding: .day, value: -14, to: .now)!
        let recent28  = profile.sessions.filter { $0.startedAt >= cutoff28 && $0.isComplete }
        let avgShots  = recent28.isEmpty ? 0.0
            : recent28.map { Double($0.shotsAttempted) }.reduce(0, +) / Double(recent28.count)
        let weeklyMin = recent28.map { $0.durationSeconds / 60 }.reduce(0, +) / 4
        let distinct  = Set(profile.sessions.filter { $0.startedAt >= cutoff14 && $0.isComplete }.map { $0.drillType }).count
        let drillVar  = min(1.0, Double(distinct) / 4.0)

        let volumeScore = SkillRatingCalculator.volumeScore(
            sessionsLast4Weeks:     recent28.count,
            avgShotsPerSession:     avgShots,
            weeklyTrainingMinutes:  weeklyMin,
            drillVarietyLast14Days: drillVar
        )

        // EMA update; cold-start: if current == 0, set directly (no blend)
        func ema(_ current: Double, _ new: Double) -> Double {
            current == 0 ? new : current * (1 - alpha) + new * alpha
        }

        if let s = shootingScore    { profile.ratingShooting     = ema(profile.ratingShooting,     s) }
        if let h = handlingScore    { profile.ratingBallHandling  = ema(profile.ratingBallHandling,  h) }
        if let a = athleticismScore { profile.ratingAthleticism   = ema(profile.ratingAthleticism,   a) }
        if let c = consistencyScore { profile.ratingConsistency   = ema(profile.ratingConsistency,   c) }
        profile.ratingVolume = ema(profile.ratingVolume, volumeScore)

        profile.ratingOverall = SkillRatingCalculator.overallScore(
            shooting:    profile.ratingShooting    > 0 ? profile.ratingShooting    : nil,
            handling:    profile.ratingBallHandling > 0 ? profile.ratingBallHandling : nil,
            athleticism: profile.ratingAthleticism  > 0 ? profile.ratingAthleticism  : nil,
            consistency: profile.ratingConsistency  > 0 ? profile.ratingConsistency  : nil,
            volume:      profile.ratingVolume
        )

        // Update personal vertical jump record
        if let jump = session.avgVerticalJumpCm, jump > profile.prVerticalJumpCm {
            profile.prVerticalJumpCm = jump
        }

        try modelContext.save()
    }
}
