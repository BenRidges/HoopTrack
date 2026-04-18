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

    // NBA half-court: 50 ft wide × 47 ft deep (portrait — baseline at bottom).
    // courtAspect = width / height = 47/50.
    private let courtAspect: CGFloat = 47.0 / 50.0

    // Phase 11 — accessibility summary for VoiceOver users.
    private var courtMapAccessibilitySummary: String {
        guard !shots.isEmpty else { return "Shot chart. No shots recorded." }
        let makes = shots.filter { $0.result == .make }.count
        let misses = shots.count - makes
        return "Shot chart. \(makes) makes, \(misses) misses out of \(shots.count) total shots."
    }

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
        .aspectRatio(courtAspect, contentMode: .fit)
        .background(Color(red: 0.84, green: 0.68, blue: 0.42))  // hardwood colour
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Phase 11 — expose a single accessibility element so VoiceOver reads the summary.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(courtMapAccessibilitySummary)
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
        ctx.stroke(
            courtPath(x: origin.x, y: origin.y, w: size.width, h: size.height),
            with: .color(.white.opacity(0.9)),
            lineWidth: 2
        )
    }

    private func courtPath(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> Path {
        // All fractions derived from NBA half-court: 50 ft wide × 47 ft deep.
        // Scale: 1 ft = w/50 = h/47 (equal because courtAspect = 47/50).

        let cx = x + w / 2                          // horizontal centre

        // Basket: front rim 5.25 ft from baseline
        let basketY = y + h * (1 - 5.25 / 47)

        // Paint: 16 ft wide (8 ft each side), FT line 19 ft from baseline
        let paintHalf: CGFloat = w * (8.0 / 50)
        let ftLineY   = y + h * (1 - 19.0 / 47)

        // Free throw circle: 6 ft radius
        let ftRadius: CGFloat = w * (6.0 / 50)

        // Restricted area arc: 4 ft radius, open toward half-court
        let raRadius: CGFloat = w * (4.0 / 50)

        // Three-point line: arc radius 23.75 ft; corner lines 3 ft from sideline
        let tpRadius:     CGFloat = w * (23.75 / 50)
        let cornerXLeft   = x + w * (3.0  / 50)
        let cornerXRight  = x + w * (47.0 / 50)   // = sideline - 3 ft
        // canvas-y where corner line meets the arc (above basket)
        let cornerDX: CGFloat = cx - cornerXLeft   // horizontal arm: 22 ft = 0.44 w
        let cornerDY: CGFloat = (tpRadius * tpRadius - cornerDX * cornerDX).squareRoot()
        let cornerEndY    = basketY - cornerDY

        // Backboard: 6 ft wide, 4 ft from baseline
        let backboardHalf: CGFloat = w * (3.0 / 50)
        let backboardY    = y + h * (1 - 4.0 / 47)

        // Basket circle: symbolic size (~0.75 ft radius on court)
        let basketRadius: CGFloat = w * 0.025

        return Path { p in

            // 1. Outer boundary
            p.addRect(CGRect(x: x, y: y, width: w, height: h))

            // 2. Paint / key
            p.addRect(CGRect(x: cx - paintHalf, y: ftLineY,
                             width: paintHalf * 2, height: y + h - ftLineY))

            // 3. Free throw circle (full)
            p.addEllipse(in: CGRect(x: cx - ftRadius, y: ftLineY - ftRadius,
                                    width: ftRadius * 2, height: ftRadius * 2))

            // 4. Restricted area arc (upper semicircle, open toward half-court)
            p.move(to: CGPoint(x: cx - raRadius, y: basketY))
            p.addArc(center: CGPoint(x: cx, y: basketY),
                     radius: raRadius,
                     startAngle: .degrees(180), endAngle: .degrees(0),
                     clockwise: false)

            // 5. Three-point corner lines (baseline → corner meeting point)
            p.move(to: CGPoint(x: cornerXLeft,  y: y + h))
            p.addLine(to: CGPoint(x: cornerXLeft,  y: cornerEndY))
            p.move(to: CGPoint(x: cornerXRight, y: y + h))
            p.addLine(to: CGPoint(x: cornerXRight, y: cornerEndY))

            // 6. Three-point arc: angles computed from actual corner positions so the
            //    arc meets the corner lines exactly. clockwise: false draws the arc
            //    bowing away from the basket toward half-court.
            let startAngle = Angle(radians: Double(atan2(cornerEndY - basketY, cornerXLeft  - cx)))
            let endAngle   = Angle(radians: Double(atan2(cornerEndY - basketY, cornerXRight - cx)))
            p.move(to: CGPoint(x: cornerXLeft, y: cornerEndY))
            p.addArc(center: CGPoint(x: cx, y: basketY),
                     radius: tpRadius,
                     startAngle: startAngle,
                     endAngle: endAngle,
                     clockwise: false)

            // 7. Backboard
            p.move(to: CGPoint(x: cx - backboardHalf, y: backboardY))
            p.addLine(to: CGPoint(x: cx + backboardHalf, y: backboardY))

            // 8. Basket circle
            p.addEllipse(in: CGRect(x: cx - basketRadius, y: basketY - basketRadius,
                                    width: basketRadius * 2, height: basketRadius * 2))
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
