// SessionExportRecord.swift
// Codable value type for session-level export. Plain struct — not a SwiftData @Model.

import Foundation

struct SessionExportRecord: Codable {
    let id: String                     // UUID string
    let date: Date
    let drillType: String              // DrillType.rawValue
    let durationSeconds: Double
    let fgPercent: Double
    let threePointPercent: Double?
    let shots: [ShotExportRecord]
}

extension SessionExportRecord {
    init(from session: TrainingSession) {
        self.id                 = session.id.uuidString
        self.date               = session.startedAt
        self.drillType          = session.drillType.rawValue
        self.durationSeconds    = session.durationSeconds
        self.fgPercent          = session.fgPercent / 100.0   // 0–1 range
        self.threePointPercent  = session.threePointPercentage.map { $0 / 100.0 }
        self.shots              = session.shots
            .filter { $0.result != .pending }
            .map    { ShotExportRecord(from: $0) }
    }
}
