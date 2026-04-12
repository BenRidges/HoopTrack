// HoopTrackTests/DataServiceExportTests.swift
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class DataServiceExportTests: XCTestCase {

    private var container: ModelContainer!
    private var sut: DataService!

    override func setUp() async throws {
        let schema = Schema([
            PlayerProfile.self, TrainingSession.self,
            ShotRecord.self, GoalRecord.self, EarnedBadge.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        sut = DataService(modelContext: container.mainContext)
    }

    override func tearDown() async throws {
        container = nil
        sut = nil
    }

    func test_fetchShotsTodayCount_returnsZeroWhenNoSessions() throws {
        let count = try sut.fetchShotsTodayCount()
        XCTAssertEqual(count, 0)
    }

    func test_fetchShotsTodayCount_returnsCorrectShotTotal() throws {
        // Arrange
        let session = try sut.startSession(drillType: .freeShoot)
        _ = try sut.addShot(to: session, result: .make,
                            zone: .midRange, shotType: .catchAndShoot,
                            courtX: 0.5, courtY: 0.5)
        _ = try sut.addShot(to: session, result: .miss,
                            zone: .midRange, shotType: .catchAndShoot,
                            courtX: 0.4, courtY: 0.6)
        try sut.finaliseSession(session)

        // Act
        let count = try sut.fetchShotsTodayCount()

        // Assert
        XCTAssertEqual(count, 2)
    }

    func test_fetchSessionsSince_returnsOnlySessionsAfterCutoff() throws {
        // Arrange — create a session, then fabricate a "yesterday" check
        let session = try sut.startSession(drillType: .freeShoot)
        try sut.finaliseSession(session)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let futureDate = Calendar.current.date(byAdding: .day, value: +1, to: .now)!

        // Act
        let sinceYesterday = try sut.fetchSessions(since: yesterday)
        let sinceTomorrow  = try sut.fetchSessions(since: futureDate)

        // Assert
        XCTAssertEqual(sinceYesterday.count, 1)
        XCTAssertEqual(sinceTomorrow.count,  0)
    }

    func test_fetchSessionsSince_respectsLimit() throws {
        for _ in 0..<5 {
            let s = try sut.startSession(drillType: .freeShoot)
            try sut.finaliseSession(s)
        }
        let epoch = Date(timeIntervalSince1970: 0)
        let result = try sut.fetchSessions(since: epoch, limit: 3)
        XCTAssertEqual(result.count, 3)
    }
}
