// Camera.swift
// A pinhole phone camera: 1280×720 landscape with the field of view the
// app assumes (CourtPositionEstimator.defaultHorizontalFOV, 68°), placed
// on a stand the way the app tells people to — behind the shooter at
// chest height with the whole rim in view — or behind the hoop facing out.
//
// Projection is to Vision-normalised coordinates: origin bottom-left, y up,
// the same as every box the app logs.

import Foundation
@testable import HoopTrack

struct CameraRig: Sendable {
    let position: Vec3
    let forward: Vec3
    let right: Vec3
    let up: Vec3
    /// Degrees across the image width.
    let horizontalFOV: Double
    let pixelWidth: Double
    let pixelHeight: Double

    var aspect: Double { pixelWidth / pixelHeight }
    /// Focal length in pixels.
    var focalPx: Double { pixelWidth / 2 / tan(horizontalFOV * .pi / 360) }
    /// Half the vertical field of view, degrees.
    var halfVerticalFOV: Double { atan(tan(horizontalFOV * .pi / 360) / aspect) * 180 / .pi }

    /// - Parameters: yaw/pitch/roll in degrees. Yaw 0 looks along −z (from
    ///   the court towards the backboard), positive yaw turns towards +x;
    ///   positive pitch looks up; positive roll turns the image clockwise.
    init(position: Vec3, yaw: Double, pitch: Double, roll: Double = 0,
         horizontalFOV: Double = CourtPositionEstimator.defaultHorizontalFOV,
         pixelWidth: Double = 1280, pixelHeight: Double = 720) {
        self.position = position
        self.horizontalFOV = horizontalFOV
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        let y = yaw * .pi / 180, p = pitch * .pi / 180, r = roll * .pi / 180
        let f = Vec3(sin(y) * cos(p), sin(p), -cos(y) * cos(p))
        let r0 = f.cross(.up).normalized
        let u0 = r0.cross(f)
        forward = f
        right = r0 * cos(r) + u0 * sin(r)
        up = u0 * cos(r) - r0 * sin(r)
    }

    struct Projection: Sendable {
        /// Vision-normalised.
        var x: Double
        var y: Double
        /// Distance along the optical axis, metres.
        var depth: Double
    }

    func project(_ p: Vec3) -> Projection? {
        let d = p - position
        let z = d.dot(forward)
        guard z > 0.05 else { return nil }
        let f = focalPx
        return Projection(x: 0.5 + f * d.dot(right) / z / pixelWidth,
                          y: 0.5 + f * d.dot(up) / z / pixelHeight,
                          depth: z)
    }

    /// Yaw that looks straight at `p` from `position`.
    static func yaw(from position: Vec3, to p: Vec3) -> Double {
        let d = p - position
        return atan2(d.x, -d.z) * 180 / .pi
    }

    /// Elevation of `p` above the camera's horizontal, degrees.
    static func elevation(from position: Vec3, to p: Vec3) -> Double {
        let d = p - position
        return atan2(d.y, d.horizontal.length) * 180 / .pi
    }

    // MARK: Things in the picture

    struct BallImage: Sendable {
        var x: Double
        var y: Double
        var depth: Double
        /// Apparent diameter in camera pixels.
        var diameterPx: Double
        /// Image velocity, pixels per second.
        var velocityX: Double
        var velocityY: Double
    }

    func ball(at centre: Vec3, velocity: Vec3) -> BallImage? {
        guard let c = project(centre) else { return nil }
        let dt = 1e-3
        let ahead = project(centre + velocity * dt) ?? c
        return BallImage(x: c.x, y: c.y, depth: c.depth,
                         diameterPx: focalPx * 2 * Court.ballRadius / c.depth,
                         velocityX: (ahead.x - c.x) * pixelWidth / dt,
                         velocityY: (ahead.y - c.y) * pixelHeight / dt)
    }

