// GameRegistrationViewModel.swift
// State machine for the multi-player registration flow. UI observes
// `currentPlayerIndex`, `pendingPlayers`, and `isComplete`. The view is
// responsible for wiring up AppearanceCaptureService; the view model
// just tracks who's been confirmed.

import Foundation
import Combine

@MainActor
final class GameRegistrationViewModel: ObservableObject {

    struct PendingPlayer: Identifiable, Equatable {
        let id = UUID()
        let name: String
        /// JSON-encoded AppearanceDescriptor. Persisted into GamePlayer.appearanceEmbedding later.
        let descriptorBlob: Data
    }

    let format: GameFormat
    @Published private(set) var currentPlayerIndex: Int = 0
    @Published private(set) var pendingPlayers: [PendingPlayer] = []

    init(format: GameFormat) {
        self.format = format
    }

    var totalPlayers: Int { format.totalPlayers }

    var isComplete: Bool { pendingPlayers.count >= totalPlayers }

    var prompt: String {
        "Player \(currentPlayerIndex + 1) of \(totalPlayers) — step in front of the camera."
    }

    func confirmPlayer(name: String, descriptor: Data) {
        guard !isComplete else { return }
        pendingPlayers.append(PendingPlayer(name: name, descriptorBlob: descriptor))
        currentPlayerIndex = min(currentPlayerIndex + 1, totalPlayers)
    }

    func restart() {
        pendingPlayers.removeAll()
        currentPlayerIndex = 0
    }
}
