// RecentGamesSection.swift
// Last few pickup games on the Progress tab. Hidden when there are none.

import SwiftUI
import SwiftData

struct RecentGamesSection: View {

    @Query(filter: #Predicate<GameSession> { $0.endTimestamp != nil },
           sort: \GameSession.startTimestamp, order: .reverse)
    private var games: [GameSession]

    var body: some View {
        if !games.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Pickup games")
                VStack(spacing: 0) {
                    ForEach(Array(games.prefix(5).enumerated()), id: \.element.id) { index, game in
                        if index > 0 { Hairline(inset: Metrics.cardPadding) }
                        NavigationLink {
                            GameSummaryView(game: game)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(game.gameFormat.displayName) pickup")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(game.startTimestamp.relativeDayLabel)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(game.teamAScore)–\(game.teamBScore)")
                                    .font(.score(26))
                                    .foregroundStyle(.primary)
                            }
                            .padding(Metrics.cardPadding)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .background(Color.panel, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            }
        }
    }
}
