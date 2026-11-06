// BallFilter.swift
// Constant-velocity Kalman filter for the ball in flight, one independent
// filter per image axis. ShotTracker uses it to predict where the ball
// should be in the next frame and how far from that prediction a
// detection may land and still be the same ball.
//
// Compared with extrapolating from the last two samples, the filter:
//   • isn't thrown by one noisy box (it weighs each measurement against
//     its own confidence),
//   • widens its gate on its own across missed frames, and narrows it
//     again once the ball is seen,
//   • keeps a smoothed velocity, so a bounce or a lost frame doesn't
//     send the prediction off the screen.
//
// Gravity isn't modelled explicitly: on screen it's a perspective-dependent
// deceleration, so it's absorbed by the process noise (`accelerationSD`).
// Units are whatever the caller uses consistently — ShotTracker feeds it
// height-normalised coordinates with x scaled by the aspect ratio, so both
// axes share a unit.

import Foundation

nonisolated struct BallFilter: Sendable, Equatable {

    struct Point: Sendable, Equatable {
        var x: Double
        var y: Double
    }

    /// Position + velocity along one axis with its 2×2 covariance.
    private struct Axis: Sendable, Equatable {
        var position: Double
        var velocity: Double
        var pPP: Double        // var(position)
        var pPV: Double        // cov(position, velocity)
        var pVV: Double        // var(velocity)

        func predicted(dt: Double, q: Double) -> Axis {
            guard dt > 0 else { return self }
            let dt2 = dt * dt, dt3 = dt2 * dt, dt4 = dt3 * dt
            return Axis(position: position + velocity * dt,
                        velocity: velocity,
                        pPP: pPP + 2 * dt * pPV + dt2 * pVV + q * dt4 / 4,
                        pPV: pPV + dt * pVV + q * dt3 / 2,
                        pVV: pVV + q * dt2)
        }

        mutating func correct(measurement z: Double, r: Double) {
            let s = pPP + r
            guard s > 0 else { return }
            let kP = pPP / s, kV = pPV / s
            let innovation = z - position
            position += kP * innovation
            velocity += kV * innovation
            let newPP = (1 - kP) * pPP
            let newPV = (1 - kP) * pPV
            let newVV = pVV - kV * pPV
            pPP = newPP; pPV = newPV; pVV = newVV
        }
    }

    private var x: Axis
    private var y: Axis
    private(set) var time: Double
    /// Standard deviation of unmodelled acceleration (units / s²).
    let accelerationSD: Double
    /// Standard deviation of a single position measurement (units).
    let measurementSD: Double

    init(at point: Point, velocity: Point = Point(x: 0, y: 0), time: Double,
         accelerationSD: Double, measurementSD: Double, initialVelocitySD: Double) {
        let r = measurementSD * measurementSD
        let v = initialVelocitySD * initialVelocitySD
        x = Axis(position: point.x, velocity: velocity.x, pPP: r, pPV: 0, pVV: v)
        y = Axis(position: point.y, velocity: velocity.y, pPP: r, pPV: 0, pVV: v)
        self.time = time
        self.accelerationSD = accelerationSD
        self.measurementSD = measurementSD
    }

    var position: Point { Point(x: x.position, y: y.position) }
    var velocity: Point { Point(x: x.velocity, y: y.velocity) }

    /// Where the ball should be at `time`, without changing the filter.
    func predicted(at time: Double) -> Point {
        let dt = time - self.time
        let q = accelerationSD * accelerationSD
        return Point(x: x.predicted(dt: dt, q: q).position, y: y.predicted(dt: dt, q: q).position)
    }

    /// How surprising a detection at `point` would be at `time`, in standard
    /// deviations (Mahalanobis distance over both axes).
    func surprise(of point: Point, at time: Double) -> Double {
        let dt = time - self.time
        let q = accelerationSD * accelerationSD
        let r = measurementSD * measurementSD
        let px = x.predicted(dt: dt, q: q), py = y.predicted(dt: dt, q: q)
        let dx = point.x - px.position, dy = point.y - py.position
        return (dx * dx / (px.pPP + r) + dy * dy / (py.pPP + r)).squareRoot()
    }

    /// Advances to `time` and folds in a measurement.
    mutating func update(with point: Point, at time: Double) {
        let dt = max(0, time - self.time)
        let q = accelerationSD * accelerationSD
        let r = measurementSD * measurementSD
        x = x.predicted(dt: dt, q: q)
        y = y.predicted(dt: dt, q: q)
        x.correct(measurement: point.x, r: r)
        y.correct(measurement: point.y, r: r)
        self.time = max(self.time, time)
    }
}
