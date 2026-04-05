// DribbleSessionSummaryView.swift
// Post-session summary for dribble drills.
// Shows total dribbles, average BPS, max BPS, hand balance, and combo count.

import SwiftUI

struct DribbleSessionSummaryView: View {

    let session: TrainingSession
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    drillHeader
                    statsGrid
                    handBalanceBar
                }
                .padding()
            }
            .navigationTitle("Drill Complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    // MARK: - Drill Header

    private var drillHeader: some View {
        VStack(spacing: 6) {
            Image(systemName: "hand.point.up.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(session.namedDrill?.rawValue ?? "Dribble Drill")
                .font(.title2.bold())
            Text(session.formattedDuration)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top)
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        StatCardGrid {
            StatCard(title: "Dribbles",
                     value: "\(session.totalDribbles ?? 0)",
                     accent: .blue)
            StatCard(title: "Avg BPS",
                     value: session.avgDribblesPerSec.map { String(format: "%.1f", $0) } ?? "—",
                     accent: bpsColor(session.avgDribblesPerSec))
            StatCard(title: "Max BPS",
                     value: session.maxDribblesPerSec.map { String(format: "%.1f", $0) } ?? "—",
                     accent: .orange)
            StatCard(title: "Combos",
                     value: "\(session.dribbleCombosDetected ?? 0)",
                     accent: .purple)
        }
    }

    // MARK: - Hand Balance Bar

    private var handBalanceBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hand Balance")
                .font(.headline)

            if let balance = session.handBalanceFraction {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geo.size.width * balance)
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: geo.size.width * (1 - balance))
                    }
                    .clipShape(Capsule())
                    .frame(height: 20)
                }
                .frame(height: 20)

                HStack {
                    Label(String(format: "Left %.0f%%", balance * 100),
                          systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Spacer()
                    Label(String(format: "Right %.0f%%", (1 - balance) * 100),
                          systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .environment(\.layoutDirection, .rightToLeft)
                }
            } else {
                Text("No hand data recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: HoopTrack.UI.cornerRadius,
                                         style: .continuous))
    }

    private func bpsColor(_ bps: Double?) -> Color {
        guard let bps else { return .gray }
        return bps >= HoopTrack.Dribble.optimalBPSMin
            && bps <= HoopTrack.Dribble.optimalBPSMax ? .green : .orange
    }
}
