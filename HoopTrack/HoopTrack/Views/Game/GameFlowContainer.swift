// GameFlowContainer.swift
// Hosts the full SP1 Game Mode user flow — consent → registration →
// team assignment → live game → summary. Kept here (rather than in
// TrainTabView) so TrainTabView stays flat and the game flow's internal
// state doesn't leak out.

import SwiftUI
import SwiftData

struct GameFlowContainer: View {

    let format: GameFormat
    let gameType: GameType
    let onDismiss: () -> Void

    @EnvironmentObject private var dataService: DataService
    @Environment(\.modelContext) private var modelContext

    // Step within the game flow.
    private enum Step: Hashable {
        case consent
        case registration
        case teamAssignment
        case live
        case summary
    }

    @State private var step: Step = .consent
    @StateObject private var regVM: GameRegistrationViewModel
    @State private var gameSession: GameSession?
    @State private var gameVM: GameSessionViewModel?

    init(format: GameFormat, gameType: GameType, onDismiss: @escaping () -> Void) {
        self.format = format
        self.gameType = gameType
        self.onDismiss = onDismiss
        _regVM = StateObject(wrappedValue: GameRegistrationViewModel(format: format))
    }

    var body: some View {
        Group {
            switch step {
            case .consent:
                GameConsentView(
                    format: format,
                    gameType: gameType,
                    onContinue: { step = .registration },
                    onCancel: onDismiss
                )
            case .registration:
                GameRegistrationView(
                    viewModel: regVM,
                    onComplete: { _ in step = .teamAssignment },
                    onCancel: {
                        regVM.restart()
                        onDismiss()
                    }
                )
            case .teamAssignment:
                TeamAssignmentView(
                    players: regVM.pendingPlayers,
                    onConfirm: { assignments in
                        startGame(assignments: assignments)
                    },
                    onBack: {
                        regVM.restart()
                        step = .registration
                    }
                )
            case .live:
                if let gameVM {
                    LiveGameView(viewModel: gameVM) {
                        step = .summary
                    }
                }
            case .summary:
                if let gameSession {
                    GameSummaryView(session: gameSession) {
                        onDismiss()
                    }
                }
            }
        }
    }

    private func startGame(assignments: [UUID: TeamAssignment]) {
        let session = GameSession(gameType: gameType, gameFormat: format)
        session.gameState = .inProgress

        for pending in regVM.pendingPlayers {
            let team = assignments[pending.id] ?? .teamA
            let player = GamePlayer(
                name: pending.name,
                appearanceEmbedding: pending.descriptorBlob,
                teamAssignment: team
            )
            session.players.append(player)
        }

        modelContext.insert(session)
        try? modelContext.save()

        self.gameSession = session
        self.gameVM = GameSessionViewModel(session: session, dataService: dataService)
        self.step = .live
    }
}
