// HoopTrackSchemaV1.swift
// Captures the original schema (before Phase 5A) for migration bookkeeping.

import SwiftData

enum HoopTrackSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [PlayerProfile.self, TrainingSession.self, ShotRecord.self, GoalRecord.self]
    }
}

enum HoopTrackSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [PlayerProfile.self, TrainingSession.self, ShotRecord.self, GoalRecord.self, EarnedBadge.self]
    }
}
