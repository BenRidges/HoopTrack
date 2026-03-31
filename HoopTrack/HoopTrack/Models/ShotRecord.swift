// ShotRecord.swift
// SwiftData model — one individual shot attempt within a session.
// Normalised court coordinates use a 0–1 range (origin = bottom-left of half-court).

import Foundation
import SwiftData

@Model
final class ShotRecord {

    // MARK: - Identity
    var id: UUID
    var timestamp: Date             // wall-clock time of the attempt
    var sequenceIndex: Int          // shot number within the session (1-based)

    // MARK: - Classification
    var result: ShotResult
    var zone: CourtZone
    var shotType: ShotType

    // MARK: - Court Position (normalised 0–1 half-court space)
    // x = 0 → left baseline, x = 1 → right baseline
    // y = 0 → baseline, y = 1 → half-court line
    var courtX: Double
    var courtY: Double

    // MARK: - Shot Science (Phase 3 — Vision body pose)
    var releaseAngleDeg: Double?    // 43–57° optimal
    var releaseTimeMs: Double?      // ms from pickup to release
    var verticalJumpCm: Double?     // estimated jump height
    var legAngleDeg: Double?        // knee bend at jump initiation
    var shotSpeedMph: Double?       // estimated ball velocity post-release

    // MARK: - Video
    var videoTimestampSeconds: Double?  // offset into session video for thumbnail
    var isUserCorrected: Bool           // true if user edited result/position

    // MARK: - Relationship
    var session: TrainingSession?

    init(sequenceIndex: Int,
         result: ShotResult = .pending,
         zone: CourtZone = .unknown,
         shotType: ShotType = .unknown,
         courtX: Double = 0.5,
         courtY: Double = 0.5) {

        self.id              = UUID()
        self.timestamp       = .now
        self.sequenceIndex   = sequenceIndex

        self.result          = result
        self.zone            = zone
        self.shotType        = shotType

        self.courtX          = courtX
        self.courtY          = courtY

        self.releaseAngleDeg = nil
        self.releaseTimeMs   = nil
        self.verticalJumpCm  = nil
        self.legAngleDeg     = nil
        self.shotSpeedMph    = nil

        self.videoTimestampSeconds = nil
        self.isUserCorrected       = false
    }

    // MARK: - Helpers

    var isMake: Bool { result == .make }
    var isMiss: Bool { result == .miss }

    /// Normalised court position as CGPoint for use in canvas drawing.
    var courtPosition: CGPoint { CGPoint(x: courtX, y: courtY) }
}
