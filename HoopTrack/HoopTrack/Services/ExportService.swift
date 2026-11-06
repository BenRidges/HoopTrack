// ExportService.swift
// Transforms SwiftData profile + sessions into JSON and writes to a temp file.
// Returns a URL that can be passed directly to ShareLink or UIActivityViewController.

import Foundation
import SwiftData

/// Top-level export envelope — the JSON root object. Everything the player
/// made in the app: sessions with shots, goals, badges, pickup games and
/// playoff runs. (Pickup-game appearance data is left out: it's an on-device
/// matching aid, meaningless outside the app.)
private struct ProfileExport: Codable {
    let exportedAt: Date
    let profileName: String
    let career: Career
    let sessions: [SessionExportRecord]
    let goals: [Goal]
    let badges: [Badge]
    let games: [Game]
    let playoffRuns: [PlayoffRun]

    struct Career: Codable {
        let shotsAttempted: Int
        let shotsMade: Int
        let sessions: Int
        let trainingMinutes: Double
        let longestStreakDays: Int
    }

    struct Goal: Codable {
        let id: String
        let title: String
        let metric: String          // GoalMetric.rawValue (a stable key)
        let baselineValue: Double
        let currentValue: Double
        let targetValue: Double
        let targetDate: Date?
        let achievedAt: Date?
    }

    struct Badge: Codable {
        let badge: String           // BadgeID.rawValue
        let rank: String
        let mmr: Double
        let earnedAt: Date
    }

    struct Game: Codable {
        let date: Date
        let format: String
        let teamAScore: Int
        let teamBScore: Int
        let players: [Player]

        struct Player: Codable {
            let name: String
            let team: String
        }
    }

    struct PlayoffRun: Codable {
        let spot: String            // PlayoffSpot.rawValue
        let startedAt: Date
        let status: String
        let round: Int
        let wins: Int
        let losses: Int
        let gamesPlayed: Int
    }
}

@MainActor
final class ExportService {

    // MARK: - Public Interface

    /// Builds JSON from `profile` and writes it to a dated temp file.
    /// Each call creates a new file in the system temp directory.
    /// - Returns: URL of the written file.
    func exportJSON(for profile: PlayerProfile) async throws -> URL {
        let context = profile.modelContext
        let games = (try? context?.fetch(FetchDescriptor<GameSession>(
            sortBy: [SortDescriptor(\.startTimestamp, order: .reverse)]))) ?? []
        let runs = (try? context?.fetch(FetchDescriptor<PlayoffSeries>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []

        let envelope = ProfileExport(
            exportedAt:  .now,
            profileName: profile.name.isEmpty ? "Player" : profile.name,
            career: .init(shotsAttempted: profile.careerShotsAttempted,
                          shotsMade: profile.careerShotsMade,
                          sessions: profile.totalSessionCount,
                          trainingMinutes: profile.totalTrainingMinutes,
                          longestStreakDays: profile.longestStreakDays),
            sessions:    profile.sessions
                .filter { $0.isComplete }
                .sorted { $0.startedAt > $1.startedAt }
                .map    { SessionExportRecord(from: $0) },
            goals: profile.goals.sorted { $0.createdAt < $1.createdAt }.map {
                .init(id: $0.id.uuidString, title: $0.title, metric: $0.metric.rawValue,
                      baselineValue: $0.baselineValue, currentValue: $0.currentValue,
                      targetValue: $0.targetValue, targetDate: $0.targetDate, achievedAt: $0.achievedAt)
            },
            badges: profile.earnedBadges.sorted { $0.earnedAt < $1.earnedAt }.map {
                .init(badge: $0.badgeID.rawValue, rank: $0.rank.displayName, mmr: $0.mmr, earnedAt: $0.earnedAt)
            },
            games: games.filter { $0.endTimestamp != nil }.map { game in
                .init(date: game.startTimestamp, format: game.gameFormat.displayName,
                      teamAScore: game.teamAScore, teamBScore: game.teamBScore,
                      players: game.players.map { .init(name: $0.name, team: $0.teamAssignment.displayName) })
            },
            playoffRuns: runs.map {
                .init(spot: $0.spot.rawValue, startedAt: $0.createdAt, status: $0.status.rawValue,
                      round: $0.round, wins: $0.wins, losses: $0.losses, gamesPlayed: $0.gamesPlayed)
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)

        let fileName = "hooptrack-export-\(dateStamp()).json"
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)

        // Phase 7 — Security: apply complete file protection so the exported JSON
        // cannot be read from the temp directory without the device being unlocked.
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )

        return url
    }

    // MARK: - Private Helpers

    private func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: .now)
    }
}
