// GameFlowView.swift
// Pickup-game scorekeeper: set up teams → keep score → box score.
// Tap a player, then +2 / +3 / Miss. The selection sticks, so a hot hand
// is one tap per shot.

import SwiftUI
import SwiftData

struct GameFlowView: View {
    let onFinish: () -> Void

    @State private var game: GameSession?
    @State private var finished = false

    var body: some View {
        NavigationStack {
            Group {
                if let game, finished {
                    GameSummaryView(game: game)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", action: onFinish).bold()
                            }
                        }
                } else if let game {
                    ScorekeeperView(game: game) { finished = true }
                } else {
                    GameSetupView(onCancel: onFinish) { game = $0 }
                }
            }
            .courtBackground()
        }
    }
}

// MARK: - Setup

private struct GameSetupView: View {
    let onCancel: () -> Void
    let onStart: (GameSession) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var format: GameFormat = .twoOnTwo
    @State private var target: Int? = HoopTrack.Game.defaultTargetScore
    @State private var teamA: [String] = Array(repeating: "", count: 3)
    @State private var teamB: [String] = Array(repeating: "", count: 3)

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $format) {
                    ForEach(GameFormat.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Play to", selection: $target) {
                    Text("11").tag(Int?.some(11))
                    Text("15").tag(Int?.some(15))
                    Text("21").tag(Int?.some(21))
                    Text("No limit").tag(Int?.none)
                }
            }
            .listRowBackground(Color.panel)

            teamSection(title: "Team A", names: $teamA, offset: 0)
            teamSection(title: "Team B", names: $teamB, offset: format.rawValue)
        }
        .courtList()
        .navigationTitle("Pickup game")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Start game", action: start)
                .buttonStyle(.primary)
                .padding(Metrics.screenPadding)
                .background(Color.court)
        }
    }

    private func teamSection(title: String, names: Binding<[String]>, offset: Int) -> some View {
        Section(title) {
            ForEach(0..<format.rawValue, id: \.self) { i in
                TextField("Player \(offset + i + 1)", text: names[i])
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
        }
        .listRowBackground(Color.panel)
    }

    private func start() {
        let count = format.rawValue
        let namesA = BoxScore.rosterNames(Array(teamA.prefix(count)))
        // Team B placeholders continue the numbering ("Player 3", …).
        let namesB = BoxScore.rosterNames(Array(repeating: "", count: count) + Array(teamB.prefix(count)))
            .suffix(count)

        let game = GameSession(gameType: .pickup, gameFormat: format, targetScore: target)
        game.gameState = .inProgress
        modelContext.insert(game)
        let roster = namesA.map { ($0, TeamAssignment.teamA) } + namesB.map { ($0, TeamAssignment.teamB) }
        let now = Date.now
        for (index, entry) in roster.enumerated() {
            let player = GamePlayer(name: entry.0, teamAssignment: entry.1)
            // Distinct timestamps keep roster order stable when sorting.
            player.registeredAt = now.addingTimeInterval(Double(index) * 0.001)
            modelContext.insert(player)
            game.players.append(player)
        }
        try? modelContext.save()
        onStart(game)
    }
}

// MARK: - Scorekeeper

private struct ScorekeeperView: View {
    let game: GameSession
    let onEnd: () -> Void

    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject private var hapticService: HapticService
    @State private var shooterID: GamePlayer.ID?
    @State private var confirmEnd = false

    private var players: [GamePlayer] { game.players.sorted { $0.registeredAt < $1.registeredAt } }
    private var lines: [BoxScore.Line] { GameStats.lines(for: game) }
    private var winner: TeamAssignment? {
        BoxScore.winner(teamA: game.teamAScore, teamB: game.teamBScore, target: game.targetScore)
    }

    var body: some View {
        VStack(spacing: 20) {
            scoreboard
            if let winner {
                winnerBanner(winner)
            }
            HStack(alignment: .top, spacing: 12) {
                teamColumn(.teamA)
                teamColumn(.teamB)
            }
            Spacer()
            actions
        }
        .padding(Metrics.screenPadding)
        .navigationTitle(game.targetScore.map { "First to \($0)" } ?? "Pickup game")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("End") { confirmEnd = true }
            }
        }
        .confirmationDialog("End the game?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End and see box score") { end() }
        }
    }

    private var scoreboard: some View {
        HStack {
            scoreColumn("TEAM A", score: game.teamAScore, color: .leather)
            Text("–").font(.score(48)).foregroundStyle(.tertiary)
            scoreColumn("TEAM B", score: game.teamBScore, color: .primary)
        }
        .padding(.vertical, 8)
    }

    private func scoreColumn(_ title: String, score: Int, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.label).tracking(1.2).foregroundStyle(.secondary)
            Text("\(score)")
                .font(.score(88))
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .animation(.snappy, value: score)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func winnerBanner(_ team: TeamAssignment) -> some View {
        HStack {
            Text("\(team.displayName) wins")
                .font(.headline)
            Spacer()
            Button("Finish") { end() }
                .font(.headline)
                .foregroundStyle(Color.onLeather)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.leather, in: Capsule())
        }
        .padding(Metrics.cardPadding)
        .background(Color.leather.opacity(0.15), in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func teamColumn(_ team: TeamAssignment) -> some View {
        VStack(spacing: 8) {
            ForEach(players.filter { $0.teamAssignment == team }) { player in
                let selected = shooterID == player.id
                let points = lines.first { $0.id == player.id }?.points ?? 0
                Button {
                    hapticService.tap()
                    shooterID = player.id
                } label: {
                    HStack {
                        Text(player.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Text("\(points)")
                            .font(.score(22))
                    }
                    .foregroundStyle(selected ? Color.onLeather : .primary)
                    .padding(.horizontal, 14)
                    .frame(height: 54)
                    .background(selected ? Color.leather : Color.panel,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("\(player.name), \(points) points")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if shooterID == nil {
                Text("Tap who took the shot")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                actionButton("Miss", color: .panelRaised, text: .primary) { log(made: false, three: false) }
                actionButton("+2", color: .make, text: .onLeather) { log(made: true, three: false) }
                actionButton("+3", color: .leather, text: .onLeather) { log(made: true, three: true) }
            }
            .disabled(shooterID == nil)
            .opacity(shooterID == nil ? 0.4 : 1)
            Button {
                dataService.undoLastGameShot(in: game)
                hapticService.tap()
            } label: {
                Label("Undo last", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(game.shots.isEmpty)
        }
    }

    private func actionButton(_ title: String, color: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.score(30))
                .foregroundStyle(text)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(color, in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
        }
        .buttonStyle(.pressable)
    }

    private func log(made: Bool, three: Bool) {
        guard let player = players.first(where: { $0.id == shooterID }) else { return }
        try? dataService.addGameShot(to: game, shooter: player, result: made ? .make : .miss,
                                     shotType: three ? .threePoint : .twoPoint)
        made ? hapticService.makeMade() : hapticService.missMade()
    }

    private func end() {
        dataService.endGame(game)
        onEnd()
    }
}

// MARK: - Shared stats

enum GameStats {
    @MainActor static func lines(for game: GameSession) -> [BoxScore.Line] {
        let players = game.players
            .sorted { $0.registeredAt < $1.registeredAt }
            .map { BoxScore.Player(id: $0.id, name: $0.name, team: $0.teamAssignment) }
        let shots = game.shots.map {
            BoxScore.Shot(shooterID: $0.shooter?.id, made: $0.result == .make, isThree: $0.shotType == .threePoint)
        }
        return BoxScore.lines(players: players, shots: shots)
    }
}
