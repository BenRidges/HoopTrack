// ShotExportRecord.swift
// Codable value type for shot-level export. Plain struct — not a SwiftData @Model.

import Foundation

struct ShotExportRecord: Codable {
    let zone: String                   // CourtZone.rawValue
    let made: Bool
    let releaseAngleDeg: Double?
    let releaseTimeMs: Double?
    let shotSpeedMph: Double?
    let courtX: Double
    let courtY: Double
}

extension ShotExportRecord {
    init(from record: ShotRecord) {
        self.zone             = record.zone.rawValue
        self.made             = record.result == .make
        self.releaseAngleDeg  = record.releaseAngleDeg
        self.releaseTimeMs    = record.releaseTimeMs
        self.shotSpeedMph     = record.shotSpeedMph
        self.courtX           = record.courtX
        self.courtY           = record.courtY
    }
}
