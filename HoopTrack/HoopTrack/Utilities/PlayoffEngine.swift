// PlayoffEngine.swift
// Best-of-seven playoffs, solo. Four rounds; each game is ten shots and
// you win it by making the round's target before missing enough to make
// that impossible (target 5 → win at 5 makes, lose at 6 misses). First to
// four games takes the series. The target rises each round.
//
// Knocked out, you don't start over: a comeback drill (three games' worth
// of makes, ideally from your weakest spot) earns the round back at 0–0.
//
// A run is a pure function of its shots in order, so it's never stored,
// only replayed. Undo, a corrected call or a deleted session all just
// change the input. PlayoffSeries caches the result for lists.

import Foundation

nonisolated struct PlayoffGame: Codable, Equatable, Sendable {
    let round: Int
    /// Game number within the series, from 1.
    let number: Int
    let makes: Int
    let misses: Int
    let won: Bool
    /// The series score after this game.
    let seriesWins: Int
    let seriesLosses: Int
}

nonisolated enum PlayoffEvent: Equatable, Sendable {
    case gameWon(PlayoffGame)
    case gameLost(PlayoffGame)
    /// Took the series; `round` is the one just won.
    case seriesWon(round: Int, game: PlayoffGame)
    case eliminated(round: Int, game: PlayoffGame)
    case champion(PlayoffGame)
    /// Earned the round back; the series restarts at 0–0.
    case comebackComplete(round: Int)
}

nonisolated struct PlayoffRun: Equatable, Sendable {

    static let gameLength = 10
    static let winsToTakeSeries = 4
    static let roundCount = 4

    let spot: PlayoffSpot
    private(set) var round = 1
    private(set) var wins = 0
    private(set) var losses = 0
    private(set) var gameMakes = 0
    private(set) var gameMisses = 0
    private(set) var status: PlayoffStatus = .playing
    private(set) var comebackMakes = 0
    /// Every finished game, all rounds, in order.
    private(set) var games: [PlayoffGame] = []

    init(spot: PlayoffSpot) {
        self.spot = spot
    }

    /// Replays a run from its first shot.
    init(spot: PlayoffSpot, results: [ShotResult]) {
        self.init(spot: spot)
        for result in results { record(result) }
    }

    // MARK: Where things stand

    var makesToWin: Int { spot.makesToWin[min(round, Self.roundCount) - 1] }
    /// Misses that lose the game: one more than the ten shots can absorb.
    var missesToLose: Int { Self.gameLength + 1 - makesToWin }
    var gameNumber: Int { wins + losses + 1 }
    var comebackTarget: Int { makesToWin * 3 }
    var isOver: Bool { status == .champion || status == .retired }

    static func roundName(_ round: Int) -> String {
        switch round {
        case 1:  return "First round"
        case 2:  return "Second round"
        case 3:  return "Conference finals"
        default: return "The Finals"
        }
    }

    var roundName: String { Self.roundName(round) }

    // MARK: Shots

    /// Adds one shot. Returns what it decided, if anything.
    @discardableResult
    mutating func record(_ result: ShotResult) -> PlayoffEvent? {
        guard result != .pending else { return nil }
        switch status {
        case .champion, .retired:
            return nil

        case .comeback:
            guard result == .make else { return nil }
            comebackMakes += 1
            guard comebackMakes >= comebackTarget else { return nil }
            status = .playing
            comebackMakes = 0
            wins = 0
            losses = 0
            return .comebackComplete(round: round)

        case .playing:
            if result == .make { gameMakes += 1 } else { gameMisses += 1 }
            let won = gameMakes >= makesToWin
            guard won || gameMisses >= missesToLose else { return nil }

            let number = gameNumber
            if won { wins += 1 } else { losses += 1 }
            let game = PlayoffGame(round: round, number: number, makes: gameMakes, misses: gameMisses,
                                   won: won, seriesWins: wins, seriesLosses: losses)
            games.append(game)
            gameMakes = 0
            gameMisses = 0

            if wins == Self.winsToTakeSeries {
                if round == Self.roundCount {
                    status = .champion
                    return .champion(game)
                }
                let finished = round
                round += 1
                wins = 0
                losses = 0
                return .seriesWon(round: finished, game: game)
            }
            if losses == Self.winsToTakeSeries {
                status = .comeback
                return .eliminated(round: round, game: game)
            }
            return won ? .gameWon(game) : .gameLost(game)
        }
    }

    /// Marks the run as ended by the player.
    mutating func retire() {
        if !isOver { status = .retired }
    }

    // MARK: Comeback hint

    /// The zone with the lowest make rate among those with at least
    /// `minAttempts` shots; nil when none qualifies. Unplaced shots don't count.
    static func weakestZone(_ shots: [(zone: CourtZone, made: Bool)], minAttempts: Int = 5) -> CourtZone? {
        var tally: [CourtZone: (made: Int, total: Int)] = [:]
        for shot in shots where shot.zone != .unknown {
            var entry = tally[shot.zone] ?? (0, 0)
            entry.total += 1
            if shot.made { entry.made += 1 }
            tally[shot.zone] = entry
        }
        return tally
            .filter { $0.value.total >= minAttempts }
            .min { a, b in
                let ra = Double(a.value.made) / Double(a.value.total)
                let rb = Double(b.value.made) / Double(b.value.total)
                if ra != rb { return ra < rb }
                if a.value.total != b.value.total { return a.value.total > b.value.total }
                return a.key.rawValue < b.key.rawValue
            }?
            .key
    }
}
