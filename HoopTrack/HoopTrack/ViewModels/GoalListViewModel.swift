// GoalListViewModel.swift
import Foundation
import Combine
import SwiftData

@MainActor final class GoalListViewModel: ObservableObject {

    @Published var showingAddGoal = false
    @Published var showAchieved  = false

    private let modelContext: ModelContext
    let profile: PlayerProfile   // internal so AddGoalSheet can read it

    init(modelContext: ModelContext, profile: PlayerProfile) {
        self.modelContext = modelContext
        self.profile      = profile
    }

    var activeGoals:   [GoalRecord] { profile.goals.filter { !$0.isAchieved } }
    var achievedGoals: [GoalRecord] { profile.goals.filter {  $0.isAchieved } }

    func delete(_ goal: GoalRecord) {
        modelContext.delete(goal)
        try? modelContext.save()
    }

    func add(title: String, skill: SkillDimension, metric: GoalMetric,
             target: Double, baseline: Double, targetDate: Date?) {
        let goal = GoalRecord(title: title, skill: skill, metric: metric,
                              targetValue: target, baselineValue: baseline,
                              targetDate: targetDate)
        goal.profile = profile
        profile.goals.append(goal)
        modelContext.insert(goal)
        try? modelContext.save()
    }

    /// Returns the profile's current value for a metric — used to pre-fill baseline in AddGoalSheet.
    func currentValue(for metric: GoalMetric) -> Double {
        switch metric {
        case .fgPercent:
            return profile.sessions.last?.fgPercent ?? 0
        case .threePointPercent:
            return profile.sessions.last?.threePointPercentage ?? 0
        case .freeThrowPercent:
            return profile.sessions.last?.freeThrowPercentage ?? 0
        case .verticalJumpCm:
            return profile.prVerticalJumpCm
        case .dribbleSpeedHz:
            return profile.sessions.last?.avgDribblesPerSec ?? 0
        case .shuttleRunSeconds:
            return profile.sessions.compactMap { $0.bestShuttleRunSeconds }.min() ?? 0
        case .overallRating:
            return profile.ratingOverall
        case .shootingRating:
            return profile.ratingShooting
        case .sessionsPerWeek:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
            return Double(profile.sessions.filter { $0.startedAt >= cutoff }.count)
        }
    }
}
