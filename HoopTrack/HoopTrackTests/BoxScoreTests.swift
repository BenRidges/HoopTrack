// HoopTrackTests/BoxScoreTests.swift
import XCTest
@testable import HoopTrack

final class BoxScoreTests: XCTestCase {

    private let ana = BoxScore.Player(id: UUID(), name: "Ana", team: .teamA)
    private let ben = BoxScore.Player(id: UUID(), name: "Ben", team: .teamA)
    private let cat = BoxScore.Player(id: UUID(), name: "Cat", team: .teamB)

    func test_lines_countPointsAndShooting() {
        let shots = [
            BoxScore.Shot(shooterID: ana.id, made: true, isThree: true),
            BoxScore.Shot(shooterID: ana.id, made: false, isThree: false),
            BoxScore.Shot(shooterID: ana.id, made: true, isThree: false),
            BoxScore.Shot(shooterID: cat.id, made: true, isThree: false),
        ]
        let lines = BoxScore.lines(players: [ana, ben, cat], shots: shots)
        XCTAssertEqual(lines.map(\.name), ["Ana", "Ben", "Cat"])
        XCTAssertEqual(lines[0].points, 5)
        XCTAssertEqual(lines[0].made, 2)
        XCTAssertEqual(lines[0].attempts, 3)
        XCTAssertEqual(lines[0].threesMade, 1)
        XCTAssertNil(lines[1].fgPercent)
        XCTAssertEqual(BoxScore.points(for: .teamA, in: lines), 5)
        XCTAssertEqual(BoxScore.points(for: .teamB, in: lines), 2)
    }

    func test_unattributedShots_areIgnored() {
        let lines = BoxScore.lines(players: [ana], shots: [BoxScore.Shot(shooterID: nil, made: true, isThree: true)])
        XCTAssertEqual(lines[0].points, 0)
    }

    func test_winner_needsTargetAndLead() {
        XCTAssertEqual(BoxScore.winner(teamA: 21, teamB: 15, target: 21), .teamA)
        XCTAssertEqual(BoxScore.winner(teamA: 9, teamB: 11, target: 11), .teamB)
        XCTAssertNil(BoxScore.winner(teamA: 20, teamB: 15, target: 21))
        XCTAssertNil(BoxScore.winner(teamA: 30, teamB: 2, target: nil))
    }

    func test_rosterNames_fillBlanks() {
        XCTAssertEqual(BoxScore.rosterNames(["  Ana ", "", "Cat"]), ["Ana", "Player 2", "Cat"])
    }
}
