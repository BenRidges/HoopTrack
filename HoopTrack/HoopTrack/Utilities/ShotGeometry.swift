// ShotGeometry.swift
// Turns 2D detections into court-space numbers using things we know the
// real size of: a basketball is 24 cm across, a rim 45.7 cm. With the
// camera's field of view that gives each object's distance from the lens,
// and from there the shooter's position relative to the basket.
//
// Assumes the usual setup: phone on a stand behind (or in front of) the
// shooter, looking at the hoop. Side-on camera placements can't be mapped
// to the court this way and fall back to "unknown position".

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated enum CourtPositionEstimator {

    static let ballDiameterM: Double = 0.239
    static let rimDiameterM: Double = 0.457
    /// iPhone wide camera, 16:9 video. Used when the device doesn't report one.
    static let defaultHorizontalFOV: Double = 68

    struct Estimate: Sendable, Equatable {
        /// Metres right (+) / left (−) of the basket centre, as seen from the camera.
        let lateralM: Double
        /// Metres out from the basket towards the camera.
        let depthM: Double
        var distanceM: Double { (lateralM * lateralM + depthM * depthM).squareRoot() }
        var distanceFt: Double { distanceM * 3.2808 }
    }

    /// - Parameters:
    ///   - ballBox: ball at release, Vision-normalised.
    ///   - ballDiameter: apparent ball diameter in image-width units (median over a few frames).
    ///   - rimBox: smoothed rim box, Vision-normalised.
    ///   - horizontalFOV: degrees, across the image width.
    static func estimate(ballBox: CGRect,
                         ballDiameter: Double,
                         rimBox: CGRect,
                         horizontalFOV: Double = defaultHorizontalFOV) -> Estimate? {
        let rimWidth = Double(rimBox.width)
        guard ballDiameter > 0.002, rimWidth > 0.004,
              horizontalFOV > 10, horizontalFOV < 170 else { return nil }

        // Focal length in image-width units.
        let f = 0.5 / tan(horizontalFOV * .pi / 360)

        let ballDepth = f * ballDiameterM / ballDiameter
        let rimDepth  = f * rimDiameterM / rimWidth
        let ballX = (Double(ballBox.midX) - 0.5) * ballDepth / f
        let rimX  = (Double(rimBox.midX) - 0.5) * rimDepth / f

        let lateral = ballX - rimX
        let depth = rimDepth - ballDepth
        guard lateral.isFinite, depth.isFinite,
              abs(lateral) < 12, depth > -2, depth < 16 else { return nil }
        return Estimate(lateralM: lateral, depthM: max(0, depth))
    }

    /// Normalised court coordinates for an estimate (see CourtGeometry).
    static func courtPosition(for estimate: Estimate) -> (courtX: Double, courtY: Double) {
        CourtGeometry.normalised(lateralFt: estimate.lateralM * 3.2808,
                                 depthFt: estimate.depthM * 3.2808)
    }
}

/// Launch angle and speed from flight time. From behind the shooter the
/// ball's arc is foreshortened, so measuring the angle off the image is
/// meaningless; but how long the ball takes to reach the rim from a known
/// distance pins down the launch velocity once gravity is accounted for.
nonisolated enum ShotPhysics {

    static let gravity: Double = 9.81
    static let rimHeightM: Double = 3.048
    /// Typical jump-shot release height. Errors of ±30 cm move the angle ~2°.
    static let assumedReleaseHeightM: Double = 2.2

    struct Launch: Sendable, Equatable {
        let angleDeg: Double
        let speedMph: Double
    }

    /// - Parameters:
    ///   - horizontalDistanceM: release point to basket, along the floor.
    ///   - flightTime: seconds from release to the ball dropping through rim height.
    static func launch(horizontalDistanceM d: Double,
                       flightTime t: Double,
                       heightGainM h: Double = rimHeightM - assumedReleaseHeightM) -> Launch? {
        guard d.isFinite, t.isFinite, d >= 0.8, d <= 12, t >= 0.35, t <= 2.5 else { return nil }
        let vHorizontal = d / t
        let vVertical = (h + 0.5 * gravity * t * t) / t
        let angle = atan2(vVertical, vHorizontal) * 180 / .pi
        let speed = (vHorizontal * vHorizontal + vVertical * vVertical).squareRoot() * 2.23694
        guard angle >= 20, angle <= 80 else { return nil }
        return Launch(angleDeg: angle, speedMph: speed)
    }
}
