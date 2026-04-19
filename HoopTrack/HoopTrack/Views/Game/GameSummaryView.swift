// GameSummaryView.swift
// SP1: just final team scores + player list + duration. SP2 replaces
// this with the full box score.

import SwiftUI

struct GameSummaryView: View {
    let session: GameSession
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    HStack {
                        teamBlock(name: "Team A", score: session.teamAScore, colour: .orange)
                        Text("vs").font(.title2).foregroundStyle(.secondary)
                        teamBlock(name: "Team B", score: session.teamBScore, colour: .blue)
                    }

                    Label(
                        "\(Int(session.durationSeconds)) sec",
                        systemImage: "clock"
                    )
                    .font(.subheadline).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Players").font(.headline)
                        ForEach(session.players) { p in
                            HStack {
                                Text(p.name)
                                Spacer()
                                Text(p.teamAssignment.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("Game summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).bold().tint(.orange)
                }
            }
        }
    }

    private func teamBlock(name: String, score: Int, colour: Color) -> some View {
        VStack {
            Text(name).font(.caption).foregroundStyle(colour)
            Text("\(score)").font(.system(size: 48, weight: .black, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(colour.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }
}
