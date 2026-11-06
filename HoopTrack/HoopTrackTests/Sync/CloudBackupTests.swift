// HoopTrackTests/Sync/CloudBackupTests.swift
// The whole-store passes: backing up what hasn't gone yet, and restoring
// onto a phone without losing or resurrecting anything.
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class CloudBackupTests: XCTestCase {

    private var container: ModelContainer!
    private var dataService: DataService!
    private var mock: MockSupabaseDataService!
    private var sut: SyncCoordinator!
    private let userID = UUID()

    override func setUp() async throws {
        container = try HoopTrackStore.makeInMemoryContainer()
        dataService = DataService(modelContext: container.mainContext)
        mock = MockSupabaseDataService()
        sut = SyncCoordinator(backend: mock)
    }

    override func tearDown() async throws {
        sut = nil
        mock = nil
        dataService = nil
        container = nil
    }

    private var context: ModelContext { container.mainContext }

    @discardableResult
    private func finishedSession(shots results: [ShotResult]) throws -> TrainingSession {
        let session = try dataService.startSession(drillType: .freeShoot)
        for result in results {
            try dataService.addShot(to: session, result: result, zone: .paint, shotType: .unknown,
                                    courtX: 0.5, courtY: 0.3)
        }
        try dataService.finaliseSession(session, activeDuration: 120)
        return session
    }

    /// A backed-up session as the server would hand it back, made from a
    /// throwaway model that never touches the test store.
    private func remote(shots: Int, makes: Int) -> (TrainingSessionDTO, [ShotRecordDTO]) {
        let session = TrainingSession(drillType: .freeShoot, namedDrill: .aroundTheArc)
        session.endedAt = .now
        session.shotsAttempted = shots
        session.shotsMade = makes
        let dtos = (0..<shots).map { i -> ShotRecordDTO in
            let shot = ShotRecord(sequenceIndex: i + 1, result: i < makes ? .make : .miss,
                                  zone: .cornerThree, shotType: .unknown, courtX: 0.1, courtY: 0.9)
            return ShotRecordDTO(from: shot, userID: userID, sessionID: session.id)
        }
        return (TrainingSessionDTO(from: session, userID: userID), dtos)
    }

    // MARK: - Backup

    func test_backUp_sendsOnlyWhatsNotUp_andSkipsSessionsInProgress() async throws {
        try finishedSession(shots: [.make, .miss])
        _ = try dataService.startSession(drillType: .freeShoot)         // still running

        let sent = try await sut.backUpEverything(userID: userID, context: context)
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(mock.shotUpserts.flatMap { $0 }.count, 2)

        let again = try await sut.backUpEverything(userID: userID, context: context)
        XCTAssertEqual(again, 0)
        XCTAssertEqual(mock.shotUpserts.flatMap { $0 }.count, 2)          // nothing re-sent
    }

    func test_backUp_resendsACorrectedSession() async throws {
        let session = try finishedSession(shots: [.make, .miss])
        try await sut.backUpEverything(userID: userID, context: context)

        dataService.updateShot(session.orderedShots[1], result: .make)
        let sent = try await sut.backUpEverything(userID: userID, context: context)
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(mock.sessionUpserts.last?.shotsMade, 2)
    }

    func test_backUp_keepsGoingPastAFailure_thenThrows() async throws {
        try finishedSession(shots: [.make])
        mock.scriptedError = NSError(domain: "offline", code: -1009)
        do {
            try await sut.backUpEverything(userID: userID, context: context)
            XCTFail("expected the failure to surface")
        } catch {}
        XCTAssertNil(try context.fetch(FetchDescriptor<TrainingSession>()).first?.cloudSyncedAt)
    }

    // MARK: - Restore

    func test_restore_bringsBackSessionsWithTheirShots() async throws {
        let (session, shots) = remote(shots: 4, makes: 3)
        mock.remoteSessions = [session]
        mock.remoteShots = shots

        let report = try await sut.restore(userID: userID, context: context)
        XCTAssertEqual(report.sessions, 1)
        XCTAssertEqual(report.shots, 4)

        let restored = try XCTUnwrap(try context.fetch(FetchDescriptor<TrainingSession>()).first)
        XCTAssertEqual(restored.id, session.id)
        XCTAssertEqual(restored.namedDrill, .aroundTheArc)
        XCTAssertEqual(restored.shots.count, 4)
        XCTAssertEqual(restored.shotsMade, 3)
        XCTAssertNotNil(restored.cloudSyncedAt)                        // already in the cloud
    }

    func test_restore_twice_addsNothing() async throws {
        let (session, shots) = remote(shots: 2, makes: 1)
        mock.remoteSessions = [session]
        mock.remoteShots = shots
        _ = try await sut.restore(userID: userID, context: context)
        let second = try await sut.restore(userID: userID, context: context)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ShotRecord>()), 2)
    }

    func test_restore_neverAddsShotsToASessionAlreadyHere() async throws {
        // A shot deleted on this phone is still in the cloud: it stays gone.
        let local = try finishedSession(shots: [.make])
        let ghost = ShotRecord(sequenceIndex: 2, result: .miss, zone: .paint, shotType: .unknown,
                               courtX: 0.5, courtY: 0.3)
        mock.remoteSessions = [TrainingSessionDTO(from: local, userID: userID)]
        mock.remoteShots = [ShotRecordDTO(from: ghost, userID: userID, sessionID: local.id)]

        let report = try await sut.restore(userID: userID, context: context)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(local.shots.count, 1)
    }

    func test_restore_keepsTheBadgeAlreadyEarnedHere() async throws {
        let profile = try dataService.fetchOrCreateProfile()
        context.insert(EarnedBadge(badgeID: .deadeye, initialMMR: 900, profile: profile))
        try context.save()
        mock.remoteBadges = [
            EarnedBadgeDTO(from: EarnedBadge(badgeID: .deadeye, initialMMR: 100), userID: userID),
            EarnedBadgeDTO(from: EarnedBadge(badgeID: .sniper, initialMMR: 300), userID: userID),
        ]
        let report = try await sut.restore(userID: userID, context: context)
        XCTAssertEqual(report.badges, 1)
        let badges = try context.fetch(FetchDescriptor<EarnedBadge>())
        XCTAssertEqual(badges.first { $0.badgeID == .deadeye }?.mmr, 900)
    }
}
