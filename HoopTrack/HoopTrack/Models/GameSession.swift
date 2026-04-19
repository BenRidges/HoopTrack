// GameSession.swift
// One multi-player game (pickup or BO7 playoff). Sibling to TrainingSession,
// not a subclass — team structure + per-player shots warrant separation.
// Videos follow the same local-retention rules as TrainingSession (see
// DataService.purgeOldVideos).

import Foundation
import SwiftData

@Model
final class GameSession {
    @Attribute(.unique) var id: UUID
    var gameTypeRaw: String       // GameType.rawValue
    var gameFormatRaw: Int        // GameFormat.rawValue
    @Relationship(deleteRule: .cascade, inverse: \GamePlayer.gameSession)
    var players: [GamePlayer]
    var teamAScore: Int
    var teamBScore: Int
    var startTimestamp: Date
    var endTimestamp: Date?
    var gameStateRaw: String      // GameState.rawValue
    @Relationship(deleteRule: .cascade, inverse: \GameShotRecord.gameSession)
    var shots: [GameShotRecord]
    var targetScore: Int?
    var videoFileName: String?
    var videoPinnedByUser: Bool

    init(
        id: UUID = UUID(),
        gameType: GameType,
        gameFormat: GameFormat,
        targetScore: Int? = nil
    ) {
        self.id = id
        self.gameTypeRaw = gameType.rawValue
        self.gameFormatRaw = gameFormat.rawValue
        self.players = []
        self.teamAScore = 0
        self.teamBScore = 0
        self.startTimestamp = .now
        self.endTimestamp = nil
        self.gameStateRaw = GameState.registering.rawValue
        self.shots = []
        self.targetScore = targetScore
        self.videoFileName = nil
        self.videoPinnedByUser = false
    }

    var gameType: GameType {
        get { GameType(rawValue: gameTypeRaw) ?? .pickup }
        set { gameTypeRaw = newValue.rawValue }
    }

    var gameFormat: GameFormat {
        get { GameFormat(rawValue: gameFormatRaw) ?? .twoOnTwo }
        set { gameFormatRaw = newValue.rawValue }
    }

    var gameState: GameState {
        get { GameState(rawValue: gameStateRaw) ?? .registering }
        set { gameStateRaw = newValue.rawValue }
    }

    /// Duration in seconds. Falls back to elapsed-since-start if still running.
    var durationSeconds: TimeInterval {
        (endTimestamp ?? .now).timeIntervalSince(startTimestamp)
    }
}
