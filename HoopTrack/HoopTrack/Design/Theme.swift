// Theme.swift
// HoopTrack's visual language: a gym at night. Near-black court, one
// accent (basketball leather orange), green/red reserved for makes and
// misses. Big numbers use the compressed system width so they read like
// an arena scoreboard; everything else stays plain system type.
//
// Rules of thumb:
//   • One hero number per screen.
//   • Flat panels, no borders, no blur. Separation comes from spacing.
//   • Orange means "act here" or "this is you". Never decorative.

import SwiftUI

// MARK: - Palette

extension Color {
    /// App background — the court at night.
    static let court       = Color(red: 0.055, green: 0.055, blue: 0.060)
    /// Default card / panel surface.
    static let panel       = Color(red: 0.098, green: 0.098, blue: 0.106)
    /// Raised surface: chips, secondary buttons, rows inside panels.
    static let panelRaised = Color(red: 0.145, green: 0.145, blue: 0.157)
    /// Basketball leather — the single brand accent.
    static let leather     = Color(red: 1.00, green: 0.42, blue: 0.10)
    /// Made shot.
    static let make        = Color(red: 0.24, green: 0.84, blue: 0.50)
    /// Missed shot.
    static let miss        = Color(red: 0.95, green: 0.33, blue: 0.36)
    /// Text that sits on the leather accent.
    static let onLeather   = Color(red: 0.08, green: 0.05, blue: 0.03)

    /// Colour for an FG% value: green when good, accent when okay, red when cold.
    static func shooting(_ percent: Double) -> Color {
        switch percent {
        case 50...:   return .make
        case 35..<50: return .leather
        default:      return .miss
        }
    }
}

extension ShotResult {
    var color: Color {
        switch self {
        case .make:    return .make
        case .miss:    return .miss
        case .pending: return .secondary
        }
    }
}

// MARK: - Type

extension Font {
    /// Scoreboard numerals. Compressed, heavy, fixed-width digits.
    static func score(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy).width(.compressed).monospacedDigit()
    }

    /// Small all-caps section labels ("THIS WEEK").
    static let label = Font.system(size: 12, weight: .semibold).width(.expanded)

    /// Screen and card titles.
    static let heading = Font.system(.title3, weight: .bold)
}

// MARK: - Layout

enum Metrics {
    static let screenPadding: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 22
    static let controlRadius: CGFloat = 16
    static let sectionSpacing: CGFloat = 28
}

// MARK: - Building blocks

/// Flat rounded panel used for every card in the app.
struct Panel<Content: View>: View {
    var padding: CGFloat = Metrics.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

/// Small tracked all-caps label that heads a section.
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(.label)
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A big number with a quiet caption underneath.
struct StatValue: View {
    let value: String
    let caption: String
    var size: CGFloat = 34
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.score(size))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons

/// Filled leather button for the one primary action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.onLeather)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.leather, in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet raised button for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.panelRaised, in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Press feedback for custom tappable cards and rows.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Screen chrome

extension View {
    /// Standard screen background for scrollable tab content.
    func courtBackground() -> some View {
        background(Color.court.ignoresSafeArea())
    }

    /// Styles a `List`/`Form` to sit on the court background with panel rows.
    func courtList() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.court.ignoresSafeArea())
    }
}

/// Hairline separator for rows inside panels.
struct Hairline: View {
    var inset: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}
