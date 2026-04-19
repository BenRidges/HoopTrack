import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class GameModelTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: GamePlayer.self, GameSession.self, GameShotRecord.self,
            configurations: config
        )
    }

    private func makeDescriptorBlob() throws -> Data {
        let desc = AppearanceDescriptor(
            torsoHueHistogram: Array(repeating: 0.125, count: 8),
            torsoValueHistogram: Array(repeating: 0.25, count: 4),
            heightRatio: 0.5,
            upperBodyAspect: 0.6,
            schemaVersion: 1
        )
        return try JSONEncoder().encode(desc)
    }

    func test_insertingGameSession_persistsPlayersAndShots() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let blob = try makeDescriptorBlob()
        let session = GameSession(gameType: .pickup, gameFormat: .twoOnTwo)
        let player = GamePlayer(
            name: "Ben",
            appearanceEmbedding: blob,
            teamAssignment: .teamA
        )
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

        let blob = try makeDescriptorBlob()
        let session = GameSession(gameType: .pickup, gameFormat: .twoOnTwo)
        session.players.append(
            GamePlayer(name: "A", appearanceEmbedding: blob, teamAssignment: .teamA)
        )
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

    func test_appearanceDescriptor_roundTripsThroughGamePlayer() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let desc = AppearanceDescriptor(
            torsoHueHistogram: Array(repeating: 0.125, count: 8),
            torsoValueHistogram: Array(repeating: 0.25, count: 4),
            heightRatio: 0.42,
            upperBodyAspect: 0.6,
            schemaVersion: 1
        )
        let blob = try JSONEncoder().encode(desc)
        let player = GamePlayer(name: "X", appearanceEmbedding: blob, teamAssignment: .teamA)
        ctx.insert(player)
        try ctx.save()

        let decoded = player.appearanceDescriptor
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.heightRatio ?? 0, 0.42, accuracy: 1e-6)
    }
}
