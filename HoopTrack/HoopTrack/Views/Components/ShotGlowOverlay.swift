// ShotGlowOverlay.swift
// Border glow + text flash overlay for make/miss shot detection.
// Radiates colour from screen edges inward with opacity gradient.

import SwiftUI

struct ShotGlowOverlay: View {

    let shotResult: ShotResult?
    /// Width of the sidebar to offset the text toward the camera area centre.
    let sidebarWidth: CGFloat

    @State private var isVisible: Bool = false

    private var glowColor: Color {
        switch shotResult {
        case .make:    return .green
        case .miss:    return .red
        case .pending, .none: return .clear
        }
    }

    private var labelText: String {
        switch shotResult {
        case .make:    return "MAKE"
        case .miss:    return "MISS"
        case .pending, .none: return ""
        }
    }

    var body: some View {
        ZStack {
            // Border glow — thick blurred stroke creates an edge-inward glow
            Rectangle()
                .fill(.clear)
                .overlay {
                    Rectangle()
                        .stroke(glowColor, lineWidth: 120)
                        .blur(radius: 70)
                }
                .clipped()
                .ignoresSafeArea()

            // "MAKE" / "MISS" text — centred on camera area (offset left of sidebar)
            Text(labelText)
                .font(.system(size: 56, weight: .black, design: .rounded))
                .foregroundStyle(glowColor)
                .shadow(color: glowColor.opacity(0.8), radius: 40)
                .shadow(color: glowColor.opacity(0.4), radius: 80)
                .padding(.trailing, sidebarWidth)
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .onChange(of: shotResult) { _, newValue in
            guard newValue == .make || newValue == .miss else { return }
            withAnimation(.easeIn(duration: 0.1)) {
                isVisible = true
            }
            withAnimation(.easeOut(duration: 0.9).delay(0.1)) {
                isVisible = false
            }
        }
    }
}
