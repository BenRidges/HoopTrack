// GamePlayer.swift
// A player in a specific GameSession. Ephemeral — cascade-deleted with the
// parent GameSession. `appearanceEmbedding` is left over from the removed
// camera-registration flow; it stays in the schema (empty) so existing
// stores open without a migration.

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
        appearanceEmbedding: Data = Data(),
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
}
