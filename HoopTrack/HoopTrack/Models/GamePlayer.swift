// GamePlayer.swift
// A player registered to a specific GameSession. Ephemeral — cascade-deleted
// with the parent GameSession. `appearanceEmbedding` carries a JSON-encoded
// AppearanceDescriptor.

import Foundation
import SwiftData

@Model
final class GamePlayer {
    @Attribute(.unique) var id: UUID
    var name: String
    var appearanceEmbedding: Data
    var teamAssignmentRaw: String
    var gameSession: GameSession?
    var linkedProfile: PlayerProfile?
    var registeredAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        appearanceEmbedding: Data,
        teamAssignment: TeamAssignment,
        linkedProfile: PlayerProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.appearanceEmbedding = appearanceEmbedding
        self.teamAssignmentRaw = teamAssignment.rawValue
        self.gameSession = nil
        self.linkedProfile = linkedProfile
        self.registeredAt = .now
    }

    /// Typed view on the raw-string-backed team assignment. Keeps call sites clean.
    var teamAssignment: TeamAssignment {
        get { TeamAssignment(rawValue: teamAssignmentRaw) ?? .teamA }
        set { teamAssignmentRaw = newValue.rawValue }
    }

    /// Decoded descriptor. Returns nil if the blob is malformed — caller
    /// must guard (SP2 attribution will).
    var appearanceDescriptor: AppearanceDescriptor? {
        try? JSONDecoder().decode(AppearanceDescriptor.self, from: appearanceEmbedding)
    }
}
