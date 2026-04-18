// BadgesUpdatedSection.swift
// Inline list of badge rank changes shown at the bottom of session summary views.
// Renders nothing when changes is empty — callers pass changes unconditionally.
import SwiftUI
import UIKit   // for UINotificationFeedbackGenerator

struct BadgesUpdatedSection: View {
    let changes: [BadgeTierChange]
    var skipReason: String? = nil
    private let haptic = UINotificationFeedbackGenerator()
    @State private var appeared = false

    var body: some View {
        if let reason = skipReason, changes.isEmpty {
            skipReasonContent(reason)
        } else if changes.isEmpty {
            EmptyView()
        } else {
            content
        }
    }

    private func skipReasonContent(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Badges Not Updated", systemImage: "shield.slash")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Badges Updated")
                .font(.headline)

            ForEach(Array(changes.enumerated()), id: \.element.badgeID) { index, change in
                BadgeTierChangeRow(change: change)
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.8, anchor: .leading)
                    .animation(
                        .spring(response: 0.4, dampingFraction: 0.6)
                        .delay(Double(index) * 0.08),
                        value: appeared
                    )
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            haptic.prepare()
            haptic.notificationOccurred(.success)
            appeared = true
        }
    }
}

private struct BadgeTierChangeRow: View {
    let change: BadgeTierChange

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: change.badgeID.skillDimension.systemImage)
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)

            Text(change.badgeID.displayName)
                .font(.subheadline)

            Spacer()

            rankChangeLabel
        }
    }

    @ViewBuilder private var rankChangeLabel: some View {
        if let previous = change.previousRank {
            if previous.tier != change.newRank.tier {
                // Tier promotion
                HStack(spacing: 4) {
                    BadgeRankPill(rank: previous)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    BadgeRankPill(rank: change.newRank)
                }
                .foregroundStyle(.green)
            } else {
                // Division promotion within same tier
                HStack(spacing: 4) {
                    BadgeRankPill(rank: previous)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    BadgeRankPill(rank: change.newRank)
                }
                .foregroundStyle(.blue)
            }
        } else {
            // First earn
            HStack(spacing: 4) {
                Text("Earned ·")
                    .font(.caption)
                    .foregroundStyle(.orange)
                BadgeRankPill(rank: change.newRank)
            }
        }
    }
}
