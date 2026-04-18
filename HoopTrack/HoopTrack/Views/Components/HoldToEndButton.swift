// HoldToEndButton.swift
// Reusable hold-to-confirm button with visual progress feedback.

import SwiftUI

struct HoldToEndButton: View {
    let onConfirm: () async -> Void

    @EnvironmentObject private var hapticService: HapticService

    @State private var isHolding = false
    @State private var progress: Double = 0
    @State private var task: Task<Void, Never>?

    var body: some View {
        Text(isHolding ? "HOLD..." : "END SESSION")
            .font(.system(size: 9, weight: .heavy))
            .tracking(1.5)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .accessibilityLabel("End session")
            .accessibilityHint("Hold to confirm ending the current training session")
            .accessibilityAddTraits(.isButton)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(colors: [Color(red: 0.83, green: 0.13, blue: 0.13),
                                                    Color(red: 1.0, green: 0.23, blue: 0.19)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.2))
                            .frame(width: max(0, progress) * geo.size.width)
                            .animation(.linear(duration: 0.05), value: progress)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .red.opacity(0.25), radius: 8, y: 2)
            )
            .foregroundStyle(.white)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding else { return }
                        isHolding = true
                        progress = 0
                        withAnimation(.linear(duration: 1.5)) {
                            progress = 1
                        }
                        task = Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            guard !Task.isCancelled else { return }
                            hapticService.longPress()
                            await onConfirm()
                        }
                    }
                    .onEnded { _ in
                        task?.cancel()
                        task = nil
                        isHolding = false
                        withAnimation(.easeOut(duration: 0.2)) {
                            progress = 0
                        }
                    }
            )
    }
}

#Preview {
    HoldToEndButton {
        print("Confirmed!")
    }
    .environmentObject(HapticService())
}
