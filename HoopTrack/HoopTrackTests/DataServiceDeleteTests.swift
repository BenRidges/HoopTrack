// HoopTrackTests/DataServiceDeleteTests.swift
// Phase 7 — Security / GDPR right-to-delete tests
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class DataServiceDeleteTests: XCTestCase {

    private var container: ModelContainer!
    private var service: DataService!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([
            PlayerProfile.self, TrainingSession.self,
            ShotRecord.self, GoalRecord.self, EarnedBadge.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        service = DataService(modelContext: container.mainContext)
    }

    override func tearDown() async throws {
        service = nil
        container = nil
        try await super.tearDown()
    }

    func test_deleteAllUserData_doesNotThrow() async throws {
        // Empty store — must not throw
        await service.deleteAllUserData()
    }

    func test_deleteAllUserData_clearsKeychainEntries() async throws {
        let keychain = KeychainService()
        keychain.save("tok_123", forKey: HoopTrack.KeychainKey.accessToken)
        keychain.save("uid_456", forKey: HoopTrack.KeychainKey.userID)

        await service.deleteAllUserData()

        XCTAssertNil(keychain.string(forKey: HoopTrack.KeychainKey.accessToken))
        XCTAssertNil(keychain.string(forKey: HoopTrack.KeychainKey.userID))

        // Clean up to avoid polluting other tests
        keychain.deleteAll()
    }

    // Phase 7 — Security: EarnedBadge records must be wiped on account deletion
    func test_deleteAllUserData_clearsEarnedBadges() async throws {
        let context = container.mainContext
        let profile = PlayerProfile()
        context.insert(profile)
        let badge = EarnedBadge(badgeID: .hotHand, initialMMR: 900, profile: profile)
        context.insert(badge)
        profile.earnedBadges.append(badge)
        try context.save()

        await service.deleteAllUserData()

        let remaining = try context.fetch(FetchDescriptor<EarnedBadge>())
        XCTAssertTrue(remaining.isEmpty, "EarnedBadge records must be deleted by deleteAllUserData()")
    }

    // Phase 7 — Security: exported JSON temp files must be removed on account deletion
    func test_deleteAllUserData_purgesExportedTempFiles() async throws {
        // Write a fake export file matching the ExportService naming convention
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooptrack-export-2026-01-01-120000.json")
        try "{}".data(using: .utf8)!.write(to: tmpURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpURL.path))

        await service.deleteAllUserData()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path),
                       "Exported JSON temp files must be deleted by deleteAllUserData()")
    }
}
