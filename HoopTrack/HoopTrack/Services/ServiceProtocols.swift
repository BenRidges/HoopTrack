// ServiceProtocols.swift
// @MainActor on each protocol ensures the @MainActor coordinator can call
// requirements without additional await (required for Swift 6 strict concurrency).

import Foundation

@MainActor protocol GoalUpdateServiceProtocol {
    func update(after session: TrainingSession, profile: PlayerProfile) throws
}

@MainActor protocol SkillRatingServiceProtocol {
    func recalculate(for profile: PlayerProfile, session: TrainingSession) throws
}

@MainActor protocol BadgeEvaluationServiceProtocol {
    func evaluate(session: TrainingSession,
                  profile: PlayerProfile) throws -> [BadgeTierChange]
}

@MainActor protocol HealthKitServiceProtocol {
    func requestPermission() async
    func writeWorkout(for session: TrainingSession) async throws
}

// MARK: - Result types

struct BadgeTierChange: Equatable {
    let badgeID: BadgeID
    let previousRank: BadgeRank?   // nil = first earn
    let newRank: BadgeRank
}

struct SessionResult {
    let session: TrainingSession
    let badgeChanges: [BadgeTierChange]
    /// Non-nil when badge evaluation was skipped (e.g. too few shots). Shown in the summary UI.
    let badgeSkipReason: String?

    init(session: TrainingSession, badgeChanges: [BadgeTierChange], badgeSkipReason: String? = nil) {
        self.session = session
        self.badgeChanges = badgeChanges
        self.badgeSkipReason = badgeSkipReason
    }
}

struct AgilityAttempts {
    var bestShuttleRunSeconds: Double?
    var bestLaneAgilitySeconds: Double?
}
