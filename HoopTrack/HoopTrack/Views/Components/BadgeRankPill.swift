// BadgeRankPill.swift
// Reusable tier-coloured pill showing badge rank — used in browser and detail sheet.
import SwiftUI

struct BadgeRankPill: View {
    let rank: BadgeRank

    var body: some View {
        Text(rank.displayName)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(rank.tier.color.opacity(0.20), in: Capsule())
            .foregroundStyle(rank.tier.color)
            .overlay(Capsule().strokeBorder(rank.tier.color.opacity(0.4), lineWidth: 1))
    }
}
