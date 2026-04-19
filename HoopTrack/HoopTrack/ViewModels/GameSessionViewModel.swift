// GameSessionViewModel.swift
// SP1: shell that owns the current GameSession row and exposes manual
// make/miss helpers for LiveGameView. SP2 replaces the manual path with
// CV attribution via GameScoringCoordinator.

import Foundation
import Combine
import SwiftData

@MainActor
final class GameSessionViewModel: ObservableObject {
    @Published private(set) var session: GameSession
    private let dataService: DataService

    init(session: GameSession, dataService: DataService) {
        self.session = session
        self.dataService = dataService
    }

    /// Manual make/miss for SP1. SP2 replaces with CV-driven entries.
    func logShot(
        shooter: GamePlayer,
        result: ShotResult,
        courtX: Double,
        courtY: Double,
        shotType: GameShotType
    ) {
        try? dataService.addGameShot(
            to: session,
            shooter: shooter,
            result: result,
            courtX: courtX, courtY: courtY,
            shotType: shotType
        )
        objectWillChange.send()
    }

    func endSession() {
        session.gameState = .completed
        session.endTimestamp = .now
        try? dataService.modelContext.save()
    }
}
