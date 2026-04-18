// BadgeBrowserView.swift
// Navigation destination pushed from ProfileTabView.
// Includes BadgeDetailSheet as a nested type.
import SwiftUI

struct BadgeBrowserView: View {
    @ObservedObject var viewModel: BadgeBrowserViewModel

    @State private var selectedBadgeID: BadgeID?

    var body: some View {
        List {
            ForEach(SkillDimension.allCases) { dimension in
                Section {
                    ForEach(viewModel.rows(for: dimension)) { item in
                        BadgeRowView(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedBadgeID = item.id }
                    }
                } header: {
                    Label(dimension.rawValue, systemImage: dimension.systemImage)
                }
            }
        }
        .navigationTitle("Badges  ·  \(viewModel.earnedCount) / 25")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedBadgeID) { badgeID in
            BadgeDetailSheet(badgeID: badgeID, viewModel: viewModel)
                .presentationDetents([.medium])
        }
    }
}

// MARK: - BadgeRowView

private struct BadgeRowView: View {
    let item: BadgeBrowserViewModel.BadgeRowItem

    // Phase 11 — VoiceOver label for the row.
    private var rowAccessibilityLabel: String {
        if let rank = item.rank {
            return "\(item.id.displayName) badge. Earned. Rank: \(rank.displayName)."
        } else {
            return "\(item.id.displayName) badge. Locked."
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.id.displayName)
                    .font(.subheadline)
                    .foregroundStyle(item.rank == nil ? .secondary : .primary)
            }
            Spacer()
            if let rank = item.rank {
                BadgeRankPill(rank: rank)
            } else {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        // Phase 11 — single VoiceOver element for the row.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityHint("Double-tap to see details")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - BadgeDetailSheet

private struct BadgeDetailSheet: View {
    let badgeID: BadgeID
    @ObservedObject var viewModel: BadgeBrowserViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Badge icon + name
                    VStack(spacing: 8) {
                        Image(systemName: badgeID.skillDimension.systemImage)
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                        Text(badgeID.displayName)
                            .font(.title2.bold())
                    }
                    .padding(.top, 8)

                    badgeBody
                }
                .padding()
            }
            .navigationTitle(badgeID.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private var badgeBody: some View {
        // Find the earned badge entry from the profile
        let earnedRow = viewModel.rows(for: badgeID.skillDimension).first { $0.id == badgeID }
        if let rank = earnedRow?.rank {
            // Earned — show rank, progress bar, MMR
            VStack(spacing: 16) {
                BadgeRankPill(rank: rank)
                    .scaleEffect(1.4)
                    // Phase 11 — rank name already in sheet title; hide from VoiceOver.
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    let bandProgress = (rank.mmr.truncatingRemainder(dividingBy: 100)) / 100
                    ProgressView(value: bandProgress)
                        .tint(rank.tier.color)
                        // Phase 11 — describe progress bar to VoiceOver.
                        .accessibilityLabel("Progress to next rank")
                        .accessibilityValue(String(format: "%.0f percent", bandProgress * 100))

                    HStack {
                        Text("MMR: \(Int(rank.mmr))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let nextName = nextRankName(current: rank) {
                            Text("Next: \(nextName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else {
            // Not yet earned
            VStack(spacing: 12) {
                Text("Not Yet Earned")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(badgeID.scoringDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func nextRankName(current: BadgeRank) -> String? {
        let nextMMR = (floor(current.mmr / 100) * 100) + 100
        guard nextMMR < 1800 else { return nil }
        return BadgeRank(mmr: nextMMR).displayName
    }
}

// MARK: - BadgeID: Identifiable
extension BadgeID: Identifiable {
    public var id: String { rawValue }
}
