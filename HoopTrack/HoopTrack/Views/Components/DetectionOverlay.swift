// DetectionOverlay.swift
// Draws the detected hoop rectangle (green) and the current ball bounding box
// (orange) directly over the camera preview. Rects are Vision-normalised
// (origin bottom-left, 0–1); this view flips to SwiftUI's top-left origin.
//
// Temporary debug aid — remove once CV detection is verified end-to-end.

import SwiftUI

struct DetectionOverlay: View {
    let hoopRect: CGRect?
    let ballBox: CGRect?
    let ballConfidence: Float?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let hoop = hoopRect {
                    rect(from: hoop, in: geo.size)
                        .stroke(Color.green, lineWidth: 2)
                    label("HOOP",
                          color: .green,
                          at: rect(from: hoop, in: geo.size).boundingRect.origin)
                }
                if let ball = ballBox {
                    let mapped = rect(from: ball, in: geo.size)
                    mapped.stroke(Color.orange, lineWidth: 2)
                    label(ballLabel,
                          color: .orange,
                          at: mapped.boundingRect.origin)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Maps Vision coords (bottom-left origin, 0–1) to SwiftUI rect in view space.
    private func rect(from vision: CGRect, in size: CGSize) -> Path {
        let x = vision.origin.x * size.width
        let w = vision.width * size.width
        let h = vision.height * size.height
        // Flip Y: Vision y=0 is at the bottom, SwiftUI y=0 is at the top.
        let y = (1 - vision.origin.y - vision.height) * size.height
        return Path(CGRect(x: x, y: y, width: w, height: h))
    }

    private func label(_ text: String, color: Color, at point: CGPoint) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
            .offset(x: point.x, y: max(0, point.y - 14))
    }

    private var ballLabel: String {
        if let c = ballConfidence {
            return "BALL \(Int(c * 100))%"
        }
        return "BALL"
    }
}

#Preview {
    ZStack {
        Color.black
        DetectionOverlay(
            hoopRect: CGRect(x: 0.45, y: 0.70, width: 0.10, height: 0.08),
            ballBox:  CGRect(x: 0.48, y: 0.45, width: 0.06, height: 0.06),
            ballConfidence: 0.87
        )
    }
    .frame(width: 400, height: 300)
}
