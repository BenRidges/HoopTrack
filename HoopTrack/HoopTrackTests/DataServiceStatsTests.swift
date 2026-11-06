// HoopTrackTests/DataServiceStatsTests.swift
// Career stats are recomputed from sessions, so deletes and corrections
// can't leave the profile out of step.
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class DataServiceStatsTests: XCTestCase {

    private var container: ModelContainer!
    private var sut: DataService!

    override func setUp() async throws {
        container = try HoopTrackStore.makeInMemoryContainer()
        sut = DataService(modelContext: container.mainContext)
    }

    override func tearDown() async throws {
        sut = nil
        container = nil
    }

    private func shootingSession(makes: Int, misses: Int) throws -> TrainingSession {
        let session = try sut.startSession(drillType: .freeShoot)
        for i in 0..<(makes + misses) {
            try sut.addShot(to: session, result: i < makes ? .make : .miss,
                            zone: .midRange, shotType: .unknown, courtX: 0.5, courtY: 0.4)
        }
        try sut.finaliseSession(session, activeDuration: 600)
        return session
    }

    func test_finalise_usesActiveDuration_andUpdatesCareer() throws {
        _ = try shootingSession(makes: 6, misses: 4)
        let profile = try sut.fetchOrCreateProfile()
        XCTAssertEqual(profile.careerShotsAttempted, 10)
        XCTAssertEqual(profile.careerShotsMade, 6)
        XCTAssertEqual(profile.totalSessionCount, 1)
        XCTAssertEqual(profile.totalTrainingMinutes, 10, accuracy: 0.01)
        XCTAssertEqual(profile.currentStreakDays, 1)
    }

    func test_deleteSession_removesItFromCareerTotals() throws {
        _ = try shootingSession(makes: 6, misses: 4)
        let second = try shootingSession(makes: 2, misses: 8)
        try sut.deleteSession(second)

        let profile = try sut.fetchOrCreateProfile()
        XCTAssertEqual(profile.careerShotsAttempted, 10)
        XCTAssertEqual(profile.careerShotsMade, 6)
        XCTAssertEqual(profile.totalSessionCount, 1)
    }

    func test_correctingAShot_updatesSessionAndCareer() throws {
        let session = try shootingSession(makes: 5, misses: 5)
        let firstMiss = session.orderedShots.first { $0.result == .miss }!
        sut.updateShot(firstMiss, result: .make)

        XCTAssertEqual(session.shotsMade, 6)
        XCTAssertEqual(session.fgPercent, 60, accuracy: 0.01)
        XCTAssertTrue(firstMiss.isUserCorrected)
        XCTAssertEqual(try sut.fetchOrCreateProfile().careerShotsMade, 6)
    }

    func test_deleteShot_renumbersNothing_butFixesStats() throws {
        let session = try shootingSession(makes: 3, misses: 1)
        sut.deleteShot(session.orderedShots.last!)
        XCTAssertEqual(session.shotsAttempted, 3)
        XCTAssertEqual(session.shotsMade, 3)
    }

    func test_longestMakeStreak_followsShotOrder() throws {
        let session = try sut.startSession(drillType: .freeShoot)
        for result in [ShotResult.make, .make, .miss, .make, .make, .make, .miss] {
            try sut.addShot(to: session, result: result, zone: .paint, shotType: .unknown,
                            courtX: 0.5, courtY: 0.2)
        }
        XCTAssertEqual(session.longestMakeStreak, 3)
    }

    func test_finalise_dropsUnresolvedPendingShot() throws {
        let session = try sut.startSession(drillType: .freeShoot)
        try sut.addShot(to: session, result: .make, zone: .paint, shotType: .unknown, courtX: 0.5, courtY: 0.2)
        try sut.addShot(to: session, result: .pending, zone: .paint, shotType: .unknown, courtX: 0.5, courtY: 0.2)
        try sut.finaliseSession(session)
        XCTAssertEqual(session.shots.count, 1)
        XCTAssertEqual(session.shotsAttempted, 1)
    }

    func test_dailyVolume_includesEmptyDays() throws {
        _ = try shootingSession(makes: 1, misses: 1)
        let volume = try sut.dailyVolume(lastDays: 7)
        XCTAssertEqual(volume.count, 7)
        XCTAssertEqual(volume.last?.attempts, 2)
        XCTAssertEqual(volume.first?.attempts, 0)
    }

    func test_gameScore_undoReversesPoints() throws {
        let context = container.mainContext
        let game = GameSession(gameType: .pickup, gameFormat: .twoOnTwo)
        context.insert(game)
        let player = GamePlayer(name: "A", appearanceEmbedding: Data(), teamAssignment: .teamA)
        context.insert(player)
        game.players.append(player)

        try sut.addGameShot(to: game, shooter: player, result: .make, shotType: .threePoint)
        try sut.addGameShot(to: game, shooter: player, result: .make, shotType: .twoPoint)
        XCTAssertEqual(game.teamAScore, 5)

        sut.undoLastGameShot(in: game)
        XCTAssertEqual(game.teamAScore, 3)
        XCTAssertEqual(game.shots.count, 1)
    }
}
