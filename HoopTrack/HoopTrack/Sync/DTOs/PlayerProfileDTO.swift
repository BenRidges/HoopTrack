// HoopTrack/Sync/DTOs/PlayerProfileDTO.swift
import Foundation

/// Codable mirror of the `player_profiles` Postgres row.
struct PlayerProfileDTO: Codable, Sendable {
    let userId: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    var ratingOverall: Double
    var ratingShooting: Double
    var ratingBallHandling: Double
    var ratingAthleticism: Double
    var ratingConsistency: Double
    var ratingVolume: Double

    var careerShotsAttempted: Int
    var careerShotsMade: Int
    var totalSessionCount: Int
    var totalTrainingMinutes: Double

    var prBestFgPercentSession: Double
    var prMostMakesSession: Int
    var prBestConsistencyScore: Double?
    var prVerticalJumpCm: Double

    var currentStreakDays: Int
    var longestStreakDays: Int
    var lastSessionDate: Date?

    var preferredCourtType: String
    var videosAutoDeleteDays: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case ratingOverall = "rating_overall"
        case ratingShooting = "rating_shooting"
        case ratingBallHandling = "rating_ball_handling"
        case ratingAthleticism = "rating_athleticism"
        case ratingConsistency = "rating_consistency"
        case ratingVolume = "rating_volume"
        case careerShotsAttempted = "career_shots_attempted"
        case careerShotsMade = "career_shots_made"
        case totalSessionCount = "total_session_count"
        case totalTrainingMinutes = "total_training_minutes"
        case prBestFgPercentSession = "pr_best_fg_percent_session"
        case prMostMakesSession = "pr_most_makes_session"
        case prBestConsistencyScore = "pr_best_consistency_score"
        case prVerticalJumpCm = "pr_vertical_jump_cm"
        case currentStreakDays = "current_streak_days"
        case longestStreakDays = "longest_streak_days"
        case lastSessionDate = "last_session_date"
        case preferredCourtType = "preferred_court_type"
        case videosAutoDeleteDays = "videos_auto_delete_days"
    }

    @MainActor
    init(from profile: PlayerProfile, userID: UUID) {
        self.userId = userID
        self.name = profile.name
        self.createdAt = profile.createdAt
        self.updatedAt = Date()

        self.ratingOverall = profile.ratingOverall
        self.ratingShooting = profile.ratingShooting
        self.ratingBallHandling = profile.ratingBallHandling
        self.ratingAthleticism = profile.ratingAthleticism
        self.ratingConsistency = profile.ratingConsistency
        self.ratingVolume = profile.ratingVolume

        self.careerShotsAttempted = profile.careerShotsAttempted
        self.careerShotsMade = profile.careerShotsMade
        self.totalSessionCount = profile.totalSessionCount
        self.totalTrainingMinutes = profile.totalTrainingMinutes

        self.prBestFgPercentSession = profile.prBestFGPercentSession
        self.prMostMakesSession = profile.prMostMakesSession
        // Local model uses Double.infinity as "unset"; translate to nil over the wire.
        self.prBestConsistencyScore = profile.prBestConsistencyScore.isFinite
            ? profile.prBestConsistencyScore : nil
        self.prVerticalJumpCm = profile.prVerticalJumpCm

        self.currentStreakDays = profile.currentStreakDays
        self.longestStreakDays = profile.longestStreakDays
        self.lastSessionDate = profile.lastSessionDate

        self.preferredCourtType = profile.preferredCourtType.rawValue
        self.videosAutoDeleteDays = profile.videosAutoDeleteDays
    }
}
