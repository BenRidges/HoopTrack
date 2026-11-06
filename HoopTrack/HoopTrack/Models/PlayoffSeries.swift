// PlayoffSeries.swift
// SwiftData model: one playoff run. The run's progress is replayed from
// the shots of its sessions (TrainingSession.playoffSeriesID) by
// PlayoffRun. The numbers here are a cache for lists, refreshed by
// DataService.refreshPlayoff(_:) after every session.

import Foundation
import SwiftData

@Model
final class PlayoffSeries {

    var id: UUID
    var createdAt: Date
    var spot: PlayoffSpot
    /// Set when the player ends the run early.
    var retiredAt: Date?
    /// Set the first time the run reaches champion.
    var wonAt: Date?

    // MARK: - Cached from the replay
    var round: Int
    var wins: Int
    var losses: Int
    var status: PlayoffStatus
    var gamesPlayed: Int
    var updatedAt: Date

    init(spot: PlayoffSpot) {
        self.id          = UUID()
        self.createdAt   = .now
        self.spot        = spot
        self.retiredAt   = nil
        self.wonAt       = nil
        self.round       = 1
        self.wins        = 0
        self.losses      = 0
        self.status      = .playing
        self.gamesPlayed = 0
        self.updatedAt   = .now
    }

    var isActive: Bool { status == .playing || status == .comeback }

    /// One line for lists: "Second round · 2–1", "Champion", …
    var standing: String {
        switch status {
        case .playing:  return "\(PlayoffRun.roundName(round)) · \(wins)–\(losses)"
        case .comeback: return "\(PlayoffRun.roundName(round)) · comeback"
        case .champion: return "Champion"
        case .retired:  return "Ended in the \(PlayoffRun.roundName(round).lowercased())"
        }
    }
}
