// HoopTrack/Sync/DTOs/GoalRecordDTO.swift
import Foundation

struct GoalRecordDTO: Codable, Sendable {
    let id: UUID
    let userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var targetDate: Date?
    var title: String
    var skill: String
    var metric: String
    var targetValue: Double
    var baselineValue: Double
    var currentValue: Double
    var isAchieved: Bool
    var achievedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case targetDate = "target_date"
        case title, skill, metric
        case targetValue = "target_value"
        case baselineValue = "baseline_value"
        case currentValue = "current_value"
        case isAchieved = "is_achieved"
        case achievedAt = "achieved_at"
    }

    @MainActor
    init(from goal: GoalRecord, userID: UUID) {
        self.id = goal.id
        self.userId = userID
        self.createdAt = goal.createdAt
        self.updatedAt = Date()
        self.targetDate = goal.targetDate
        self.title = goal.title
        self.skill = goal.skill.rawValue
        self.metric = goal.metric.rawValue
        self.targetValue = goal.targetValue
        self.baselineValue = goal.baselineValue
        self.currentValue = goal.currentValue
        self.isAchieved = goal.isAchieved
        self.achievedAt = goal.achievedAt
    }
}
