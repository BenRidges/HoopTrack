// BallFilter.swift
// Kalman filter for the ball in flight. ShotTracker uses it to predict
// where the ball should be in the next frame, or after it has been out of
// sight, and how far from that prediction a detection may land and still
// be the same ball.
//
// The motion model is a ball in free flight seen by a pinhole camera. For
// a ball at depth Z moving along the lens axis at Ż, the image position
// (y up) obeys
//
//     ẍ = −c·ẋ          + bₓ
//     ÿ = −c·ẏ − G      + b_y          G = g·f / Z,   c = 2·Ż / Z
//
// G is gravity at the ball's depth. In apparent ball diameters it is the
// same at any depth: g / 0.239 m ≈ 41 diameters/s², so G = 41·D for a ball
// that looks D across. c is perspective: a ball flying away from a camera
// behind the shooter slows down in the image on the way up and falls
// slowly after the apex (towards a camera behind the hoop it's the
// reverse). Both come from the apparent diameter: D ∝ 1/Z, so the filter
// also tracks W = 1/D, which changes at a steady rate while the ball's
// speed along the lens axis is steady, and c = 2·Ẇ/W.
//
// On a real 45° clip (somorin-dusk-cam1, 2026-11) this predicts the
// image acceleration the boxes show: ~43 rim widths/s² on the way up,
// ~18 on the way down. A constant-velocity filter (what this was before)
// sends a ball that leaves the top of the frame at its apex off into the
// sky; a constant-acceleration one brings it back to the rim 0.3 s early.
//
// What the model leaves out — drag, spin, camera tilt, boxes a little
// bigger than the ball — goes into a residual acceleration b per axis,
// estimated from the detections and allowed to wander slowly, plus white
// acceleration noise. A bounce off the rim or board is a kick to the
// velocity that the caller declares (`bounceSD`), since only it knows
// where the hoop is.
//
// Units are whatever the caller uses consistently: ShotTracker feeds it
// height-normalised coordinates with x scaled by the aspect ratio, so both
// axes share a unit, and diameters in that unit too. Without diameters the
// filter has no depth: G and c are 0 and the residual acceleration (with
// its starting SD) has to stand in for gravity.

import Foundation

