// BadgeBrowserViewModel.swift
import Foundation
import Combine

@MainActor final class BadgeBrowserViewModel: ObservableObject {

    struct BadgeRowItem: Identifiable {
        let id: BadgeID
        let rank: BadgeRank?   // nil = not yet earned
    }

    private let profile: PlayerProfile

    init(profile: PlayerProfile) {
        self.profile = profile
    }

    var earnedCount: Int { profile.earnedBadges.count }

    func rows(for dimension: SkillDimension) -> [BadgeRowItem] {
        BadgeID.allCases
            .filter { $0.skillDimension == dimension }
            .map { badgeID in
                let earned = profile.earnedBadges.first { $0.badgeID == badgeID }
                return BadgeRowItem(
                    id:   badgeID,
                    rank: earned.map { BadgeRank(mmr: $0.mmr) }
                )
            }
    }
}
