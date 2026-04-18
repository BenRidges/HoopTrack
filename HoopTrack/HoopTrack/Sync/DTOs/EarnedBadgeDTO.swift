// HoopTrack/Sync/DTOs/EarnedBadgeDTO.swift
import Foundation

struct EarnedBadgeDTO: Codable, Sendable {
    let id: UUID
    let userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var badgeId: String
    var mmr: Double
    var rank: String
    var earnedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case badgeId = "badge_id"
        case mmr
        case rank
        case earnedAt = "earned_at"
    }

    @MainActor
    init(from badge: EarnedBadge, userID: UUID) {
        self.id = badge.id
        self.userId = userID
        self.createdAt = badge.earnedAt
        self.updatedAt = Date()
        self.badgeId = badge.badgeID.rawValue
        self.mmr = badge.mmr
        self.rank = badge.rank.displayName
        self.earnedAt = badge.earnedAt
    }
}
