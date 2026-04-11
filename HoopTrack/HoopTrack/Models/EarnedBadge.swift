// EarnedBadge.swift
import Foundation
import SwiftData

@Model final class EarnedBadge {
    var id: UUID
    var badgeID: BadgeID
    var mmr: Double          // 0–1800 continuous; tier derived via BadgeRank(mmr:)
    var earnedAt: Date       // set on first earn (cold-start)
    var lastUpdatedAt: Date  // updated each time MMR changes
    var profile: PlayerProfile?

    init(badgeID: BadgeID, initialMMR: Double, profile: PlayerProfile? = nil) {
        self.id            = UUID()
        self.badgeID       = badgeID
        self.mmr           = initialMMR
        self.earnedAt      = .now
        self.lastUpdatedAt = .now
        self.profile       = profile
    }

    /// Derived rank — never stored, always computed from current mmr.
    var rank: BadgeRank { BadgeRank(mmr: mmr) }
}
