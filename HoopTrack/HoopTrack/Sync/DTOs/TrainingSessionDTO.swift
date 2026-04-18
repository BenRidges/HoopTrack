// HoopTrack/Sync/DTOs/TrainingSessionDTO.swift
import Foundation

struct TrainingSessionDTO: Codable, Sendable {
    let id: UUID
    let userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double
    var drillType: String
    var namedDrill: String?
    var courtType: String
    var locationTag: String
    var notes: String
    var shotsAttempted: Int
    var shotsMade: Int
    var fgPercent: Double
    var avgReleaseAngleDeg: Double?
    var avgReleaseTimeMs: Double?
    var avgVerticalJumpCm: Double?
    var avgShotSpeedMph: Double?
    var consistencyScore: Double?
    var videoPinnedByUser: Bool

    var totalDribbles: Int?
    var avgDribblesPerSec: Double?
    var maxDribblesPerSec: Double?
    var handBalanceFraction: Double?
    var dribbleCombosDetected: Int?

    var bestShuttleRunSeconds: Double?
    var bestLaneAgilitySeconds: Double?
    var longestMakeStreak: Int
    var shotSpeedStdDev: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case drillType = "drill_type"
        case namedDrill = "named_drill"
        case courtType = "court_type"
        case locationTag = "location_tag"
        case notes
        case shotsAttempted = "shots_attempted"
        case shotsMade = "shots_made"
        case fgPercent = "fg_percent"
        case avgReleaseAngleDeg = "avg_release_angle_deg"
        case avgReleaseTimeMs = "avg_release_time_ms"
        case avgVerticalJumpCm = "avg_vertical_jump_cm"
        case avgShotSpeedMph = "avg_shot_speed_mph"
        case consistencyScore = "consistency_score"
        case videoPinnedByUser = "video_pinned_by_user"
        case totalDribbles = "total_dribbles"
        case avgDribblesPerSec = "avg_dribbles_per_sec"
        case maxDribblesPerSec = "max_dribbles_per_sec"
        case handBalanceFraction = "hand_balance_fraction"
        case dribbleCombosDetected = "dribble_combos_detected"
        case bestShuttleRunSeconds = "best_shuttle_run_seconds"
        case bestLaneAgilitySeconds = "best_lane_agility_seconds"
        case longestMakeStreak = "longest_make_streak"
        case shotSpeedStdDev = "shot_speed_std_dev"
    }

    @MainActor
    init(from session: TrainingSession, userID: UUID) {
        self.id = session.id
        self.userId = userID
        self.createdAt = session.startedAt
        self.updatedAt = Date()
        self.startedAt = session.startedAt
        self.endedAt = session.endedAt
        self.durationSeconds = session.durationSeconds
        self.drillType = session.drillType.rawValue
        self.namedDrill = session.namedDrill?.rawValue
        self.courtType = session.courtType.rawValue
        self.locationTag = session.locationTag
        self.notes = session.notes
        self.shotsAttempted = session.shotsAttempted
        self.shotsMade = session.shotsMade
        self.fgPercent = session.fgPercent
        self.avgReleaseAngleDeg = session.avgReleaseAngleDeg
        self.avgReleaseTimeMs = session.avgReleaseTimeMs
        self.avgVerticalJumpCm = session.avgVerticalJumpCm
        self.avgShotSpeedMph = session.avgShotSpeedMph
        self.consistencyScore = session.consistencyScore
        self.videoPinnedByUser = session.videoPinnedByUser
        self.totalDribbles = session.totalDribbles
        self.avgDribblesPerSec = session.avgDribblesPerSec
        self.maxDribblesPerSec = session.maxDribblesPerSec
        self.handBalanceFraction = session.handBalanceFraction
        self.dribbleCombosDetected = session.dribbleCombosDetected
        self.bestShuttleRunSeconds = session.bestShuttleRunSeconds
        self.bestLaneAgilitySeconds = session.bestLaneAgilitySeconds
        self.longestMakeStreak = session.longestMakeStreak
        self.shotSpeedStdDev = session.shotSpeedStdDev
    }
}
