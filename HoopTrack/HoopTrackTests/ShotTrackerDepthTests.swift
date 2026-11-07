// HoopTrackTests/ShotTrackerDepthTests.swift
// The make decision seen through a real camera: a pinhole at chest height
// behind the shooter (or behind the board, facing them), regulation ball
// and rim, ballistic flights at 60 fps with perfect detections. From one
// camera a ball dropping in front of the rim looks like a make in 2D; only
// its size gives it away (ShotTracker.Doubts).

import XCTest
@testable import HoopTrack
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class ShotTrackerDepthTests: XCTestCase {

    // MARK: - A pinhole camera (metres; rim centre at the origin's x/z, 3.05 m up)

    private struct Vec {
        var x, y, z: Double
        static func + (a: Vec, b: Vec) -> Vec { Vec(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
        static func - (a: Vec, b: Vec) -> Vec { Vec(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
        static func * (a: Vec, k: Double) -> Vec { Vec(x: a.x * k, y: a.y * k, z: a.z * k) }
        func dot(_ b: Vec) -> Double { x * b.x + y * b.y + z * b.z }
        func cross(_ b: Vec) -> Vec { Vec(x: y * b.z - z * b.y, y: z * b.x - x * b.z, z: x * b.y - y * b.x) }
        var unit: Vec { self * (1 / dot(self).squareRoot()) }
    }

    private struct Camera {
        let position: Vec
        let forward, right, up: Vec
        /// Focal length in image-width units (68° horizontal field of view).
        let f = 0.5 / tan(34 * Double.pi / 180)
        let aspect = 16.0 / 9.0

        init(at position: Vec, lookingAt target: Vec) {
            self.position = position
            forward = (target - position).unit
            right = forward.cross(Vec(x: 0, y: 1, z: 0)).unit
            up = right.cross(forward)
        }

        /// Vision-normalised image point (origin bottom-left, y up).
        func project(_ p: Vec) -> (x: Double, y: Double, depth: Double) {
            let d = p - position
            let depth = d.dot(forward)
            return (0.5 + f * d.dot(right) / depth, 0.5 + f * aspect * d.dot(up) / depth, depth)
        }

        func ballBox(_ p: Vec) -> CGRect {
            let c = project(p)
            let w = f * 0.239 / c.depth
            return CGRect(x: c.x - w / 2, y: c.y - w * aspect / 2, width: w, height: w * aspect)
        }

        /// Ring (0.49 m outer) plus net (down to 2.60 m, 0.30 m across): the
        /// box the detector is trained to draw.
        func hoopBox() -> CGRect {
            var points: [(x: Double, y: Double, depth: Double)] = []
            for k in 0..<72 {
                let a = Double(k) / 72 * 2 * .pi
                points.append(project(Vec(x: 0.245 * cos(a), y: 3.05, z: 0.245 * sin(a))))
                points.append(project(Vec(x: 0.15 * cos(a), y: 2.60, z: 0.15 * sin(a))))
            }
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    private let rimHeight = 3.05

    /// A drag-free flight from `release` that passes `through` on the way
    /// down `flight` seconds later.
    private func ballistic(from release: Vec, through: Vec, flight: Double) -> (Double) -> Vec {
        let g = 9.81
        let v = Vec(x: (through.x - release.x) / flight,
                    y: (through.y - release.y) / flight + 0.5 * g * flight,
                    z: (through.z - release.z) / flight)
        return { t in release + v * t + Vec(x: 0, y: -0.5 * g * t * t, z: 0) }
    }

    /// Steps a ball at 60 fps with gravity; `net` brakes it while it's in
    /// the net (inside the ring's circle, between rim and net bottom).
    private func flight(start: Vec, velocity: Vec, duration: Double, net: Bool) -> [Vec] {
        var p = start, v = velocity
        var out: [Vec] = []
        let dt = 1.0 / 240
        for step in 0..<Int(duration * 240) {
            if step % 4 == 0 { out.append(p) }
            let inNet = net && p.y < rimHeight && p.y > 2.55 && (p.x * p.x + p.z * p.z) < 0.25 * 0.25
            if inNet {
                v = Vec(x: v.x * exp(-14 * dt), y: v.y * exp(-5 * dt), z: v.z * exp(-14 * dt))
            }
            v.y -= 9.81 * dt
            p = p + v * dt
        }
        return out
    }

    /// Feeds the camera's view of `path` (one position per 1/60 s) with a
    /// fixed hoop box, returning the resolved outcome.
    private func call(_ path: [Vec], camera: Camera, from t0: Double = 0) -> ShotTracker.Outcome? {
        var tracker = ShotTracker()
        let hoop = camera.hoopBox()
        var outcome: ShotTracker.Outcome?
        for (i, p) in path.enumerated() {
            let t = t0 + Double(i) / 60
            let box = camera.ballBox(p)
            let visible = box.minX > 0 && box.maxX < 1 && box.minY > 0 && box.maxY < 1
            if case .resolved(let o)? = tracker.update(balls: visible ? [box] : [], hoop: hoop, time: t) {
                outcome = o
                break
            }
        }
        // Let a ball that vanished settle.
        if outcome == nil {
            for k in 1...90 {
                if case .resolved(let o)? = tracker.update(balls: [], hoop: hoop, time: t0 + Double(path.count + k) / 60) {
                    return o
                }
            }
        }
        return outcome
    }

    /// Positions from release, at 60 fps, of a shot through `target` at rim
    /// height, continuing with real physics (net braking for a make).
    private func shot(release: Vec, target: Vec, flightTime: Double, makes: Bool) -> [Vec] {
        let arc = ballistic(from: release, through: target, flight: flightTime)
        // Run the arc to just above rim height, then step the physics.
        let handover = flightTime - 0.05
        var path: [Vec] = stride(from: 0.0, to: handover, by: 1.0 / 60).map(arc)
        let p = arc(handover)
        let q = arc(handover + 1e-3)
        let v = (q - p) * 1000
        path += flight(start: p, velocity: v, duration: 1.2, net: makes)
        return path
    }

    // Behind the shooter: shooter 5 m out, phone 3 m behind them, 1.35 m up.
    private var behind: Camera {
        Camera(at: Vec(x: 0.6, y: 1.35, z: 8.0), lookingAt: Vec(x: 0, y: 2.45, z: 0))
    }
    private let release = Vec(x: 0.15, y: 2.3, z: 5.0)

    // MARK: - Behind the shooter

    func test_behind_cleanMake_isStillSure() {
        let path = shot(release: release, target: Vec(x: 0, y: rimHeight, z: 0), flightTime: 1.05, makes: true)
        let o = call(path, camera: behind)
        XCTAssertEqual(o?.result, .make)
        XCTAssertEqual(o?.confidence ?? 0, 0.95, accuracy: 1e-9)
        XCTAssertEqual(o?.doubts, [])
    }

    func test_behind_airballLandingAMetreShort_isNotASureMake() {
        // Touches nothing: crosses rim height 1 m in front of the rim, on the
        // camera's line to the hoop, and falls in front of the net.
        let path = shot(release: release, target: Vec(x: 0, y: rimHeight, z: 1.0), flightTime: 0.95, makes: false)
        let o = call(path, camera: behind)
        XCTAssertEqual(o?.result, .make, "in 2D this is a make: it drops through the rim's column")
        XCTAssertLessThan(o?.confidence ?? 1, 0.9, "a ball in front of the rim must not be a sure make")
        XCTAssertTrue(o?.doubts.contains(.tooBigForRim) ?? false)
    }

    func test_behind_frontRimBounceBack_isNotASureMake() {
        // Hits the front of the rim and comes back toward the shooter (and
        // the camera), dropping in front of the net.
        let arc = ballistic(from: release, through: Vec(x: 0, y: 3.12, z: 0.36), flight: 1.0)
        var path: [Vec] = stride(from: 0.0, to: 1.0, by: 1.0 / 60).map(arc)
        path += flight(start: arc(1.0), velocity: Vec(x: 0, y: 1.8, z: 2.2), duration: 1.2, net: false)
        let o = call(path, camera: behind)
        XCTAssertEqual(o?.result, .make, "in 2D this is a make: it drops through the rim's column")
        XCTAssertLessThan(o?.confidence ?? 1, 0.9)
        XCTAssertFalse(o?.doubts.isDisjoint(with: .depth) ?? true)
    }

    // MARK: - Behind the board, facing the shooter

    private var facing: Camera {
        Camera(at: Vec(x: -0.4, y: 1.35, z: -3.0), lookingAt: Vec(x: 0, y: 3.4, z: 3.0))
    }

    func test_facing_cleanMake_isStillSure() {
        let path = shot(release: release, target: Vec(x: 0, y: rimHeight, z: 0), flightTime: 1.05, makes: true)
        let o = call(path, camera: facing)
        XCTAssertEqual(o?.result, .make)
        XCTAssertEqual(o?.confidence ?? 0, 0.95, accuracy: 1e-9)
    }

    func test_facing_frontRimBounceBackToTheShooter_isNotASureMake() {
        // Seen from behind the board the bounce goes away from the camera:
        // the ball stops growing before it drops past the net, about 0.6 m
        // beyond the rim. (Harder bounces lose the tracker's ball filter
        // altogether; that's a lost-ball call, not this one.)
        let arc = ballistic(from: release, through: Vec(x: 0, y: 3.12, z: 0.36), flight: 1.0)
        var path: [Vec] = stride(from: 0.0, to: 1.0, by: 1.0 / 60).map(arc)
        path += flight(start: arc(1.0), velocity: Vec(x: 0, y: 2.4, z: 0.4), duration: 1.2, net: false)
        let o = call(path, camera: facing)
        XCTAssertEqual(o?.result, .make, "in 2D this is a make: it drops through the rim's column")
        XCTAssertLessThan(o?.confidence ?? 1, 0.9)
        XCTAssertTrue(o?.doubts.contains(.cameBack) ?? false)
    }

    // MARK: - Side-on: no depth trend, size alone

    func test_sideOn_cleanMake_isStillSure() {
        // Camera 6 m to the side of the shot line: the ball's distance
        // barely changes, so its size trend says nothing.
        let side = Camera(at: Vec(x: 6.0, y: 1.35, z: 2.5), lookingAt: Vec(x: 0, y: 2.6, z: 2.0))
        let path = shot(release: release, target: Vec(x: 0, y: rimHeight, z: 0), flightTime: 1.05, makes: true)
        let o = call(path, camera: side)
        XCTAssertEqual(o?.result, .make)
        XCTAssertEqual(o?.doubts, [])
    }

    // MARK: - Sanity of the harness

    func test_harness_ballIsAboutHalfTheRimWideAtTheRim() {
        let cam = behind
        let rim = cam.hoopBox()
        let ball = cam.ballBox(Vec(x: 0, y: rimHeight, z: 0))
        XCTAssertEqual(Double(ball.width / rim.width), 0.239 / 0.49, accuracy: 0.02)
    }
}
