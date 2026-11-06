// GameSummaryView.swift
// Final score and box score for a pickup game.

import SwiftUI

struct GameSummaryView: View {
    let game: GameSession

    private var lines: [BoxScore.Line] { GameStats.lines(for: game) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(game.gameFormat.displayName) pickup")
                        .font(.title2.bold())
                    Text("\(game.startTimestamp.formatted(date: .abbreviated, time: .shortened)) · \(game.durationSeconds.clockText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    finalScore("TEAM A", game.teamAScore, won: game.teamAScore > game.teamBScore)
                    finalScore("TEAM B", game.teamBScore, won: game.teamBScore > game.teamAScore)
                }
                ForEach(TeamAssignment.allCases) { team in
                    teamTable(team)
                }
            }
            .padding(Metrics.screenPadding)
        }
        .courtBackground()
        .navigationTitle("Box score")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func finalScore(_ title: String, _ score: Int, won: Bool) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.label).tracking(1.2).foregroundStyle(.secondary)
            Text("\(score)")
                .font(.score(72))
                .foregroundStyle(won ? Color.leather : .primary)
            Text(won ? "Winner" : " ")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.leather)
        }
        .frame(maxWidth: .infinity)
    }

    private func teamTable(_ team: TeamAssignment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(team.displayName)
            VStack(spacing: 0) {
                row(name: "", pts: "PTS", fg: "FG", three: "3PT", header: true)
                ForEach(lines.filter { $0.team == team }) { line in
                    Hairline(inset: Metrics.cardPadding)
                    row(name: line.name, pts: "\(line.points)",
                        fg: "\(line.made)/\(line.attempts)",
                        three: "\(line.threesMade)/\(line.threeAttempts)", header: false)
                }
            }
            .background(Color.panel, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
    }

    private func row(name: String, pts: String, fg: String, three: String, header: Bool) -> some View {
        HStack {
            Text(name).font(.body.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
            Text(pts).frame(width: 44, alignment: .trailing)
            Text(fg).frame(width: 52, alignment: .trailing)
            Text(three).frame(width: 52, alignment: .trailing)
        }
        .font(header ? .caption.weight(.semibold) : .body.monospacedDigit())
        .foregroundStyle(header ? Color.secondary : Color.primary)
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, header ? 10 : 12)
    }
}
