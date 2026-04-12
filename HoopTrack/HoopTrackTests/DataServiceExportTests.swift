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
}
