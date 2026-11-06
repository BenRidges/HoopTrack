// PlayoffViews.swift
// Playoffs outside the live session: the Train tab's card for a run in
// progress and the sheet that starts one.

import SwiftUI

/// The run in progress, on the Train tab. One button: carry on.
struct PlayoffCard: View {
    let series: PlayoffSeries
    let run: PlayoffRun
    let onContinue: () -> Void
    let onEnd: () -> Void

    @State private var confirmingEnd = false

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("PLAYOFFS · \(series.spot.displayName.uppercased())")
                        .font(.label)
                        .foregroundStyle(Color.leather)
                    Spacer()
                    Menu {
                        Button("End this run", role: .destructive) { confirmingEnd = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 24)
                    }
                    .accessibilityLabel("More")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(run.roundName)
                        .font(.title2.bold())
                    Text(standing)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                RoundLadder(current: run.round, status: run.status)

                Button(action: onContinue) {
                    Label(run.status == .comeback ? "Continue the comeback" : "Play game \(run.gameNumber)",
                          systemImage: "play.fill")
                }
                .buttonStyle(.primary)
            }
        }
        .confirmationDialog("End this playoff run?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End run", role: .destructive, action: onEnd)
        } message: {
            Text("Your shots stay in your history.")
        }
    }

    private var standing: String {
        switch run.status {
        case .comeback:
            return "Knocked out. \(run.comebackMakes) of \(run.comebackTarget) makes to earn the round back."
        default:
            let lead = run.wins == run.losses ? "Series tied \(run.wins)–\(run.losses)"
                : run.wins > run.losses ? "You lead \(run.wins)–\(run.losses)"
                : "You trail \(run.wins)–\(run.losses)"
            return "\(lead) · \(run.makesToWin) makes wins a game"
        }
    }
}

/// Four segments, one per round: done, current, to come.
struct RoundLadder: View {
    let current: Int
    let status: PlayoffStatus

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...PlayoffRun.roundCount, id: \.self) { round in
                Capsule()
                    .fill(fill(for: round))
                    .frame(height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status == .champion ? "All four rounds won" : "Round \(current) of \(PlayoffRun.roundCount)")
    }

    private func fill(for round: Int) -> Color {
        if status == .champion || round < current { return .leather }
        if round == current { return status == .comeback ? .miss.opacity(0.7) : .leather.opacity(0.45) }
        return .white.opacity(0.1)
    }
}

/// Choose a spot, start a run.
struct PlayoffSetupSheet: View {
    let onStart: (PlayoffSpot) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var spot: PlayoffSpot = .threes

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Four rounds, best of seven.")
                            .font(.title2.bold())
                        Text("Each game is ten shots: hit the target before your misses run out. First to four wins takes the series, and the target goes up every round. Knocked out? Earn your way back with a comeback drill.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Shoot from")
                        VStack(spacing: 0) {
                            ForEach(Array(PlayoffSpot.allCases.enumerated()), id: \.element) { index, option in
                                if index > 0 { Hairline(inset: 64) }
                                spotRow(option)
                            }
                        }
                        .background(Color.panel, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                    }

                    Button {
                        onStart(spot)
                        dismiss()
                    } label: {
                        Label("Start the run", systemImage: "trophy.fill")
                    }
                    .buttonStyle(.primary)
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.vertical, 12)
            }
            .courtBackground()
            .navigationTitle("Playoffs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func spotRow(_ option: PlayoffSpot) -> some View {
        Button {
            spot = option
        } label: {
            HStack(spacing: 14) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.leather)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(option.detail) Makes to win: \(option.makesToWin.map(String.init).joined(separator: " · ")).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: spot == option ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(spot == option ? Color.leather : Color.white.opacity(0.25))
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(spot == option ? .isSelected : [])
    }
}
