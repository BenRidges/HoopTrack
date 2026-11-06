// BoxScore.swift
// Per-player lines for a pickup game, from plain values so it can be
// tested without SwiftData.

import Foundation

nonisolated enum BoxScore {

    struct Player: Sendable, Equatable {
        let id: UUID
        let name: String
        let team: TeamAssignment
    }

    struct Shot: Sendable, Equatable {
        let shooterID: UUID?
        let made: Bool
        let isThree: Bool
    }

    struct Line: Sendable, Equatable, Identifiable {
        let id: UUID
        let name: String
        let team: TeamAssignment
        var points = 0
        var made = 0
        var attempts = 0
        var threesMade = 0
        var threeAttempts = 0

        var fgPercent: Double? { attempts > 0 ? Double(made) / Double(attempts) * 100 : nil }
    }

    static func lines(players: [Player], shots: [Shot]) -> [Line] {
        var byID: [UUID: Line] = [:]
        for player in players {
            byID[player.id] = Line(id: player.id, name: player.name, team: player.team)
        }
        for shot in shots {
            guard let id = shot.shooterID, var line = byID[id] else { continue }
            line.attempts += 1
            if shot.isThree { line.threeAttempts += 1 }
            if shot.made {
                line.made += 1
                line.points += shot.isThree ? 3 : 2
                if shot.isThree { line.threesMade += 1 }
            }
            byID[id] = line
        }
        // Keep roster order.
        return players.compactMap { byID[$0.id] }
    }

    static func points(for team: TeamAssignment, in lines: [Line]) -> Int {
        lines.filter { $0.team == team }.reduce(0) { $0 + $1.points }
    }

    /// The team that has reached `target` first, if any.
    static func winner(teamA: Int, teamB: Int, target: Int?) -> TeamAssignment? {
        guard let target else { return nil }
        if teamA >= target && teamA > teamB { return .teamA }
        if teamB >= target && teamB > teamA { return .teamB }
        return nil
    }

    /// Player names with blanks filled in: "Player 1", "Player 2", …
    static func rosterNames(_ raw: [String]) -> [String] {
        raw.enumerated().map { index, name in
            let trimmed = InputValidator.sanitisedProfileName(name) ?? ""
            return trimmed.isEmpty ? "Player \(index + 1)" : trimmed
        }
    }
}
