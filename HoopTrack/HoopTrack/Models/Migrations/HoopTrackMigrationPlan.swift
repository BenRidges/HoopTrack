// HoopTrackMigrationPlan.swift
// Lightweight migration: new optional/default fields require no custom mapping.

import SwiftData

enum HoopTrackMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [HoopTrackSchemaV1.self, HoopTrackSchemaV2.self, HoopTrackSchemaV3.self]
    }

    static var stages: [MigrationStage] { [migrateV1toV2, migrateV2toV3] }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: HoopTrackSchemaV1.self,
        toVersion: HoopTrackSchemaV2.self
    )

    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: HoopTrackSchemaV2.self,
        toVersion: HoopTrackSchemaV3.self
    )
}
