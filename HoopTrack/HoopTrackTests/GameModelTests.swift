import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class GameModelTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try HoopTrackStore.makeInMemoryContainer()
    }

    func test_insertingGameSession_persistsPlayersAndShots() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let session = GameSession(gameType: .pickup, gameFormat: .twoOnTwo)
        let player = GamePlayer(name: "Ben", teamAssignment: .teamA)
        session.players.append(player)

        let shot = GameShotRecord(
            shooter: player,
            result: .make,
            courtX: 0.5, courtY: 0.6,
            shotType: .threePoint
        )
        session.shots.append(shot)

        ctx.insert(session)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<GameSession>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.players.count, 1)
        XCTAssertEqual(fetched.first?.shots.count, 1)
        XCTAssertEqual(fetched.first?.shots.first?.shooter?.name, "Ben")
    }

    func test_deletingSession_cascadesToPlayersAndShots() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let session = GameSession(gameType: .pickup, gameFormat: .twoOnTwo)
        session.players.append(GamePlayer(name: "A", teamAssignment: .teamA))
        session.shots.append(
            GameShotRecord(shooter: nil, result: .miss, courtX: 0, courtY: 0, shotType: .twoPoint)
        )
        ctx.insert(session)
        try ctx.save()

        ctx.delete(session)
        try ctx.save()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<GameSession>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<GamePlayer>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<GameShotRecord>()).count, 0)
    }
}
