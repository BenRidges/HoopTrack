// SkillDimensionExtensions.swift
// UI-only extension — maps SkillDimension to GoalMetric suggestions.
import Foundation

extension SkillDimension {
    /// Ordered list of GoalMetric values suggested when creating a goal for this dimension.
    var suggestedMetrics: [GoalMetric] {
        switch self {
        case .shooting:     return [.fgPercent, .threePointPercent, .freeThrowPercent, .shootingRating]
        case .ballHandling: return [.dribbleSpeedHz]
        case .athleticism:  return [.verticalJumpCm, .shuttleRunSeconds]
        case .consistency:  return [.fgPercent, .overallRating]
        case .volume:       return [.sessionsPerWeek, .overallRating]
        }
    }
}
