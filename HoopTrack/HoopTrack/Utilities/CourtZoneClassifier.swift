// CourtZoneClassifier.swift
// One court model shared by the classifier, the CV position estimator and
// the shot chart. Everything is in feet on an NBA-proportioned half court
// (50 ft wide × 47 ft deep, basket centre 5.25 ft from the baseline).
//
// Stored shot positions stay normalised 0–1 so existing data keeps working:
//   courtX = feet from the left sideline / 50
//   courtY = feet from the baseline     / 47

import Foundation

nonisolated enum CourtGeometry {
    static let widthFt: Double = 50
    static let depthFt: Double = 47
    static let basketYFt: Double = 5.25
    static let paintHalfWidthFt: Double = 8
    static let freeThrowLineFt: Double = 19
    static let freeThrowCircleRadiusFt: Double = 6
    static let restrictedAreaRadiusFt: Double = 4
    /// Corner three distance cap — the straight part of the line sits 22 ft
    /// from the basket on NBA courts. Shorter arcs simply have no straight part.
    static let cornerThreeMaxFt: Double = 22

    /// Feet from the basket centre to a normalised court point.
    static func offsetFromBasket(courtX: Double, courtY: Double) -> (lateralFt: Double, depthFt: Double) {
        (courtX * widthFt - widthFt / 2, courtY * depthFt - basketYFt)
    }

    /// Normalised court point for an offset from the basket, clamped onto the court.
    static func normalised(lateralFt: Double, depthFt: Double) -> (courtX: Double, courtY: Double) {
        let x = (widthFt / 2 + lateralFt) / widthFt
        let y = (basketYFt + depthFt) / self.depthFt
        return (x.clamped(to: 0...1), y.clamped(to: 0...1))
    }

    /// Height above the baseline (ft) where the three-point arc meets the corner line.
    static func cornerBreakFt(threePointDistanceFt r: Double) -> Double {
        let c = min(r, cornerThreeMaxFt)
        return basketYFt + max(0, r * r - c * c).squareRoot()
    }
}

nonisolated enum CourtZoneClassifier {

    /// Classifies a normalised court position. Non-finite or off-court input
    /// returns `.unknown` rather than guessing a zone.
    static func classify(courtX: Double,
                         courtY: Double,
                         threePointDistanceFt: Double = 23.75) -> CourtZone {
        guard InputValidator.isValidCourtCoordinate(courtX),
              InputValidator.isValidCourtCoordinate(courtY) else { return .unknown }

        let (dx, dy) = CourtGeometry.offsetFromBasket(courtX: courtX, courtY: courtY)
        let yFromBaseline = courtY * CourtGeometry.depthFt
        let distance = (dx * dx + dy * dy).squareRoot()
        let cornerDistance = min(threePointDistanceFt, CourtGeometry.cornerThreeMaxFt)

        // Beyond the line: below the break it's a straight corner line,
        // above the break it's the arc.
        if yFromBaseline <= CourtGeometry.cornerBreakFt(threePointDistanceFt: threePointDistanceFt) {
            if abs(dx) >= cornerDistance { return .cornerThree }
        } else if distance >= threePointDistanceFt {
            return .aboveBreakThree
        }

        let inLane = abs(dx) <= CourtGeometry.paintHalfWidthFt
        if inLane && abs(yFromBaseline - CourtGeometry.freeThrowLineFt) <= 2 {
            return .freeThrow
        }
        if inLane && yFromBaseline < CourtGeometry.freeThrowLineFt {
            return .paint
        }
        return .midRange
    }
}
