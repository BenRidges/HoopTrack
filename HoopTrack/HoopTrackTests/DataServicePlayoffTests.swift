// HoopTrackTests/DataServicePlayoffTests.swift
// A playoff run is replayed from its sessions' shots, so it survives
// sittings, undo and corrections without its own bookkeeping going stale.
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class DataServicePlayoffTests: XCTestCase {

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

    @discardableResult
    private func sitting(_ series: PlayoffSeries?, _ pattern: String) throws -> TrainingSession {
        let session = try sut.startSession(drillType: .freeShoot, playoffSeriesID: series?.id)
        for c in pattern {
            try sut.addShot(to: session, result: c == "o" ? .make : .miss,
                            zone: .aboveBreakThree, shotType: .unknown, courtX: 0.5, courtY: 0.8)
        }
        try sut.finaliseSession(session, activeDuration: 300)
        if let series { sut.refreshPlayoff(series) }
        return session
    }

    func test_run_carriesAcrossSittings_andIgnoresOtherSessions() throws {
        let series = try sut.startPlayoffSeries(spot: .threes)     // 4 makes wins a game
        try sitting(series, "oooo" + "oo")                          // game 1 won, game 2 at 2 makes
        try sitting(nil, "xxxxxxxxxx")                              // ordinary session
        try sitting(series, "oo")                                   // game 2 won
        XCTAssertEqual(series.wins, 2)
        XCTAssertEqual(series.losses, 0)
        XCTAssertEqual(series.gamesPlayed, 2)
        XCTAssertEqual(sut.playoffRun(for: series).gameMakes, 0)
    }

    func test_undoAndCorrections_reopenAGame() throws {
        let series = try sut.startPlayoffSeries(spot: .threes)
        let session = try sitting(series, "oooo")
        XCTAssertEqual(series.wins, 1)

        sut.deleteShot(session.orderedShots.last!)                  // undo the winner
        XCTAssertEqual(series.wins, 0)
        XCTAssertEqual(sut.playoffRun(for: series).gameMakes, 3)

        sut.updateShot(session.orderedShots.first!, result: .miss)  // corrected later
        let run = sut.playoffRun(for: series)
        XCTAssertEqual(run.gameMakes, 2)
        XCTAssertEqual(run.gameMisses, 1)
    }

    func test_startingANewRun_endsTheOldOne() throws {
        let first = try sut.startPlayoffSeries(spot: .threes)
        let second = try sut.startPlayoffSeries(spot: .freeThrows)
        XCTAssertEqual(first.status, .retired)
        XCTAssertNotNil(first.retiredAt)
        XCTAssertEqual(sut.activePlayoffSeries()?.id, second.id)
        XCTAssertTrue(sut.playoffRun(for: first).isOver)
    }

    func test_playoffSessions_areTitledAndCountTowardStats() throws {
        let series = try sut.startPlayoffSeries(spot: .midRange)
        let session = try sitting(series, "oxo")
        XCTAssertEqual(session.title, "Playoffs")
        XCTAssertEqual(try sut.fetchOrCreateProfile().careerShotsAttempted, 3)
    }

    func test_deleteAllUserData_removesRuns() async throws {
        _ = try sut.startPlayoffSeries(spot: .threes)
        await sut.deleteAllUserData()
        XCTAssertNil(sut.activePlayoffSeries())
    }
}
