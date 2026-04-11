// GoalUpdateService.swift
import Foundation
import SwiftData

@MainActor final class GoalUpdateService: GoalUpdateServiceProtocol {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    func update(after session: TrainingSession, profile: PlayerProfile) throws {
        for goal in profile.goals where !goal.isAchieved {
            let value = currentValue(for: goal.metric, session: session, profile: profile)
            goal.currentValue = value
            if isAchieved(metric: goal.metric, current: value, target: goal.targetValue) {
                goal.isAchieved = true
                goal.achievedAt = .now
            }
        }
        try modelContext.save()
    }

    // MARK: - Private

    private func currentValue(for metric: GoalMetric,
                               session: TrainingSession,
                               profile: PlayerProfile) -> Double {
        switch metric {
        case .fgPercent:
            return session.fgPercent
        case .threePointPercent:
            return session.threePointPercentage ?? 0
        case .freeThrowPercent:
            return session.freeThrowPercentage ?? 0
        case .verticalJumpCm:
            return session.avgVerticalJumpCm ?? 0
        case .dribbleSpeedHz:
            return session.avgDribblesPerSec ?? 0
        case .shuttleRunSeconds:
            return session.bestShuttleRunSeconds ?? Double.infinity
        case .overallRating:
            return profile.ratingOverall
        case .shootingRating:
            return profile.ratingShooting
        case .sessionsPerWeek:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
            return Double(profile.sessions.filter { $0.startedAt >= cutoff && $0.isComplete }.count)
        }
    }

    /// shuttle run is lower-is-better; all other metrics are higher-is-better.
    private func isAchieved(metric: GoalMetric, current: Double, target: Double) -> Bool {
        metric == .shuttleRunSeconds ? current <= target : current >= target
    }
}
