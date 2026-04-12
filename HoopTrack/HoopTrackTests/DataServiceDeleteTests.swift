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
}
