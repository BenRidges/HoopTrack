// BadgesUpdatedSection.swift
// Inline list of badge rank changes shown at the bottom of session summary views.
// Renders nothing when changes is empty — callers pass changes unconditionally.
import SwiftUI
import UIKit   // for UINotificationFeedbackGenerator

struct BadgesUpdatedSection: View {
    let changes: [BadgeTierChange]

    var body: some View {
        if changes.isEmpty { EmptyView() } else { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Badges Updated")
                .font(.headline)

            ForEach(Array(changes.enumerated()), id: \.element.badgeID) { index, change in
                BadgeTierChangeRow(change: change)
                    .transition(
                        .scale(scale: 0.8)
                        .combined(with: .opacity)
                    )
                    .animation(
                        .spring(response: 0.4, dampingFraction: 0.6)
                        .delay(Double(index) * 0.08),   // stagger rows
                        value: changes.count
                    )
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            // Fire a single success haptic when badge changes appear
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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
