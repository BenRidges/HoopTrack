// GoalRecord.swift
// SwiftData model — a single user-defined performance goal.
// Goals are shown on the dashboard with a progress bar and drive daily missions.

import Foundation
import SwiftData

@Model
final class GoalRecord {

    // MARK: - Identity
    var id: UUID
    var createdAt: Date
    var targetDate: Date?

    // MARK: - Description
    var title: String               // e.g. "Shoot 45% from 3 by June"
    var skill: SkillDimension
    var metric: GoalMetric
    var targetValue: Double         // e.g. 45.0 (percent)
    var baselineValue: Double       // value at time of goal creation

    // MARK: - State
    var currentValue: Double        // refreshed after each session
    var isAchieved: Bool
    var achievedAt: Date?

    // MARK: - Sync (Phase 9)
    var cloudSyncedAt: Date?

    // MARK: - Relationship
    var profile: PlayerProfile?
    var lastMilestoneNotified: Int = 0   // 0, 50, 75, or 100 — tracks highest fired threshold

    init(title: String,
         skill: SkillDimension,
         metric: GoalMetric,
         targetValue: Double,
         baselineValue: Double,
         targetDate: Date? = nil) {

        self.id             = UUID()
        self.createdAt      = .now
        self.targetDate     = targetDate

        self.title          = title
        self.skill          = skill
        self.metric         = metric
        self.targetValue    = targetValue
        self.baselineValue  = baselineValue

        self.currentValue   = baselineValue
        self.isAchieved     = false
        self.achievedAt     = nil

        self.cloudSyncedAt  = nil
    }

    // MARK: - Computed

    /// Progress from 0.0 to 1.0 (clamped).
    var progressFraction: Double {
        if isAchieved { return 1 }
        guard targetValue != baselineValue, currentValue.isFinite else { return 0 }
        let fraction = (currentValue - baselineValue) / (targetValue - baselineValue)
        return fraction.isFinite ? max(0, min(1, fraction)) : 0
    }

    var progressPercent: Int {
        let p = progressFraction
        return p.isFinite ? Int(p * 100) : 0
    }

    var daysRemaining: Int? {
        guard let target = targetDate else { return nil }
        return Calendar.current.dateComponents([.day], from: .now, to: target).day
    }
}

// MARK: - GoalMetric
/// The specific numeric measurement a goal is based on.
nonisolated enum GoalMetric: String, Codable, CaseIterable, Identifiable {
    case fgPercent          = "FG %"
    case threePointPercent  = "3PT %"
    case freeThrowPercent   = "FT %"
    case verticalJumpCm     = "Vertical Jump (cm)"
    case dribbleSpeedHz     = "Dribble Speed (dribbles/sec)"
    case shuttleRunSeconds  = "Shuttle Run (seconds)"
    case overallRating      = "Overall Rating"
    case shootingRating     = "Shooting Rating"
    case sessionsPerWeek    = "Sessions / Week"

    var id: String { rawValue }

    /// Shuttle times improve downwards; everything else upwards.
    var lowerIsBetter: Bool { self == .shuttleRunSeconds }

    /// Short UI label (rawValue is a persistence/sync key).
    var displayName: String {
        switch self {
        case .fgPercent:         return "Field goal %"
        case .threePointPercent: return "Three-point %"
        case .freeThrowPercent:  return "Free throw %"
        case .verticalJumpCm:    return "Vertical jump"
        case .dribbleSpeedHz:    return "Dribble speed"
        case .shuttleRunSeconds: return "Shuttle run"
        case .overallRating:     return "Overall rating"
        case .shootingRating:    return "Shooting rating"
        case .sessionsPerWeek:   return "Sessions a week"
        }
    }

    var unit: String {
        switch self {
        case .fgPercent, .threePointPercent, .freeThrowPercent: return "%"
        case .verticalJumpCm:   return "cm"
        case .dribbleSpeedHz:   return "dps"
        case .shuttleRunSeconds: return "s"
        case .overallRating, .shootingRating: return "pts"
        case .sessionsPerWeek:  return "sessions"
        }
    }
}