    /// Bounding box of a set of world points, nil if any is behind the camera.
    func box(of points: [Vec3]) -> Box? {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for p in points {
            guard let q = project(p) else { return nil }
            x0 = min(x0, q.x); y0 = min(y0, q.y); x1 = max(x1, q.x); y1 = max(y1, q.y)
        }
        return Box(minX: x0, minY: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The basket as the detector should box it: the ring plus the net
    /// (`withNet`), or the ring alone. `netOffset` moves the bottom of the
    /// net (a swinging or bulging net).
    func hoopBox(centre: Vec3 = Court.rimCentre, withNet: Bool, netOffset: Vec3 = .zero) -> Box? {
        var points: [Vec3] = []
        let outer = Court.rimRingRadius + Court.rimTubeRadius
        for i in 0..<24 {
            let a = Double(i) / 24 * 2 * .pi
            let p = centre + Vec3(outer * cos(a), 0, outer * sin(a))
            points.append(p + Vec3(0, Court.rimTubeRadius, 0))
            points.append(p - Vec3(0, Court.rimTubeRadius, 0))
        }
        if withNet {
            for i in 0..<12 {
                let a = Double(i) / 12 * 2 * .pi
                points.append(centre + netOffset + Vec3(Court.netBottomRadius * cos(a), -Court.netLength,
                                                        Court.netBottomRadius * sin(a)))
            }
        }
        return box(of: points)
    }

    /// A vertical rectangle facing the camera, `width` wide, from `bottom`
    /// to `top` metres above the floor point `base`.
    func uprightBox(base: Vec3, width: Double, bottom: Double, top: Double) -> Box? {
        let across = right.horizontal.normalized * (width / 2)
        return box(of: [base + across + Vec3(0, bottom, 0), base - across + Vec3(0, bottom, 0),
                        base + across + Vec3(0, top, 0), base - across + Vec3(0, top, 0)])
    }
}

/// Where the phone stands for a session.
enum CameraPlacement: Sendable {
    /// Behind the shooter: `back` metres behind the release point, on a
    /// stand `height` metres up, aimed at the hoop.
    case behindShooter(back: ClosedRange<Double>, height: ClosedRange<Double>)
    /// Behind the (glass) backboard looking out at the shooter.
    case facingShooter(behind: ClosedRange<Double>, height: ClosedRange<Double>)

    var facesShooter: Bool {
        if case .facingShooter = self { return true }
        return false
    }

    /// Places the camera for a shooter whose usual spot is `spot` (on the
    /// floor), aiming as a person would: hoop centred left-right, tilted so
    /// the rim, the net and (if it fits) the shooter's release are in frame.
    /// `standOff` is how far to the side of the camera's line to the hoop the
    /// shooter stands, so they don't block it.
    func camera(spot: Vec3, releaseHeight: Double, standOff: Double, rng: inout SimRNG) -> CameraRig {
        let hoopFloor = Vec3(0, 0, 0)
        let out = (spot - hoopFloor).horizontal.normalized          // hoop → shooter
        let across = out.cross(.up).normalized
        let probe = CameraRig(position: .zero, yaw: 0, pitch: 0)
        let halfV = probe.halfVerticalFOV
        let margin = 0.08 * 2 * halfV

        switch self {
        case .behindShooter(let back, let height):
            let distanceBack = rng.uniform(back)
            // `standOff` is the gap at the shooter between them and the
            // camera's line to the hoop; the camera moves further aside.
            let d = max(0.5, (spot - hoopFloor).horizontal.length)
            var position = spot + out * distanceBack + across * (standOff * (d + distanceBack) / d)
            position.y = rng.uniform(height)
            let yaw = CameraRig.yaw(from: position, to: Court.rimCentre) + rng.gaussian(0, 1.5)
            let rimTop = CameraRig.elevation(from: position, to: Court.rimCentre + Vec3(0, 0.05, 0))
            let netBottom = CameraRig.elevation(from: position, to: Court.rimCentre - Vec3(0, Court.netLength + 0.05, 0))
            let release = CameraRig.elevation(from: position, to: spot + Vec3(0, releaseHeight, 0) - out * 0.35)
            var pitch = (netBottom + release) / 2 + rng.gaussian(0, 2)
            // The whole rim and net have to be in frame, whatever else isn't.
            pitch = min(pitch, netBottom + halfV - margin)
            pitch = max(pitch, rimTop - halfV + margin)
            return CameraRig(position: position, yaw: yaw, pitch: pitch, roll: rng.gaussian(0, 1))

        case .facingShooter(let behind, let height):
            // On the far side of the board, roughly in line with the shooter.
            let lateral = rng.uniform(-0.6, 0.6)
            var position = Vec3(-out.x * 1.2 + lateral, rng.uniform(height), Court.boardZ - rng.uniform(behind))
            position.x = clampValue(position.x, -1.5, 1.5)
            let yaw = CameraRig.yaw(from: position, to: Court.rimCentre) + rng.gaussian(0, 1.5)
            let rimTop = CameraRig.elevation(from: position, to: Court.rimCentre + Vec3(0, 0.05, 0))
            let netBottom = CameraRig.elevation(from: position, to: Court.rimCentre - Vec3(0, Court.netLength + 0.05, 0))
            let release = CameraRig.elevation(from: position, to: spot + Vec3(0, releaseHeight, 0))
            var pitch = (rimTop + release) / 2 + rng.gaussian(0, 2)
            pitch = max(pitch, rimTop - halfV + margin)
            pitch = min(pitch, netBottom + halfV - margin)
            return CameraRig(position: position, yaw: yaw, pitch: pitch, roll: rng.gaussian(0, 1))
        }
    }
}
