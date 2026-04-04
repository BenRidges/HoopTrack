// TrainingSession.swift
// SwiftData model — one complete training session.
// Holds session-level metadata plus a cascade of ShotRecord children.

import Foundation
import SwiftData

@Model
final class TrainingSession {

    // MARK: - Identity
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double     // wall-clock duration

    // MARK: - Classification
    var drillType: DrillType
    var namedDrill: NamedDrill?     // nil for free-form sessions
    var courtType: CourtType
    var locationTag: String         // freeform ("Home Gym", "Rec Center", …)
    var notes: String

    // MARK: - Aggregate Stats (cached at session end, derived from ShotRecord children)
    var shotsAttempted: Int
    var shotsMade: Int
    var fgPercent: Double           // cached to avoid re-querying on list views

    // MARK: - Shot Science Averages (populated in Phase 3)
    var avgReleaseAngleDeg: Double?
    var avgReleaseTimeMs: Double?
    var avgVerticalJumpCm: Double?
    var avgShotSpeedMph: Double?
    var consistencyScore: Double?   // lower = more consistent

    // MARK: - Video
    var videoFileName: String?      // stored in Documents/Sessions/<id>.mov
    var videoPinnedByUser: Bool     // prevents auto-deletion

    // MARK: - Relationships
    var profile: PlayerProfile?
    @Relationship(deleteRule: .cascade) var shots: [ShotRecord]

    init(drillType: DrillType,
         namedDrill: NamedDrill? = nil,
         courtType: CourtType = .nba,
         locationTag: String = "",
         notes: String = "") {

        self.id              = UUID()
        self.startedAt       = .now
        self.endedAt         = nil
        self.durationSeconds = 0

        self.drillType       = drillType
        self.namedDrill      = namedDrill
        self.courtType       = courtType
        self.locationTag     = locationTag
        self.notes           = notes

        self.shotsAttempted  = 0
        self.shotsMade       = 0
        self.fgPercent       = 0

        self.avgReleaseAngleDeg = nil
        self.avgReleaseTimeMs   = nil
        self.avgVerticalJumpCm  = nil
        self.avgShotSpeedMph    = nil
        self.consistencyScore   = nil

        self.videoFileName      = nil
        self.videoPinnedByUser  = false

        self.shots              = []
    }

    // MARK: - Helpers

    var isComplete: Bool { endedAt != nil }

    var formattedDuration: String {
        let mins = Int(durationSeconds) / 60
        let secs = Int(durationSeconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    /// Re-derives and caches aggregate stats from the shots array.
    /// Call after adding/editing shot records, and before saving context.
    func recalculateStats() {
        let completedShots = shots.filter { $0.result != .pending }
        shotsAttempted = completedShots.count
        shotsMade      = completedShots.filter { $0.result == .make }.count
        fgPercent      = shotsAttempted > 0
            ? Double(shotsMade) / Double(shotsAttempted) * 100
            : 0

        // MARK: Shot Science averages
        func avg(_ values: [Double?]) -> Double? {
            let v = values.compactMap { $0 }
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }

        avgReleaseAngleDeg = avg(completedShots.map { $0.releaseAngleDeg })
        avgReleaseTimeMs   = avg(completedShots.map { $0.releaseTimeMs   })
        avgVerticalJumpCm  = avg(completedShots.map { $0.verticalJumpCm  })
        avgShotSpeedMph    = avg(completedShots.map { $0.shotSpeedMph    })

        // Consistency score = population std dev of release angles
        let angles = completedShots.compactMap { $0.releaseAngleDeg }
        consistencyScore = ShotScienceCalculator.consistencyScore(releaseAngles: angles)
    }

    // MARK: - Zone Breakdown

    struct ZoneStat {
        let zone: CourtZone
        let attempted: Int
        let made: Int
        var fgPercent: Double {
            attempted > 0 ? Double(made) / Double(attempted) * 100 : 0
        }
    }

    var zoneStats: [ZoneStat] {
        CourtZone.allCases.compactMap { zone -> ZoneStat? in
            let zoneShots = shots.filter { $0.zone == zone && $0.result != .pending }
            guard !zoneShots.isEmpty else { return nil }
            return ZoneStat(
                zone: zone,
                attempted: zoneShots.count,
                made: zoneShots.filter { $0.result == .make }.count
            )
        }
    }
}
