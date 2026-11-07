// HoopTrackTests/BallFilterGravityTests.swift
// BallFilter's free-flight model, checked against a ball thrown in 3D and
// filmed by a pinhole camera: gravity at the ball's depth and perspective
// come from its apparent size, so the filter can follow it out of the top
// of the frame and back. Units are the tracker's: height-normalised, x
// scaled by the aspect ratio.

import XCTest
@testable import HoopTrack

final class BallFilterGravityTests: XCTestCase {

    private let aspect = 16.0 / 9.0
    /// 68° horizontal field of view, in height units.
    private var focal: Double { 0.5 / tan(34 * Double.pi / 180) * aspect }

    /// A ball in flight from `start` (metres, camera at the origin looking
    /// along +z, tilted up by `tilt`, y up) at `velocity`, under gravity.
    private struct Throw {
        var start: (x: Double, y: Double, z: Double)
        var velocity: (x: Double, y: Double, z: Double)
        var tilt: Double

        func world(_ t: Double) -> (x: Double, y: Double, z: Double) {
            (start.x + velocity.x * t,
             start.y + velocity.y * t - 0.5 * ShotPhysics.gravity * t * t,
             start.z + velocity.z * t)
        }
    }

    /// Where the camera sees the ball at `t`: centre and apparent diameter.
    private func seen(_ shot: Throw, at t: Double) -> (point: BallFilter.Point, diameter: Double) {
        let w = shot.world(t)
        let c = cos(shot.tilt), s = sin(shot.tilt)
        let zc = w.y * s + w.z * c, yc = w.y * c - w.z * s
        return (BallFilter.Point(x: aspect / 2 + focal * w.x / zc, y: 0.5 + focal * yc / zc),
                focal * CourtPositionEstimator.ballDiameterM / zc)
    }

    /// From behind and to the side of the shooter (like somorin-dusk-cam1):
    /// released 3.5 m in front of a camera 1.1 m up, reaching a rim 7 m away
    /// in 1.1 s. It's in view for 0.3 s, then over the top of the frame for
    /// 0.43 s around the apex.
    private let behind = Throw(start: (-1.2, 0.6, 3.5), velocity: (3.0, 6.6, 3.2), tilt: 6 * .pi / 180)
    /// Side-on: the ball stays at one depth.
    private let sideOn = Throw(start: (-2.0, 0.9, 8.0), velocity: (4.5, 6.4, 0), tilt: 0)

    private func rimUnit(_ shot: Throw) -> Double {
        // The rim (0.47 m across) at the shot's end, 1.1 s in.
        let end = shot.world(1.1)
        return focal * 0.47 / end.z
    }

    private func noise(_ r: Double) -> BallFilter.Noise {
        BallFilter.Noise(measurementSD: 0.08 * r, acceleration: 4 * r * r,
                         residualDrift: 25 * r * r, initialResidualSD: 6 * r,
                         initialVelocitySD: 30 * r)
    }

    /// Follows the ball at 30 fps while it's wholly in frame, from `from`
    /// seconds; returns the filter and the time it was last seen.
    private func follow(_ shot: Throw, from: Double = 1.0 / 30, until: Double = 2,
                        withDiameter: Bool = true) -> (BallFilter, Double) {
        let r = rimUnit(shot)
        let first = seen(shot, at: from)
        var filter = BallFilter(at: first.point, diameter: withDiameter ? first.diameter : nil,
                                time: from, noise: noise(r))
        var last = from
        var t = from + 1.0 / 30
        while t <= until {
            guard inFrame(shot, at: t) else { break }
            let s = seen(shot, at: t)
            filter.update(with: s.point, diameter: withDiameter ? s.diameter : nil, at: t)
            last = t
            t += 1.0 / 30
        }
        return (filter, last)
    }

    private func inFrame(_ shot: Throw, at t: Double) -> Bool {
        let s = seen(shot, at: t)
        return s.point.y + s.diameter / 2 < 1
    }

    private func distance(_ a: BallFilter.Point, _ b: BallFilter.Point) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    // MARK: - Out of the top of the frame and back

    func test_ballOverTheTop_isPredictedBackIntoFrame() {
        let (filter, exit) = follow(behind)
        let r = rimUnit(behind)
        // It comes back into frame about 0.4–0.5 s later.
        var back = exit + 1.0 / 30
        while !inFrame(behind, at: back) { back += 1.0 / 30 }
        XCTAssertGreaterThan(back - exit, 0.25, "the throw should leave the frame for a while")
        let truth = seen(behind, at: back).point
        // Within half a rim width after 0.47 s unseen (most of it sideways:
        // perspective slowing the ball is only partly known from its size).
        XCTAssertLessThan(distance(filter.predicted(at: back), truth), 0.5 * r)
        XCTAssertLessThan(abs(filter.predicted(at: back).y - truth.y), 0.2 * r)
        XCTAssertLessThan(filter.surprise(of: truth, at: back), 3)
    }

