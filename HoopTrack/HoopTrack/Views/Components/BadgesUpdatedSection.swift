// BadgesUpdatedSection.swift
// Inline list of badge rank changes shown at the bottom of session summary views.
// Renders nothing when changes is empty — callers pass changes unconditionally.
import SwiftUI

struct BadgesUpdatedSection: View {
    let changes: [BadgeTierChange]

    var body: some View {
        if changes.isEmpty { EmptyView() } else { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Badges Updated")
                .font(.headline)

            ForEach(changes, id: \.badgeID) { change in
                BadgeTierChangeRow(change: change)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
