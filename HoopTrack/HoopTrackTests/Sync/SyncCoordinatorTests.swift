// HoopTrackTests/Sync/SyncCoordinatorTests.swift
import XCTest
@testable import HoopTrack

@MainActor
final class SyncCoordinatorTests: XCTestCase {

    // MARK: - Session + shots happy path

    func test_syncSession_uploadsSession_andAllShots() async throws {
        let mock = MockSupabaseDataService()
        let coordinator = SyncCoordinator(backend: mock)
        let userID = UUID()

        let session = TrainingSession(drillType: .freeShoot)
        session.shots = (1...3).map {
            let shot = ShotRecord(sequenceIndex: $0,
                                    result: .make,
                                    zone: .midRange,
                                    shotType: .catchAndShoot,
                                    courtX: 0.5, courtY: 0.5)
            shot.session = session
            return shot
        }

        try await coordinator.syncSession(session, userID: userID)

        XCTAssertEqual(mock.sessionUpserts.count, 1)
        XCTAssertEqual(mock.sessionUpserts.first?.id, session.id)
        XCTAssertEqual(mock.shotInserts.count, 1)
        XCTAssertEqual(mock.shotInserts.first?.count, 3)
    }

    func test_syncSession_withNoShots_skipsShotInsert() async throws {
        let mock = MockSupabaseDataService()
        let coordinator = SyncCoordinator(backend: mock)
        let session = TrainingSession(drillType: .freeShoot)
        session.shots = []

        try await coordinator.syncSession(session, userID: UUID())

        XCTAssertEqual(mock.sessionUpserts.count, 1)
        XCTAssertEqual(mock.shotInserts.count, 0)
    }

    // MARK: - cloudSyncedAt stamping

    func test_syncSession_stampsCloudSyncedAt_onSuccess() async throws {
        let mock = MockSupabaseDataService()
        let coordinator = SyncCoordinator(backend: mock)
        let session = TrainingSession(drillType: .freeShoot)
        session.shots = []
        XCTAssertNil(session.cloudSyncedAt)

        try await coordinator.syncSession(session, userID: UUID())

        XCTAssertNotNil(session.cloudSyncedAt)
    }

    func test_syncSession_stampsAllShots_onSuccess() async throws {
        let mock = MockSupabaseDataService()
        let coordinator = SyncCoordinator(backend: mock)
        let session = TrainingSession(drillType: .freeShoot)
        session.shots = (1...2).map {
            ShotRecord(sequenceIndex: $0, result: .make, zone: .paint,
                        shotType: .catchAndShoot, courtX: 0.5, courtY: 0.2)
        }
        XCTAssertTrue(session.shots.allSatisfy { $0.cloudSyncedAt == nil })

        try await coordinator.syncSession(session, userID: UUID())

        XCTAssertTrue(session.shots.allSatisfy { $0.cloudSyncedAt != nil })
    }

    // MARK: - Error paths

    func test_syncSession_propagatesBackendError_anddoesNotStamp() async {
        let mock = MockSupabaseDataService()
        mock.scriptedError = NSError(domain: "test", code: -1)
        let coordinator = SyncCoordinator(backend: mock)
        let session = TrainingSession(drillType: .freeShoot)
        session.shots = []

        do {
            try await coordinator.syncSession(session, userID: UUID())
            XCTFail("expected throw")
        } catch {
            XCTAssertNil(session.cloudSyncedAt)
        }
    }

    // MARK: - Profile / goal / badge

    func test_syncProfile_upsertsOnce_andStamps() async throws {
        let mock = MockSupabaseDataService()
        let coordinator = SyncCoordinator(backend: mock)
        let profile = PlayerProfile()

        try await coordinator.syncProfile(profile, userID: UUID())

        XCTAssertEqual(mock.profileUpserts.count, 1)
        XCTAssertNotNil(profile.cloudSyncedAt)
    }

    func test_syncGoal_upsertsOnce_andStamps() async throws {
        let mock = MockSupabaseDataService()
        let coordinator = SyncCoordinator(backend: mock)
        let goal = GoalRecord(title: "T", skill: .shooting, metric: .fgPercent,
                                targetValue: 50, baselineValue: 30)

        try await coordinator.syncGoal(goal, userID: UUID())

        XCTAssertEqual(mock.goalUpserts.count, 1)
        XCTAssertNotNil(goal.cloudSyncedAt)
    }

    func test_syncBadge_upsertsOnce_andStamps() async throws {
        let mock = MockSupabaseDataService()
        let coordinator = SyncCoordinator(backend: mock)
        let badge = EarnedBadge(badgeID: .deadeye, initialMMR: 500)

        try await coordinator.syncBadge(badge, userID: UUID())

        XCTAssertEqual(mock.badgeUpserts.count, 1)
        XCTAssertNotNil(badge.cloudSyncedAt)
    }
}