    func test_constantVelocity_wouldLoseIt() {
        // The same throw without sizes: no gravity, no perspective, just the
        // residual acceleration it can learn on the way up.
        let (filter, exit) = follow(behind, withDiameter: false)
        let r = rimUnit(behind)
        var back = exit + 1.0 / 30
        while !inFrame(behind, at: back) { back += 1.0 / 30 }
        let truth = seen(behind, at: back).point
        let gravity = follow(behind).0.predicted(at: back)
        XCTAssertGreaterThan(distance(filter.predicted(at: back), truth), 2 * distance(gravity, truth))
        XCTAssertGreaterThan(distance(filter.predicted(at: back), truth), 0.5 * r)
    }

    func test_fragmentAtTheRim_whileTheBallIsAboveTheFrame_isRejected() {
        let (filter, exit) = follow(behind)
        // A box on the rim 0.27 s after the ball went out of the top.
        let rim = seen(behind, at: 1.1).point
        XCTAssertGreaterThan(filter.surprise(of: rim, at: exit + 0.27), 5)
    }

    func test_perspective_ballGoingAway_fallsSlowerThanItRose() {
        let (filter, _) = follow(behind, until: 0.4)
        // Its size is shrinking: depth increasing.
        let now = filter.diameter ?? 0
        let later = filter.diameter(at: filter.time + 0.3) ?? 0
        XCTAssertLessThan(later, now)
        XCTAssertGreaterThan(filter.gravity, 0)
    }

    // MARK: - Side on

    func test_sideOn_learnsGravityAtTheBallsDepth() {
        let (filter, _) = follow(sideOn, until: 0.5)
        let s = seen(sideOn, at: 0.5)
        // g·f/Z: 9.81 m/s² over a 0.239 m ball is 41 diameters per s².
        XCTAssertEqual(filter.gravity, BallFilter.gravityPerDiameter * s.diameter, accuracy: 0.05 * filter.gravity)
        // Half a second on it is still where gravity takes it.
        let truth = seen(sideOn, at: 1.0).point
        XCTAssertLessThan(distance(filter.predicted(at: 1.0), truth), 0.25 * rimUnit(sideOn))
    }

    // MARK: - What isn't free flight

    func test_somethingHanging_isNotExplainedAwayAsFlight() {
        // A ball-sized box that doesn't move (a false "ball" on the rim): the
        // residual can't cancel gravity, so the filter expects it to fall.
        let r = 0.08
        let p = BallFilter.Point(x: 1.0, y: 0.8)
        var filter = BallFilter(at: p, diameter: 0.04, time: 0, noise: noise(r))
        for i in 1...60 { filter.update(with: p, diameter: 0.04, at: Double(i) / 30) }
        XCTAssertLessThanOrEqual(abs(filter.residualAcceleration.y), BallFilter.maxResidual * filter.gravity + 1e-9)
        XCTAssertLessThan(filter.predicted(at: 2.5).y, p.y - 0.5 * r)
    }

    func test_bounce_widensTheGate_fromWhenItCouldHaveHappened() {
        let (filter, last) = follow(sideOn, until: 0.6)
        let t = last + 1.0 / 30
        // The ball comes off the rim going the other way.
        let truth = seen(sideOn, at: t).point
        let v = filter.velocity
        let bounced = BallFilter.Point(x: truth.x - 2 * v.x / 30, y: truth.y - 2 * v.y / 30)
        let speed = (v.x * v.x + v.y * v.y).squareRoot()
        XCTAssertGreaterThan(filter.surprise(of: bounced, at: t), 5)
        XCTAssertLessThan(filter.surprise(of: bounced, at: t, bounce: .init(sd: 0.8 * speed, at: last)), 4)
        // A contact that can't have come before now hasn't moved it yet.
        XCTAssertGreaterThan(filter.surprise(of: bounced, at: t, bounce: .init(sd: 0.8 * speed, at: t)), 5)
    }

    func test_handledBall_filterFollowsAfterASurprise() {
        // Pushed upwards by a hand (not gravity) for a few frames: each
        // detection is accepted, and the filter catches up rather than
        // keeps predicting a fall.
        let r = rimUnit(sideOn)
        var filter = BallFilter(at: .init(x: 0.5, y: 0.3), diameter: 0.03,
                                velocity: .init(x: 0, y: 0), time: 0, noise: noise(r))
        var y = 0.3, v = 0.0
        for i in 1...8 {
            v += 100 * r / 30
            y += v / 30
            filter.update(with: .init(x: 0.5, y: y), diameter: 0.03, at: Double(i) / 30)
        }
        XCTAssertGreaterThan(filter.velocity.y, 0.5 * v)
    }
}
