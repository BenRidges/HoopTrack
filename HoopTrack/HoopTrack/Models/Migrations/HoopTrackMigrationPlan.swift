// HoopTrackMigrationPlan.swift
// Lightweight migration: new optional/default fields require no custom mapping.

import SwiftData

enum HoopTrackMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [HoopTrackSchemaV1.self, HoopTrackSchemaV2.self]
    }

    static var stages: [MigrationStage] { [migrateV1toV2] }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: HoopTrackSchemaV1.self,
        toVersion: HoopTrackSchemaV2.self
    )
}
