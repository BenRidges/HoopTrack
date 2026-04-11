// BadgeEvaluationService.swift
import Foundation
import SwiftData

@MainActor final class BadgeEvaluationService: BadgeEvaluationServiceProtocol {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    func evaluate(session: TrainingSession,
                  profile: PlayerProfile) throws -> [BadgeTierChange] {
        let alpha   = HoopTrack.SkillRating.emaAlpha
        var changes = [BadgeTierChange]()

        for badgeID in BadgeID.allCases {
            // Skip badges not affected by this session type
            guard BadgeScoreCalculator.affectedDrillTypes(for: badgeID)
                    .contains(session.drillType) else { continue }

            // score() returns nil if data is absent; skip (non-fatal)
            guard let score = BadgeScoreCalculator.score(for: badgeID,
                                                          session: session,
                                                          profile: profile)
            else { continue }

            let targetMMR = score / 100.0 * 1800.0

            if let existing = profile.earnedBadges.first(where: { $0.badgeID == badgeID }) {
                // EMA blend
                let previousRank = BadgeRank(mmr: existing.mmr)
                existing.mmr           = existing.mmr * (1 - alpha) + targetMMR * alpha
                existing.lastUpdatedAt = .now
                let newRank = BadgeRank(mmr: existing.mmr)
                if newRank != previousRank {
                    changes.append(BadgeTierChange(badgeID: badgeID,
                                                   previousRank: previousRank,
                                                   newRank: newRank))
                }
            } else {
                // Cold-start: first earn — set MMR directly, no blend
                let badge = EarnedBadge(badgeID: badgeID,
                                        initialMMR: targetMMR,
                                        profile: profile)
                modelContext.insert(badge)
                profile.earnedBadges.append(badge)
                changes.append(BadgeTierChange(badgeID: badgeID,
                                               previousRank: nil,
                                               newRank: BadgeRank(mmr: targetMMR)))
            }
        }

        // SwiftData write errors are fatal (propagate); per-badge calculation errors are
        // swallowed above via guard-nil. The coordinator calls evaluate() with try? so
        // even a SwiftData error is non-fatal at the finalisation level.
        try modelContext.save()
        return changes
    }
}
