// HoopTrack/Utilities/CourtZoneClassifier.swift
import Foundation

/// Maps a normalised court position (0–1, origin bottom-left half-court)
/// to a CourtZone using the geometry constants in HoopTrack.CourtGeometry.
nonisolated enum CourtZoneClassifier {

    static func classify(courtX: Double, courtY: Double) -> CourtZone {
        // Phase 7 — Security: guard against NaN, Inf, or out-of-range inputs from
        // uncalibrated frames or future callers that skip the DataService validation layer.
        guard InputValidator.isValidCourtCoordinate(courtX),
              InputValidator.isValidCourtCoordinate(courtY) else {
            return .midRange
        }

        let paintHalfWidth     = HoopTrack.CourtGeometry.paintWidthFraction / 2.0    // 0.16
        let inPaintX           = abs(courtX - 0.5) <= paintHalfWidth
        let freeThrowTolerance = 0.05
        let atFreeThrowY       = abs(courtY - HoopTrack.CourtGeometry.freeThrowLineFraction) <= freeThrowTolerance

        // Free throw (checked before paint to avoid free-throw-line shots classified as paint)
        if inPaintX && atFreeThrowY {
            return .freeThrow
        }

        // Paint: horizontally within paint, below free throw line
        if inPaintX && courtY <= HoopTrack.CourtGeometry.paintHeightFraction {
            return .paint
        }

        // Distance from basket (basket modelled at x=0.5, y=0.0 in normalised space)
        let dx = courtX - 0.5
        let dy = courtY
        let distanceFromBasket = (dx * dx + dy * dy).squareRoot()

        // Corner three: outside paint width, below corner depth, AND outside the arc
        let outsidePaintX = abs(courtX - 0.5) > paintHalfWidth
        if outsidePaintX
            && courtY <= HoopTrack.CourtGeometry.cornerThreeDepthFraction
            && distanceFromBasket >= HoopTrack.CourtGeometry.threePointArcRadiusFraction {
            return .cornerThree
        }

        // Above-break three: beyond arc radius
        if distanceFromBasket >= HoopTrack.CourtGeometry.threePointArcRadiusFraction {
            return .aboveBreakThree
        }

        return .midRange
    }
}
