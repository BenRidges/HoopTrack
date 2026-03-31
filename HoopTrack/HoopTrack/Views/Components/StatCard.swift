// StatCard.swift
// Reusable card component for displaying a labelled numeric stat.
// Used on Dashboard, Session Summary, and Progress screens.

import SwiftUI

struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String?
    let accent: Color

    init(title: String,
         value: String,
         subtitle: String? = nil,
         accent: Color = .orange) {
        self.title    = title
        self.value    = value
        self.subtitle = subtitle
        self.accent   = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Convenience for 2-column grid
struct StatCardGrid<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            content
        }
    }
}

#Preview {
    StatCardGrid {
        StatCard(title: "FG%", value: "48.3%", subtitle: "Last 30 days")
        StatCard(title: "Streak", value: "7 days", subtitle: "Personal best: 14", accent: .yellow)
        StatCard(title: "Vertical", value: "62 cm", accent: .blue)
        StatCard(title: "Sessions", value: "24", subtitle: "This month", accent: .green)
    }
    .padding()
}
