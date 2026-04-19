// RecentGamesSection.swift
// Lightweight section at the bottom of ProgressTabView showing the
// player's recent GameSessions. Hidden entirely when there are none
// so it doesn't clutter the analytics dashboard.

import SwiftUI
import SwiftData

struct RecentGamesSection: View {

    @Query(sort: \GameSession.startTimestamp, order: .reverse)
    private var games: [GameSession]

    var body: some View {
        if games.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Games")
                    .font(.headline)

                ForEach(games.prefix(5)) { game in
                    gameRow(game)
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func gameRow(_ game: GameSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(game.gameType.rawValue) · \(game.gameFormat.displayName)")
                    .font(.subheadline.bold())
                Text("\(game.teamAScore) – \(game.teamBScore) · \(game.players.count) players")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(game.startTimestamp, style: .date)
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}
