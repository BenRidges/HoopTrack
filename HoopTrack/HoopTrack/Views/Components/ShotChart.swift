// ShotChart.swift
// Half-court drawing + shot chart. Drawn from CourtGeometry (feet), with
// the basket at the top — the same view you have from behind the shooter,
// so a shot from your right lands on the right.
//
// Up to ~60 shots are drawn individually (filled = make, ring = miss).
// Beyond that, shots are binned into a grid: dot size is volume, colour
// is efficiency — readable at a glance however many shots you take.

import SwiftUI

/// Court lines for a 50 × 47 ft half court. Draw into a 50:47 rect.
struct HalfCourtShape: Shape {
    var threePointFt: Double = CourtType.nba.threePointDistanceFt

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / CourtGeometry.widthFt
        let sy = rect.height / CourtGeometry.depthFt
        func p(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        let basket = (x: CourtGeometry.widthFt / 2, y: CourtGeometry.basketYFt)

        // Arcs are sampled as polylines: no clockwise/flipped-axis ambiguity.
        func arc(radius r: Double, from a0: Double, to a1: Double, in path: inout Path) {
            let steps = 48
            for i in 0...steps {
                let a = a0 + (a1 - a0) * Double(i) / Double(steps)
                let point = p(basket.x + r * cos(a), basket.y + r * sin(a))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }

        var path = Path()
        // Baseline and sidelines.
        path.addRect(CGRect(origin: p(0, 0), size: CGSize(width: rect.width, height: rect.height)))
        // Lane.
        path.addRect(CGRect(origin: p(17, 0), size: CGSize(width: 16 * sx, height: 19 * sy)))
        // Free-throw circle.
        let ft = CourtGeometry.freeThrowCircleRadiusFt
        path.addEllipse(in: CGRect(origin: p(25 - ft, 19 - ft), size: CGSize(width: 2 * ft * sx, height: 2 * ft * sy)))
        // Restricted area (the half facing the court).
        arc(radius: CourtGeometry.restrictedAreaRadiusFt, from: 0, to: .pi, in: &path)
        // Backboard and rim.
        path.move(to: p(22, 4)); path.addLine(to: p(28, 4))
        path.addEllipse(in: CGRect(origin: p(24.25, basket.y - 0.75), size: CGSize(width: 1.5 * sx, height: 1.5 * sy)))
        // Three-point line: straight corners, then the arc.
        let corner = min(threePointFt, CourtGeometry.cornerThreeMaxFt)
        let breakY = CourtGeometry.cornerBreakFt(threePointDistanceFt: threePointFt)
        let side = atan2(breakY - basket.y, corner)
        path.move(to: p(basket.x - corner, 0)); path.addLine(to: p(basket.x - corner, breakY))
        path.move(to: p(basket.x + corner, 0)); path.addLine(to: p(basket.x + corner, breakY))
        arc(radius: threePointFt, from: side, to: .pi - side, in: &path)
        return path
    }
}

struct ShotChart: View {
    var shots: [ShotRecord]
    var threePointFt: Double = CourtType.nba.threePointDistanceFt
    var highlighted: ShotRecord.ID? = nil

    private static let individualLimit = 60

    private var placed: [ShotRecord] {
        shots.filter { $0.result != .pending && $0.zone != .unknown }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                HalfCourtShape(threePointFt: threePointFt)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1.5)

                if placed.count <= Self.individualLimit {
                    ForEach(placed) { shot in
                        marker(for: shot)
                            .position(x: shot.courtX * size.width, y: shot.courtY * size.height)
                    }
                } else {
                    ForEach(bins(), id: \.key) { bin in
                        Circle()
                            .fill(Color.shooting(bin.fgPercent))
                            .opacity(0.85)
                            .frame(width: bin.diameter, height: bin.diameter)
                            .position(x: bin.x * size.width, y: bin.y * size.height)
                    }
                }
            }
        }
        .aspectRatio(CourtGeometry.widthFt / CourtGeometry.depthFt, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func marker(for shot: ShotRecord) -> some View {
        let isHighlighted = shot.id == highlighted
        let d: CGFloat = isHighlighted ? 15 : 9
        ZStack {
            if shot.isMake {
                Circle().fill(Color.make)
            } else {
                Circle().strokeBorder(Color.miss, lineWidth: 2)
            }
            if isHighlighted {
                Circle().strokeBorder(Color.white, lineWidth: 2).padding(-4)
            }
        }
        .frame(width: d, height: d)
    }

    // MARK: Binning

    private struct Bin {
        let key: Int
        let x: Double
        let y: Double
        let fgPercent: Double
        let diameter: CGFloat
    }

    private func bins() -> [Bin] {
        let columns = 12, rows = 11
        var counts: [Int: (made: Int, total: Int, sx: Double, sy: Double)] = [:]
        for shot in placed {
            let c = min(columns - 1, Int(shot.courtX * Double(columns)))
            let r = min(rows - 1, Int(shot.courtY * Double(rows)))
            var entry = counts[r * columns + c] ?? (0, 0, 0, 0)
            entry.total += 1
            entry.made += shot.isMake ? 1 : 0
            entry.sx += shot.courtX
            entry.sy += shot.courtY
            counts[r * columns + c] = entry
        }
        let busiest = Double(counts.values.map(\.total).max() ?? 1)
        return counts.map { key, value in
            let share = (Double(value.total) / busiest).squareRoot()
            return Bin(key: key,
                       x: value.sx / Double(value.total),
                       y: value.sy / Double(value.total),
                       fgPercent: Double(value.made) / Double(value.total) * 100,
                       diameter: 8 + 18 * share)
        }
    }

    private var accessibilitySummary: String {
        guard !placed.isEmpty else { return "Shot chart. No placed shots." }
        let makes = placed.filter(\.isMake).count
        return "Shot chart. \(makes) makes from \(placed.count) placed shots."
    }
}

/// "● Make  ○ Miss" key, shown under individual-shot charts.
struct ShotChartKey: View {
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) { Circle().fill(Color.make).frame(width: 8, height: 8); Text("Make") }
            HStack(spacing: 6) { Circle().strokeBorder(Color.miss, lineWidth: 2).frame(width: 9, height: 9); Text("Miss") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
