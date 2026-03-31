// SkillRadarView.swift
// Radar / spider chart drawn with SwiftUI Canvas.
// Renders up to 5 axes — one per SkillDimension.
// Phase 5: animate between old and new ratings after session completion.

import SwiftUI

struct SkillRadarView: View {

    /// Values keyed by SkillDimension, each normalised 0–1.
    var ratings: [SkillDimension: Double]
    var accentColor: Color = .orange

    private let dimensions = SkillDimension.allCases
    private let maxRating: Double = 100

    var body: some View {
        GeometryReader { geo in
            let size   = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = size * 0.38

            ZStack {
                // Background grid rings
                Canvas { ctx, _ in
                    for ring in stride(from: 0.2, through: 1.0, by: 0.2) {
                        let path = polygonPath(center: center,
                                               radius: radius * ring,
                                               sides: dimensions.count)
                        ctx.stroke(path,
                                   with: .color(.secondary.opacity(0.25)),
                                   lineWidth: 1)
                    }
                    // Axis spokes
                    for (i, _) in dimensions.enumerated() {
                        let angle = axisAngle(index: i)
                        let tip = CGPoint(x: center.x + radius * cos(angle),
                                          y: center.y + radius * sin(angle))
                        var spokePath = Path()
                        spokePath.move(to: center)
                        spokePath.addLine(to: tip)
                        ctx.stroke(spokePath,
                                   with: .color(.secondary.opacity(0.3)),
                                   lineWidth: 1)
                    }
                }

                // Filled skill polygon
                Canvas { ctx, _ in
                    let path = skillPath(center: center, radius: radius)
                    ctx.fill(path, with: .color(accentColor.opacity(0.25)))
                    ctx.stroke(path, with: .color(accentColor), lineWidth: 2)
                }

                // Axis labels
                ForEach(Array(dimensions.enumerated()), id: \.offset) { i, dim in
                    let angle = axisAngle(index: i)
                    let labelRadius = radius * 1.18
                    let pt = CGPoint(
                        x: center.x + labelRadius * cos(angle),
                        y: center.y + labelRadius * sin(angle)
                    )

                    VStack(spacing: 2) {
                        Image(systemName: dim.systemImage)
                            .font(.system(size: 11))
                        Text(dim.rawValue)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .position(pt)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Geometry

    private func axisAngle(index: Int) -> Double {
        let step = (2 * Double.pi) / Double(dimensions.count)
        // Start at top (−π/2) and go clockwise
        return -Double.pi / 2 + Double(index) * step
    }

    private func polygonPath(center: CGPoint, radius: Double, sides: Int) -> Path {
        Path { p in
            for i in 0..<sides {
                let angle = axisAngle(index: i)
                let pt = CGPoint(x: center.x + radius * cos(angle),
                                 y: center.y + radius * sin(angle))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
    }

    private func skillPath(center: CGPoint, radius: Double) -> Path {
        Path { p in
            for (i, dim) in dimensions.enumerated() {
                let value    = (ratings[dim] ?? 0) / maxRating
                let angle    = axisAngle(index: i)
                let r        = radius * value
                let pt = CGPoint(x: center.x + r * cos(angle),
                                 y: center.y + r * sin(angle))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
    }
}

#Preview {
    SkillRadarView(ratings: [
        .shooting:     72,
        .ballHandling: 55,
        .athleticism:  63,
        .consistency:  48,
        .volume:       80
    ])
    .frame(width: 260, height: 260)
    .padding()
}
