// GameShotRecord.swift
// One shot attempt within a GameSession. Sibling to ShotRecord (used in solo
// TrainingSession) — intentionally separate because player attribution and
// shot-value classification differ. attributionConfidence is 1.0 in SP1
// (manual logging) and gets lowered once SP2's PlayerTracker attributes
// shots automatically.

import Foundation
import SwiftData

@Model
final class GameShotRecord {
    @Attribute(.unique) var id: UUID

    /// Nullable — unattributed shots (SP2 fallback) are kept here with
    /// shooter = nil until the user resolves them in the box score.
    var shooter: GamePlayer?

    var resultRaw: String            // ShotResult.rawValue
    var courtX: Double               // 0..1 normalised half-court
    var courtY: Double
    var timestamp: Date
    var shotTypeRaw: String          // GameShotType.rawValue ("2PT" / "3PT")
    var attributionConfidence: Double
    var gameSession: GameSession?

    init(
        id: UUID = UUID(),
        shooter: GamePlayer?,
        result: ShotResult,
        courtX: Double,
        courtY: Double,
        timestamp: Date = .now,
        shotType: GameShotType,
        attributionConfidence: Double = 1.0
    ) {
        self.id = id
        self.shooter = shooter
        self.resultRaw = result.rawValue
        self.courtX = courtX
        self.courtY = courtY
        self.timestamp = timestamp
        self.shotTypeRaw = shotType.rawValue
        self.attributionConfidence = attributionConfidence
    }

    var result: ShotResult {
        get { ShotResult(rawValue: resultRaw) ?? .miss }
        set { resultRaw = newValue.rawValue }
    }

    var shotType: GameShotType {
        get { GameShotType(rawValue: shotTypeRaw) ?? .twoPoint }
        set { shotTypeRaw = newValue.rawValue }
    }
}
