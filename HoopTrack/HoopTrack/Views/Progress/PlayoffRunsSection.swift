// PlayoffRunsSection.swift
// Playoff runs on the Progress tab, and each run's bracket: every series
// it played, round by round, game by game. Hidden until the first run.

import SwiftUI
import SwiftData

struct PlayoffRunsSection: View {

    @Query(sort: \PlayoffSeries.createdAt, order: .reverse)
    private var runs: [PlayoffSeries]

    var body: some View {
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Playoff runs")
                VStack(spacing: 0) {
                    ForEach(Array(runs.prefix(5).enumerated()), id: \.element.id) { index, run in
                        if index > 0 { Hairline(inset: Metrics.cardPadding) }
                        NavigationLink {
                            PlayoffRunView(series: run)
                        } label: {
                            row(run)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .background(Color.panel, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            }
        }
    }

    private func row(_ run: PlayoffSeries) -> some View {
        HStack(spacing: 14) {
            Image(systemName: run.status == .champion ? "trophy.fill" : run.spot.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(run.status == .champion ? Color.leather : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.spot.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(run.standing) · \(run.createdAt.relativeDayLabel)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            RoundLadder(current: run.round, status: run.status)
                .frame(width: 64)
        }
        .padding(Metrics.cardPadding)
        .contentShape(Rectangle())
    }
}

/// One run, round by round.
struct PlayoffRunView: View {
    let series: PlayoffSeries

    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject private var appState: AppState
    @State private var run: PlayoffRun?
    @State private var confirmingEnd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(series.standing)
                        .font(.title2.bold())
                    Text("Started \(series.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(run?.games.count ?? 0) games")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let run {
                    VStack(spacing: 12) {
                        ForEach(1...PlayoffRun.roundCount, id: \.self) { round in
                            roundPanel(round, run: run)
                        }
                    }
                }

                if series.isActive {
                    VStack(spacing: 12) {
                        Button {
                            appState.selectedTab = .train
                            appState.activeLaunch = .playoff(series.id)
                        } label: {
                            Label("Continue", systemImage: "play.fill")
                        }
                        .buttonStyle(.primary)
                        Button("End this run", role: .destructive) { confirmingEnd = true }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.miss)
                    }
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.bottom, 32)
        }
        .courtBackground()
        .navigationTitle("\(series.spot.displayName) playoffs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { run = dataService.playoffRun(for: series) }
        .onChange(of: dataService.revision) { _, _ in run = dataService.playoffRun(for: series) }
        .confirmationDialog("End this playoff run?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End run", role: .destructive) { dataService.retirePlayoff(series) }
        } message: {
            Text("Your shots stay in your history.")
        }
    }

    private func roundPanel(_ round: Int, run: PlayoffRun) -> some View {
        let attempts = Self.series(in: run.games, round: round)
        let target = series.spot.makesToWin[round - 1]
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(PlayoffRun.roundName(round))
                        .font(.headline)
                    Spacer()
                    Text("\(target) of 10 to win")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if attempts.isEmpty {
                    Text("Not reached yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                ForEach(Array(attempts.enumerated()), id: \.offset) { _, games in
                    HStack(spacing: 6) {
                        ForEach(Array(games.enumerated()), id: \.offset) { _, game in
                            Text(game.won ? "W" : "L")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(game.won ? Color.onLeather : .white)
                                .frame(width: 26, height: 26)
                                .background(game.won ? Color.make : Color.miss.opacity(0.75),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .accessibilityLabel("Game \(game.number), \(game.won ? "won" : "lost") \(game.makes) for \(game.makes + game.misses)")
                        }
                        Spacer(minLength: 8)
                        Text(Self.outcome(of: games))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .opacity(attempts.isEmpty && round > run.round ? 0.5 : 1)
    }

    /// Splits a round's games into series: a new one starts at game 1.
    static func series(in games: [PlayoffGame], round: Int) -> [[PlayoffGame]] {
        var out: [[PlayoffGame]] = []
        for game in games where game.round == round {
            if game.number == 1 || out.isEmpty { out.append([]) }
            out[out.count - 1].append(game)
        }
        return out
    }

    static func outcome(of games: [PlayoffGame]) -> String {
        guard let last = games.last else { return "" }
        if last.seriesWins == PlayoffRun.winsToTakeSeries { return "Won \(last.seriesWins)–\(last.seriesLosses)" }
        if last.seriesLosses == PlayoffRun.winsToTakeSeries { return "Lost \(last.seriesWins)–\(last.seriesLosses)" }
        return "\(last.seriesWins)–\(last.seriesLosses)"
    }
}
