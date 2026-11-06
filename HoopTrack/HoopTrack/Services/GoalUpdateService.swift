// GoalUpdateService.swift
// Refreshes goal progress after a session. A goal only moves when the
// session actually measured its metric — a dribble session no longer
// resets a shooting goal to 0%, and an agility session without a shuttle
// run no longer writes infinity into a shuttle goal.

import Foundation
import SwiftData

@MainActor final class GoalUpdateService: GoalUpdateServiceProtocol {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    func update(after session: TrainingSession, profile: PlayerProfile) throws {
        for goal in profile.goals where !goal.isAchieved {
            guard let value = Self.currentValue(for: goal.metric, session: session, profile: profile),
                  value.isFinite else { continue }
            goal.currentValue = value
            let reached = goal.metric.lowerIsBetter ? value <= goal.targetValue : value >= goal.targetValue
            if reached {
                goal.isAchieved = true
                goal.achievedAt = .now
            }
        }
        try modelContext.save()
    }

    /// The metric's value as of this session, or nil when the session
    /// didn't measure it.
    static func currentValue(for metric: GoalMetric,
                             session: TrainingSession,
                             profile: PlayerProfile) -> Double? {
        switch metric {
        case .fgPercent:
            return session.shotsAttempted > 0 ? session.fgPercent : nil
        case .threePointPercent:
            return session.threePointPercentage
        case .freeThrowPercent:
            return session.freeThrowPercentage
        case .verticalJumpCm:
            return session.avgVerticalJumpCm
        case .dribbleSpeedHz:
            return session.avgDribblesPerSec
        case .shuttleRunSeconds:
            return session.bestShuttleRunSeconds
        case .overallRating:
            return profile.ratingOverall
        case .shootingRating:
            return profile.ratingShooting
        case .sessionsPerWeek:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
            return Double(profile.sessions.filter { $0.startedAt >= cutoff && $0.isComplete }.count)
        }
    }
}
