// AnimatedCounterModifier.swift
// AnimatableModifier that drives a formatted number from 0 → target on appear.
//
// Usage:
//   @State private var animatedFG: Double = 0
//
//   EmptyView()
//       .modifier(AnimatedCounterModifier(currentValue: animatedFG, format: "%.0f%%"))
//       .font(.system(size: 72, weight: .black, design: .rounded))
//       .foregroundStyle(.orange)
//       .animation(.easeOut(duration: 0.6), value: animatedFG)
//       .onAppear { animatedFG = session.fgPercent }
//
// Note: EmptyView() is used as the content placeholder — AnimatedCounterModifier
// replaces it entirely with a Text view showing the interpolated value.

import SwiftUI

struct AnimatedCounterModifier: AnimatableModifier {

    // MARK: - Animatable State

    /// The currently-displayed (interpolated) value. SwiftUI animates this
    /// from the old value to the new value each time it changes.
    var currentValue: Double

    var animatableData: Double {
        get { currentValue }
        set { currentValue = newValue }
    }

    // MARK: - Configuration

    /// Printf-style format string, e.g. "%.0f%%", "%d", "%.2fs"
    let format: String

    // MARK: - Body

    func body(content: Content) -> some View {
        Text(String(format: format, currentValue))
    }
}
