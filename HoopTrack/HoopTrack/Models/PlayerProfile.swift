// PlayerProfile.swift
// SwiftData model — single persistent player profile.
// There is always exactly one PlayerProfile in the store (created on first launch).

import Foundation
import SwiftData

@Model
final class PlayerProfile {

    // MARK: - Identity
    var name: String
    var createdAt: Date

    // MARK: - Skill Ratings (0–100, updated after each session)
    var ratingOverall: Double
    var ratingShooting: Double
    var ratingBallHandling: Double
    var ratingAthleticism: Double
    var ratingConsistency: Double
    var ratingVolume: Double

    // MARK: - Career Stats
    var careerShotsAttempted: Int
    var careerShotsMade: Int
    var totalSessionCount: Int
    var totalTrainingMinutes: Double

    // MARK: - Personal Records
    var prBestFGPercentSession: Double      // Best FG% in a single session
    var prMostMakesSession: Int             // Most makes in a single session
    var prBestConsistencyScore: Double      // Lowest release-angle variance
    var prVerticalJumpCm: Double            // Best recorded vertical jump (cm)

    // MARK: - Streaks
    var currentStreakDays: Int
    var longestStreakDays: Int
    var lastSessionDate: Date?

    // MARK: - Settings
    var preferredCourtType: CourtType
    var iCloudSyncEnabled: Bool
    var videosAutoDeleteDays: Int           // 0 = never; default 60

    // MARK: - Relationships
    @Relationship(deleteRule: .cascade) var sessions: [TrainingSession]
    @Relationship(deleteRule: .cascade) var goals: [GoalRecord]

    init(name: String = "Player") {
        self.name                   = name
        self.createdAt              = .now

        self.ratingOverall          = 0
        self.ratingShooting         = 0
        self.ratingBallHandling     = 0
        self.ratingAthleticism      = 0
        self.ratingConsistency      = 0
        self.ratingVolume           = 0

        self.careerShotsAttempted   = 0
        self.careerShotsMade        = 0
        self.totalSessionCount      = 0
        self.totalTrainingMinutes   = 0

        self.prBestFGPercentSession = 0
        self.prMostMakesSession     = 0
        self.prBestConsistencyScore = Double.infinity
        self.prVerticalJumpCm       = 0

        self.currentStreakDays      = 0
        self.longestStreakDays      = 0
        self.lastSessionDate        = nil

        self.preferredCourtType     = .nba
        self.iCloudSyncEnabled      = false
        self.videosAutoDeleteDays   = 60

        self.sessions               = []
        self.goals                  = []
    }

    // MARK: - Computed Helpers

    var careerFGPercent: Double {
        guard careerShotsAttempted > 0 else { return 0 }
        return Double(careerShotsMade) / Double(careerShotsAttempted) * 100
    }

    /// Returns a dictionary keyed by SkillDimension for use in the radar chart.
    var skillRatings: [SkillDimension: Double] {
        [
            .shooting:     ratingShooting,
            .ballHandling: ratingBallHandling,
            .athleticism:  ratingAthleticism,
            .consistency:  ratingConsistency,
            .volume:       ratingVolume
        ]
    }
}
