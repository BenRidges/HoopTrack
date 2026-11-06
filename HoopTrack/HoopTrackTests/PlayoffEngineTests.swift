// HoopTrackTests/PlayoffEngineTests.swift

import XCTest
@testable import HoopTrack

final class PlayoffEngineTests: XCTestCase {

    private let make = ShotResult.make, miss = ShotResult.miss

    private func shots(_ pattern: String) -> [ShotResult] {
        pattern.compactMap { $0 == "o" ? .make : $0 == "x" ? .miss : nil }
    }

    /// The shots that win (or lose) one game at the current target.
    private func win(_ run: PlayoffRun) -> [ShotResult] { Array(repeating: .make, count: run.makesToWin) }
    private func lose(_ run: PlayoffRun) -> [ShotResult] { Array(repeating: .miss, count: run.missesToLose) }

    func test_game_isWonAtTheTarget_beforeTenShots() {
        var run = PlayoffRun(spot: .threes)       // round 1: 4 makes
        XCTAssertEqual(run.makesToWin, 4)
        XCTAssertEqual(run.missesToLose, 7)
        var last: PlayoffEvent?
        for result in shots("oxoxoxo") { last = run.record(result) }
        XCTAssertEqual(last, .gameWon(PlayoffGame(round: 1, number: 1, makes: 4, misses: 3, won: true, seriesWins: 1, seriesLosses: 0)))
        XCTAssertEqual(run.wins, 1)
        XCTAssertEqual(run.gameMakes, 0)
    }

    func test_game_isLostOnceTheTargetIsOutOfReach() {
        var run = PlayoffRun(spot: .threes)
        var events: [PlayoffEvent?] = []
        for result in shots("xxxoxxxx") { events.append(run.record(result)) }
        // 1 make, 7 misses: only 2 shots left, 3 more makes needed.
        XCTAssertEqual(events.compactMap { $0 }.count, 1)
        XCTAssertEqual(run.losses, 1)
        XCTAssertEqual(run.games.first?.misses, 7)
    }

    func test_series_firstToFour_movesUpARound_withAHigherTarget() {
        var run = PlayoffRun(spot: .threes)
        var events: [PlayoffEvent] = []
        for _ in 0..<3 { events += win(run).compactMap { run.record($0) } }
        events += lose(run).compactMap { run.record($0) }
        events += win(run).compactMap { run.record($0) }
        XCTAssertEqual(events.last, .seriesWon(round: 1, game: PlayoffGame(round: 1, number: 5, makes: 4, misses: 0, won: true, seriesWins: 4, seriesLosses: 1)))
        XCTAssertEqual(run.round, 2)
        XCTAssertEqual(run.wins, 0)
        XCTAssertEqual(run.losses, 0)
        XCTAssertEqual(run.makesToWin, 5)
        XCTAssertEqual(run.roundName, "Second round")
    }

    func test_fourLosses_startsAComeback_thatEarnsTheRoundBack() {
        var run = PlayoffRun(spot: .midRange)     // round 1: 5 makes, comeback 15
        var last: PlayoffEvent?
        for _ in 0..<4 { for shot in lose(run) { last = run.record(shot) } }
        XCTAssertEqual(last, .eliminated(round: 1, game: PlayoffGame(round: 1, number: 4, makes: 0, misses: 6, won: false, seriesWins: 0, seriesLosses: 4)))
        XCTAssertEqual(run.status, .comeback)
        XCTAssertEqual(run.comebackTarget, 15)

        // Misses don't count against a comeback.
        XCTAssertNil(run.record(.miss))
        for _ in 0..<14 { XCTAssertNil(run.record(.make)) }
        XCTAssertEqual(run.record(.make), .comebackComplete(round: 1))
        XCTAssertEqual(run.status, .playing)
        XCTAssertEqual(run.round, 1)
        XCTAssertEqual(run.wins + run.losses, 0)
    }

    func test_winningTheFinals_isTheEnd() {
        var run = PlayoffRun(spot: .freeThrows)
        var last: PlayoffEvent?
        for _ in 0..<(4 * 4) { for shot in win(run) { last = run.record(shot) } }
        if case .champion(let game) = last {
            XCTAssertEqual(game.round, 4)
            XCTAssertEqual(game.makes, 9)
        } else {
            XCTFail("expected champion, got \(String(describing: last))")
        }
        XCTAssertEqual(run.status, .champion)
        XCTAssertNil(run.record(.make))
        XCTAssertEqual(run.games.count, 16)
    }

    func test_replay_matchesShotByShot() {
        let results = shots("ooooxxxxxxx" + "oooo" + "xoooo")
        var live = PlayoffRun(spot: .threes)
        for result in results { live.record(result) }
        XCTAssertEqual(PlayoffRun(spot: .threes, results: results), live)
        XCTAssertEqual(live.wins, 3)
        XCTAssertEqual(live.losses, 1)
    }

    func test_pendingShotsAreIgnored_andRetiringEndsTheRun() {
        var run = PlayoffRun(spot: .threes)
        XCTAssertNil(run.record(.pending))
        XCTAssertEqual(run.gameMakes + run.gameMisses, 0)
        run.retire()
        XCTAssertTrue(run.isOver)
        XCTAssertNil(run.record(.make))
    }

    func test_weakestZone_needsEnoughShots() {
        let shots: [(zone: CourtZone, made: Bool)] =
            Array(repeating: (.cornerThree, false), count: 4)              // too few
            + Array(repeating: (.midRange, true), count: 6) + [(.midRange, false), (.midRange, false)]
            + Array(repeating: (.paint, true), count: 3) + Array(repeating: (.paint, false), count: 3)
            + Array(repeating: (.unknown, false), count: 20)
        XCTAssertEqual(PlayoffRun.weakestZone(shots), .paint)
        XCTAssertNil(PlayoffRun.weakestZone([(.paint, false)]))
    }
}
