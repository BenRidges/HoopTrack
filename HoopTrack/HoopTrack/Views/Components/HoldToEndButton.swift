// HoldToEndButton.swift
// Press and hold to finish a session, so a stray tap mid-drill can't end it.
// Built on the system long-press gesture: the confirm fires once, and
// letting go afterwards can't cancel the save (the old drag-gesture version
// cancelled the finishing task on release).

import SwiftUI

struct HoldToEndButton: View {
    var title: String = "Hold to end"
    var holdDuration: Double = 0.8
    /// Shows "Saving…" and ignores presses while the parent finishes up.
    var isBusy: Bool = false
    let onConfirm: () -> Void

    @EnvironmentObject private var hapticService: HapticService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.black.opacity(0.55))
            GeometryReader { geo in
                Capsule()
                    .fill(Color.miss)
                    .frame(width: max(geo.size.height, geo.size.width * progress))
                    .opacity(progress > 0 ? 1 : 0)
            }
            Text(isBusy ? "Saving…" : title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .frame(width: 150, height: 48)
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: holdDuration, maximumDistance: 40) {
            guard !isBusy else { return }
            hapticService.longPress()
            onConfirm()
        } onPressingChanged: { pressing in
            guard !isBusy else { return }
            if pressing {
                withAnimation(reduceMotion ? nil : .linear(duration: holdDuration)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("End session")
        .accessibilityHint("Touch and hold to finish and save")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard !isBusy else { return }
            onConfirm()
        }
        .onChange(of: isBusy) { _, busy in
            if !busy { progress = 0 }
        }
    }
}
