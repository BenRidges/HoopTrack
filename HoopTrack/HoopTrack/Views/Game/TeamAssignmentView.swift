// TeamAssignmentView.swift
// Tap-to-toggle team chips for the pending roster. Drag-and-drop was
// considered but tap is simpler, matches the rest of the app, and works
// with VoiceOver for free.

import SwiftUI

struct TeamAssignmentView: View {
    let players: [GameRegistrationViewModel.PendingPlayer]
    let onConfirm: (_ assignments: [UUID: TeamAssignment]) -> Void
    let onBack: () -> Void

    @State private var assignments: [UUID: TeamAssignment] = [:]

    var body: some View {
        VStack(spacing: 20) {
            Text("Assign teams")
                .font(.title2.bold())

            HStack(spacing: 12) {
                teamColumn(.teamA, "Team A", .orange)
                teamColumn(.teamB, "Team B", .blue)
            }

            Button {
                onConfirm(assignments)
            } label: {
                Text(readyToConfirm ? "Start game" : "Assign all \(players.count) players")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(readyToConfirm ? Color.orange : Color.secondary.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .disabled(!readyToConfirm)
            .padding(.horizontal)

            Button("Back", action: onBack)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            for (i, p) in players.enumerated() {
                assignments[p.id] = (i % 2 == 0) ? .teamA : .teamB
            }
        }
    }

    private var readyToConfirm: Bool {
        assignments.count == players.count
    }

    @ViewBuilder
    private func teamColumn(_ team: TeamAssignment, _ name: String, _ colour: Color) -> some View {
        VStack(spacing: 8) {
            Text(name).font(.headline).foregroundStyle(colour)
            ForEach(players) { p in
                let assigned = assignments[p.id]
                if assigned == team {
                    Button {
                        let other: TeamAssignment = (team == .teamA) ? .teamB : .teamA
                        assignments[p.id] = other
                    } label: {
                        Text(p.name)
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(colour.opacity(0.2), in: Capsule())
                    }
                }
            }
            if players.filter({ assignments[$0.id] == team }).isEmpty {
                Text("No players yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding()
        .background(colour.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}
