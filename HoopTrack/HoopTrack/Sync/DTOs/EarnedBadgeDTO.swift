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

    /// A local badge from a backed-up row (restore); nil for unknown ids.
    @MainActor
    func makeBadge(syncedAt: Date = .now) -> EarnedBadge? {
        guard let badgeID = BadgeID(rawValue: badgeId) else { return nil }
        let badge = EarnedBadge(badgeID: badgeID, initialMMR: mmr)
        badge.id = id
        badge.earnedAt = earnedAt
        badge.lastUpdatedAt = updatedAt
        badge.cloudSyncedAt = syncedAt
        return badge
    }
}