nonisolated struct BallFilter: Sendable, Equatable {

    struct Point: Sendable, Equatable {
        var x: Double
        var y: Double
    }

    /// How much the ball may stray from the model, in the caller's units.
    struct Noise: Sendable, Equatable {
        /// SD of one detection's centre.
        var measurementSD: Double
        /// Density of white acceleration noise (units² / s³).
        var acceleration: Double
        /// Density of the residual acceleration's random walk (units² / s⁵).
        var residualDrift: Double = 0
        /// SD of the residual acceleration when the filter starts (units / s²).
        var initialResidualSD: Double = 0
        /// SD of the starting velocity (units / s).
        var initialVelocitySD: Double
        /// SD of one apparent-diameter measurement, as a fraction of it
        /// (detector size jitter, blur, a hand or the net over the ball).
        var diameterSD: Double = 0.12
        /// SD of Ẇ/W when the filter starts (1/s): how fast the ball's depth
        /// changes relative to its depth. 1.5 covers a ball released 2.5 m
        /// from the lens at 4.5 m/s straight away from it.
        var initialDepthRateSD: Double = 1.5
        /// Density of changes in Ẇ, relative to W (1/s³). Gravity along a
        /// tilted lens axis (g·sin 15° ≈ 2.5 m/s² at 5 m) is about 0.5/s².
        var depthDrift: Double = 0.25
    }

    /// g / ball diameter (1/s²): gravity in apparent ball diameters.
    static let gravityPerDiameter = ShotPhysics.gravity / CourtPositionEstimator.ballDiameterM
    /// Range of Ẇ/W (1/s) used for perspective, so a bad run of box sizes
    /// can't fling the prediction. Going away: a ball released 1.5 m in
    /// front of the lens at 7 m/s. Coming closer (the camera behind the
    /// hoop): the ball stops at the board, 2 m or more from the lens, and
    /// travels at under 5 m/s along the lens axis by then. Coming closer
    /// makes the image speed grow, so that side matters most.
    static let maxDepthRate = 4.5
    static let maxApproachRate = 2.5
    /// Ceiling on the residual acceleration, as a fraction of gravity:
    /// camera tilt (~10%), drag (~10%) and boxes up to ~25% off the ball's
    /// true size, with room to spare.
    static let maxResidual = 0.6
    /// Longest integration step when predicting (s).
    private static let step = 1.0 / 120

    /// Position, velocity and residual acceleration along one axis, with
    /// their 3×3 covariance (symmetric; upper triangle).
    private struct Axis: Sendable, Equatable {
        var p: Double, v: Double, b: Double
        var pp: Double, pv: Double, pb: Double
        var vv: Double, vb: Double, bb: Double

        /// Advances `h` seconds with perspective `c` and gravity `g` (both
        /// constant over the step).
        mutating func advance(h: Double, c: Double, g: Double, qa: Double, qb: Double) {
            let a = -c * v - g + b
            p += v * h + 0.5 * a * h * h
            v += a * h
            // F = [[1, f01, f02], [0, f11, f12], [0, 0, 1]]
            let f01 = h - 0.5 * c * h * h, f02 = 0.5 * h * h
            let f11 = 1 - c * h, f12 = h
            // F·P
            let r0 = (pp + f01 * pv + f02 * pb, pv + f01 * vv + f02 * vb, pb + f01 * vb + f02 * bb)
            let r1 = (f11 * pv + f12 * pb, f11 * vv + f12 * vb, f11 * vb + f12 * bb)
            let r2 = (pb, vb, bb)
            // (F·P)·Fᵀ
            let h2 = h * h, h3 = h2 * h, h4 = h3 * h, h5 = h4 * h
            pp = r0.0 + f01 * r0.1 + f02 * r0.2 + qa * h3 / 3 + qb * h5 / 20
            pv = f11 * r0.1 + f12 * r0.2 + qa * h2 / 2 + qb * h4 / 8
            pb = r0.2 + qb * h3 / 6
            vv = f11 * r1.1 + f12 * r1.2 + qa * h + qb * h3 / 3
            vb = r1.2 + qb * h2 / 2
            bb = r2.2 + qb * h
        }

        mutating func kick(variance: Double) { vv += variance }

        mutating func correct(measurement z: Double, r: Double) {
            let innovation = z - p
            // The ball wasn't quite where its arc said (a touch, a box that
            // jumped): widen position and velocity until the detection is a
            // 3σ one, so the filter follows rather than keeps believing a
            // stale arc. The residual acceleration is left alone: forces
            // don't change because one box surprised us.
            let excess = innovation * innovation / 9 - r
            if excess > pp, pp > 0 {
                let scale = excess / pp
                pp *= scale; pv *= scale; vv *= scale
            }
            let s = pp + r
            guard s > 0 else { return }
            let kp = pp / s, kv = pv / s, kb = pb / s
            p += kp * innovation
            v += kv * innovation
            b += kb * innovation
            let (opp, opv, opb) = (pp, pv, pb)
            pp -= kp * opp; pv -= kp * opv; pb -= kp * opb
            vv -= kv * opv; vb -= kv * opb
            bb -= kb * opb
        }
    }

    /// W = 1/D and its rate, with their covariance.
    private struct Depth: Sendable, Equatable {
        var w: Double, rate: Double
        var ww: Double, wr: Double, rr: Double

        func at(_ dt: Double) -> Double { w + rate * dt }

        mutating func advance(dt: Double, q: Double) {
            guard dt > 0 else { return }
            w += rate * dt
            let dt2 = dt * dt, dt3 = dt2 * dt
            ww += 2 * dt * wr + dt2 * rr + q * dt3 / 3
            wr += dt * rr + q * dt2 / 2
            rr += q * dt
        }

        mutating func correct(measurement z: Double, r: Double) {
            let innovation = z - w
            // A hand or the net over the ball, or a box that isn't the
            // ball's size, counts for no more than a 3σ measurement would.
            let s = max(ww + r, innovation * innovation / 9)
            guard s > 0 else { return }
            let kw = ww / s, kr = wr / s
            w += kw * innovation
            rate += kr * innovation
            let (oww, owr) = (ww, wr)
            ww -= kw * oww; wr -= kw * owr
            rr -= kr * owr
        }
    }

    private var x: Axis
    private var y: Axis
    private var depth: Depth?
    private(set) var time: Double
    let noise: Noise

    /// - Parameters:
    ///   - diameter: the ball's apparent diameter, nil if unknown (then the
    ///     filter has no gravity or perspective until one comes in).
    init(at point: Point, diameter: Double? = nil, velocity: Point = Point(x: 0, y: 0),
         time: Double, noise: Noise) {
        let r = noise.measurementSD * noise.measurementSD
        let v = noise.initialVelocitySD * noise.initialVelocitySD
        let b = noise.initialResidualSD * noise.initialResidualSD
        x = Axis(p: point.x, v: velocity.x, b: 0, pp: r, pv: 0, pb: 0, vv: v, vb: 0, bb: b)
        y = Axis(p: point.y, v: velocity.y, b: 0, pp: r, pv: 0, pb: 0, vv: v, vb: 0, bb: b)
        self.time = time
        self.noise = noise
        if let diameter { startDepth(diameter: diameter) }
    }

    var position: Point { Point(x: x.p, y: y.p) }
    var velocity: Point { Point(x: x.v, y: y.v) }
    /// What the filter has learned the model misses (units / s²).
    var residualAcceleration: Point { Point(x: x.b, y: y.b) }
    /// The ball's apparent diameter now, if the filter has seen one.
    var diameter: Double? { depth.map { 1 / $0.w } }

    /// The ball's apparent diameter expected at `time`.
    func diameter(at time: Double) -> Double? {
        depth.map { 1 / max(0.25 * $0.w, $0.at(time - self.time)) }
    }
    /// Gravity at the ball's current depth (units / s², downwards), 0 without a diameter.
    var gravity: Double { diameter.map { Self.gravityPerDiameter * $0 } ?? 0 }

    /// Where the ball should be at `time`, without changing the filter.
    func predicted(at time: Double) -> Point {
        let (px, py) = advanced(to: time, bounceSD: 0)
        return Point(x: px.p, y: py.p)
    }

    /// The predicted path from now to `end`, every `interval` seconds
    /// (both ends included), without changing the filter.
    func path(to end: Double, every interval: Double) -> [(time: Double, point: Point)] {
        guard end > time, interval > 0 else { return [(time, position)] }
        var out: [(time: Double, point: Point)] = [(time, position)]
        var px = x, py = y
        var t = time
        while t < end - 1e-12 {
            let next = min(end, t + interval)
            Self.advance(&px, &py, depth: depth, from: t - time, by: next - t, noise: noise)
            t = next
            out.append((t, Point(x: px.p, y: py.p)))
        }
        return out
    }

    /// How surprising a detection at `point` would be at `time`, in standard
    /// deviations (Mahalanobis distance over both axes).
    ///
    /// - Parameters:
    ///   - measurementSD: this detection's centre SD, if not the usual (a
    ///     box cut off by the frame edge).
    ///   - bounceSD: SD of a velocity change the ball may have had since
    ///     the last update (a rim or board contact), units / s.
    func surprise(of point: Point, at time: Double,
                  measurementSD: Double? = nil, bounceSD: Double = 0) -> Double {
        let (px, py) = advanced(to: time, bounceSD: bounceSD)
        let sd = measurementSD ?? noise.measurementSD
        let r = sd * sd
        let dx = point.x - px.p, dy = point.y - py.p
        return (dx * dx / (px.pp + r) + dy * dy / (py.pp + r)).squareRoot()
    }

    /// Advances to `time` and folds in a measurement.
    mutating func update(with point: Point, diameter: Double? = nil, at time: Double,
                         measurementSD: Double? = nil, bounceSD: Double = 0) {
        let dt = max(0, time - self.time)
        (x, y) = advanced(to: self.time + dt, bounceSD: bounceSD)
        let q = depthDrift
        depth?.advance(dt: dt, q: q)
        let sd = measurementSD ?? noise.measurementSD
        let r = sd * sd
        x.correct(measurement: point.x, r: r)
        y.correct(measurement: point.y, r: r)
        if let diameter, diameter > 0 {
            if depth == nil {
                startDepth(diameter: diameter)
            } else {
                let w = 1 / diameter
                let sdW = noise.diameterSD * w
                depth?.correct(measurement: w, r: sdW * sdW)
            }
        }
        // Tilt, drag and box-size bias are a fraction of gravity; a residual
        // that cancels gravity would be a ball hanging in the air.
        if depth != nil {
            let limit = Self.maxResidual * gravity
            x.b = min(limit, max(-limit, x.b))
            y.b = min(limit, max(-limit, y.b))
        }
        self.time = max(self.time, time)
    }

    // MARK: Internals

    private var depthDrift: Double {
        guard let depth else { return 0 }
        return noise.depthDrift * depth.w * depth.w
    }

    private mutating func startDepth(diameter: Double) {
        guard diameter > 0 else { return }
        let w = 1 / diameter
        let sdW = noise.diameterSD * w
        let sdRate = noise.initialDepthRateSD * w
        depth = Depth(w: w, rate: 0, ww: sdW * sdW, wr: 0, rr: sdRate * sdRate)
    }

    private func advanced(to time: Double, bounceSD: Double) -> (Axis, Axis) {
        var px = x, py = y
        // A bounce could have come any time since the last sighting; taking
        // it at the start lets it move the predicted position too.
        if bounceSD > 0 {
            px.kick(variance: bounceSD * bounceSD)
            py.kick(variance: bounceSD * bounceSD)
        }
        let dt = time - self.time
        if dt > 0 { Self.advance(&px, &py, depth: depth, from: 0, by: dt, noise: noise) }
        return (px, py)
    }

    /// Moves both axes `dt` seconds on, starting `offset` seconds after the
    /// filter's own time (where the depth state is).
    private static func advance(_ px: inout Axis, _ py: inout Axis, depth: Depth?,
                                from offset: Double, by dt: Double, noise: Noise) {
        let steps = max(1, Int((dt / step).rounded(.up)))
        let h = dt / Double(steps)
        for i in 0..<steps {
            var c = 0.0, g = 0.0
            if let depth {
                // Depth half-way through the step; W can't reach zero (the
                // ball can't pass through the lens).
                let w = max(0.25 * depth.w, depth.at(offset + (Double(i) + 0.5) * h))
                // A rate the sizes don't yet pin down is shrunk towards 0
                // (no perspective) rather than trusted.
                let rate = depth.rate / w, variance = depth.rr / (w * w)
                let shrunk = rate * rate / max(rate * rate + variance, 1e-12) * rate
                c = 2 * min(maxDepthRate, max(-maxApproachRate, shrunk))
                g = gravityPerDiameter / w
            }
            px.advance(h: h, c: c, g: 0, qa: noise.acceleration, qb: noise.residualDrift)
            py.advance(h: h, c: c, g: g, qa: noise.acceleration, qb: noise.residualDrift)
        }
    }
}
