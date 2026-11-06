// HoopTrackStore.swift
// The one place the SwiftData container is built. Everything — the app,
// Siri intents, tests — goes through here so the store is never opened
// with a partial schema. (The Home/Progress/Profile tabs used to each open
// their own `try!` container with four of the nine models, which can make
// Core Data migrate the on-disk store and drop the missing tables.)

import Foundation
import SwiftData

enum HoopTrackStore {

    static let schema = Schema([
        PlayerProfile.self, TrainingSession.self,
        ShotRecord.self, GoalRecord.self, EarnedBadge.self,
        GamePlayer.self, GameSession.self, GameShotRecord.self,
        TelemetryUpload.self, PlayoffSeries.self,
    ])

    /// Shared on-disk container for the app process.
    static let shared: ModelContainer = makePersistentContainer()

    /// Fresh in-memory container for tests and previews.
    static func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func makePersistentContainer() -> ModelContainer {
        // Flat schema: SwiftData migrates additive changes (new optional or
        // defaulted fields) on its own. A rename or type change needs a real
        // VersionedSchema with frozen copies of the old models — the previous
        // "V1/V2/V3" schemas all pointed at the live classes, so they were
        // identical and SwiftData would have rejected the plan.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
#if DEBUG
            // Development only: a schema change during development can leave an
            // unreadable store. Start fresh rather than crash on every launch.
            print("⚠️ HoopTrack: ModelContainer load failed (\(error)). Wiping store for fresh start.")
            let storeURL = config.url
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch let retryError {
                fatalError("HoopTrack: ModelContainer still failed after wipe — \(retryError)")
            }
#else
            fatalError("HoopTrack: Failed to create ModelContainer — \(error)")
#endif
        }
    }
}
