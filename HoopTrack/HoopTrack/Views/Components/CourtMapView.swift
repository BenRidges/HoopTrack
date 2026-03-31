// CourtMapView.swift
// Draws an overhead half-court using SwiftUI Canvas.
// Shot dots are overlaid at normalised positions (0–1 in both axes).
//
// Phase 1: Court lines + static dots.
// Phase 2: Live dot streaming during sessions.
// Phase 5: Heat map density gradient layer.

import SwiftUI

struct CourtMapView: View {

    var shots: [ShotRecord] = []
    var highlightedShot: ShotRecord? = nil
    var showHeatMap: Bool = false         // Phase 5: toggle density gradient

    private let courtAspect: CGFloat = 0.55   // half-court is ~47x50 ft ≈ 0.94 ratio; map is portrait

    var body: some View {
        GeometryReader { geo in
            let size = courtSize(in: geo.size)
            let origin = CGPoint(
                x: (geo.size.width  - size.width)  / 2,
                y: (geo.size.height - size.height) / 2
            )

            ZStack {
                // Court lines
                Canvas { ctx, _ in
                    drawCourt(ctx: ctx, origin: origin, size: size)
                }

                // Shot dots
                ForEach(shots) { shot in
                    let pt = shotPoint(shot, origin: origin, size: size)
                    Circle()
                        .fill(color(for: shot))
                        .frame(width: dotSize(for: shot), height: dotSize(for: shot))
                        .position(pt)
                        .overlay {
                            if shot.id == highlightedShot?.id {
                                Circle()
                                    .stroke(Color.yellow, lineWidth: 2)
                                    .frame(width: dotSize(for: shot) + 4,
                                           height: dotSize(for: shot) + 4)
                                    .position(pt)
                            }
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1 / courtAspect, contentMode: .fit)
        .background(Color(red: 0.84, green: 0.68, blue: 0.42))  // hardwood colour
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Coordinate Helpers

    private func courtSize(in available: CGSize) -> CGSize {
        let w = available.width
        let h = w / courtAspect
        if h <= available.height { return CGSize(width: w, height: h) }
        let h2 = available.height
        return CGSize(width: h2 * courtAspect, height: h2)
    }

    private func shotPoint(_ shot: ShotRecord, origin: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: origin.x + shot.courtX * size.width,
            y: origin.y + (1 - shot.courtY) * size.height   // invert Y (0 = baseline)
        )
    }

    // MARK: - Canvas Drawing

    private func drawCourt(ctx: GraphicsContext, origin: CGPoint, size: CGSize) {
        let w = size.width
        let h = size.height
        let x = origin.x
        let y = origin.y

        var stroke = ctx
        stroke.stroke(
            courtPath(x: x, y: y, w: w, h: h),
            with: .color(.white.opacity(0.9)),
            lineWidth: 2
        )
    }

    private func courtPath(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            // Outer boundary
            p.addRect(CGRect(x: x, y: y, width: w, height: h))

            // Paint / key (roughly 16ft wide, 19ft tall on NBA court)
            let paintW: CGFloat = w * 0.32
            let paintH: CGFloat = h * 0.38
            let paintX = x + (w - paintW) / 2
            p.addRect(CGRect(x: paintX, y: y + h - paintH, width: paintW, height: paintH))

            // Free throw circle (radius ~6ft)
            let ftRadius: CGFloat = w * 0.12
            let ftCX = x + w / 2
            let ftCY = y + h - paintH
            p.addEllipse(in: CGRect(x: ftCX - ftRadius, y: ftCY - ftRadius,
                                    width: ftRadius * 2, height: ftRadius * 2))

            // Restricted area arc (4ft radius from basket)
            let raRadius: CGFloat = w * 0.08
            let basketY = y + h - h * 0.08
            p.addArc(center: CGPoint(x: x + w / 2, y: basketY),
                     radius: raRadius,
                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)

            // Three-point arc (approximate — actual shape requires Bézier)
            let tpRadius: CGFloat = w * 0.47
            let tpCY = basketY
            p.addArc(center: CGPoint(x: x + w / 2, y: tpCY),
                     radius: tpRadius,
                     startAngle: .degrees(210), endAngle: .degrees(330), clockwise: false)

            // Three-point corner lines
            let cornerY = y + h - h * 0.28
            p.move(to: CGPoint(x: x + w * 0.03, y: y + h))
            p.addLine(to: CGPoint(x: x + w * 0.03, y: cornerY))
            p.move(to: CGPoint(x: x + w * 0.97, y: y + h))
            p.addLine(to: CGPoint(x: x + w * 0.97, y: cornerY))

            // Basket (small circle)
            let basketRadius: CGFloat = w * 0.025
            p.addEllipse(in: CGRect(x: x + w / 2 - basketRadius,
                                    y: basketY - basketRadius,
                                    width: basketRadius * 2,
                                    height: basketRadius * 2))
        }
    }

    // MARK: - Dot Styling

    private func color(for shot: ShotRecord) -> Color {
        switch shot.result {
        case .make:    return .green
        case .miss:    return .red
        case .pending: return .yellow
        }
    }

    private func dotSize(for shot: ShotRecord) -> CGFloat {
        shot.id == highlightedShot?.id ? 14 : 10
    }
}

// MARK: - Legend
struct CourtMapLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            legendItem(color: .green, label: "Make")
            legendItem(color: .red,   label: "Miss")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

#Preview {
    CourtMapView(shots: [])
        .padding()
        .background(Color(.systemBackground))
}
