// ShimmerModifier.swift
// Animated diagonal gradient shimmer for skeleton loading states.
// Usage: someView.shimmer(isActive: isLoading)
// Compose with .redacted(reason: .placeholder) to show placeholder shapes.

import SwiftUI

struct ShimmerModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content
                .redacted(reason: .placeholder)
                .overlay(ShimmerOverlay())
                .allowsHitTesting(false)
        } else {
            content
        }
    }
}

// MARK: - Shimmer Overlay

private struct ShimmerOverlay: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.5) / 1.5  // 0→1 over 1.5s
            shimmerGradient(phase: phase)
                .blendMode(.screen)
        }
        .allowsHitTesting(false)
    }

    private func shimmerGradient(phase: Double) -> some View {
        let offset = phase * 3.0 - 1.0   // sweeps from -1 → 2 (fully off-screen both sides)
        return LinearGradient(
            gradient: Gradient(colors: [
                .clear,
                .white.opacity(0.45),
                .clear
            ]),
            startPoint: UnitPoint(x: offset - 0.5, y: 0.0),
            endPoint:   UnitPoint(x: offset + 0.5, y: 1.0)
        )
    }
}

// MARK: - View Extension

extension View {
    /// Applies a shimmer loading animation when `isActive` is true.
    /// Automatically applies `.redacted(reason: .placeholder)` so the view's
    /// shape is preserved — no need to set it separately at the call site.
    func shimmer(isActive: Bool) -> some View {
        modifier(ShimmerModifier(isActive: isActive))
    }
}
