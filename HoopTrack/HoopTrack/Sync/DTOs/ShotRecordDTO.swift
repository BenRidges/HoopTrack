// HoopTrack/Sync/DTOs/ShotRecordDTO.swift
import Foundation

struct ShotRecordDTO: Codable, Sendable {
    let id: UUID
    let userId: UUID
    let sessionId: UUID
    var createdAt: Date

    var timestamp: Date
    var sequenceIndex: Int
    var result: String
    var zone: String
    var shotType: String
    var courtX: Double
    var courtY: Double
    var releaseAngleDeg: Double?
    var releaseTimeMs: Double?
    var verticalJumpCm: Double?
    var legAngleDeg: Double?
    var shotSpeedMph: Double?
    var videoTimestampSeconds: Double?
    var isUserCorrected: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case sessionId = "session_id"
        case createdAt = "created_at"
        case timestamp
        case sequenceIndex = "sequence_index"
        case result
        case zone
        case shotType = "shot_type"
        case courtX = "court_x"
        case courtY = "court_y"
        case releaseAngleDeg = "release_angle_deg"
        case releaseTimeMs = "release_time_ms"
        case verticalJumpCm = "vertical_jump_cm"
        case legAngleDeg = "leg_angle_deg"
        case shotSpeedMph = "shot_speed_mph"
        case videoTimestampSeconds = "video_timestamp_seconds"
        case isUserCorrected = "is_user_corrected"
    }

    @MainActor
    init(from shot: ShotRecord, userID: UUID, sessionID: UUID) {
        self.id = shot.id
        self.userId = userID
        self.sessionId = sessionID
        self.createdAt = shot.timestamp
        self.timestamp = shot.timestamp
        self.sequenceIndex = shot.sequenceIndex
        self.result = shot.result.rawValue
        self.zone = shot.zone.rawValue
        self.shotType = shot.shotType.rawValue
        self.courtX = shot.courtX
        self.courtY = shot.courtY
        self.releaseAngleDeg = shot.releaseAngleDeg
        self.releaseTimeMs = shot.releaseTimeMs
        self.verticalJumpCm = shot.verticalJumpCm
        self.legAngleDeg = shot.legAngleDeg
        self.shotSpeedMph = shot.shotSpeedMph
        self.videoTimestampSeconds = shot.videoTimestampSeconds
        self.isUserCorrected = shot.isUserCorrected
    }
}
