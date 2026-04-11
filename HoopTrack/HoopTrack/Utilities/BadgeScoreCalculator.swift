// BadgeScoreCalculator.swift
// Public entry point handles SwiftData model extraction.
// Internal per-badge functions take only primitive value types — directly unit-testable.

import Foundation

enum BadgeScoreCalculator {

    // MARK: - Public API

    /// Returns 0–100 score (nil = session type not relevant to this badge).
    static func score(for badgeID: BadgeID,
                      session: TrainingSession,
                      profile: PlayerProfile) -> Double? {
        guard affectedDrillTypes(for: badgeID).contains(session.drillType) else { return nil }
        return route(badgeID: badgeID, session: session, profile: profile)
    }

    /// DrillTypes whose sessions affect this badge's MMR.
    static func affectedDrillTypes(for badgeID: BadgeID) -> Set<DrillType> {
        switch badgeID {
        // Shooting-only badges
        case .deadeye, .sniper, .quickTrigger, .beyondTheArc, .charityStripe,
             .threeLevelScorer, .hotHand, .automatic, .metronome, .iceVeins,
             .reliable, .workhorse:
            return [.freeShoot]
        // Dribble-only badges
        case .handles, .ambidextrous, .comboKing, .floorGeneral, .ballWizard:
            return [.dribble]
        // Agility-only badges
        case .posterizer, .lightning, .explosive, .highFlyer:
            return [.agility]
        // Any-session badges
        case .ironMan, .gymRat, .specialist, .completePlayer:
            return [.freeShoot, .dribble, .agility, .fullWorkout]
        }
    }

    // Implemented in the tasks below:
    private static func route(badgeID: BadgeID,
                               session: TrainingSession,
                               profile: PlayerProfile) -> Double? { nil }
}
