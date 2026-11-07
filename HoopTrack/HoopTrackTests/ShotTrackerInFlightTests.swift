// HoopTrackTests/ShotTrackerInFlightTests.swift
// Following the ball between release and the rim: false "balls" the
// detector reports while the shot ball is out of sight, and a ball that
// goes out of the top of the frame and comes back. Same layout as
// ShotTrackerTests: 60 fps, Vision-normalised (y up), hoop at x 0.45–0.55,
// y 0.70–0.80.

import XCTest
@testable import HoopTrack
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class ShotTrackerInFlightTests: XCTestCase {

    private let hoop = CGRect(x: 0.45, y: 0.70, width: 0.10, height: 0.10)
    private let fps = 60.0

    /// Rises from y 0.40, peaks at 1.0 (t = 0.6 s), back through rim height at t ≈ 0.96 s.
    private func arcY(_ t: Double) -> Double { 0.40 + 2.0 * t - 1.6667 * t * t }

    private func box(_ x: Double, _ y: Double, size: Double = 0.03) -> CGRect {
        CGRect(x: x - size / 2, y: y - size * 16 / 9 / 2, width: size, height: size * 16 / 9)
    }

    /// The rim taken for a ball: a 2:1 box the rim's width, sitting on it.
    private var rimShapedBall: CGRect { CGRect(x: 0.455, y: 0.74, width: 0.09, height: 0.05) }

    private func run(duration: Double, tracker: inout ShotTracker,
                     balls: (Double) -> [CGRect]) -> [ShotTracker.Outcome] {
        var outcomes: [ShotTracker.Outcome] = []
        var frame = 0
        while Double(frame) / fps <= duration {
            let t = Double(frame) / fps
            if case .resolved(let o)? = tracker.update(balls: balls(t), hoop: hoop, time: t) {
                outcomes.append(o)
            }
            frame += 1
        }
        return outcomes
    }

    func test_rimShapedBall_whileTheShotBallIsHidden_isNotFollowed() {
        // A near miss past the right of the rim (offset ~0.6 at rim height),
        // unseen for a moment as it gets there, while the detector reports the
        // rim itself as a "ball".
        var tracker = ShotTracker()
        let outcomes = run(duration: 2.0, tracker: &tracker) { t in
            var balls: [CGRect] = []
            if t <= 1.3 && !(t > 0.90 && t < 1.05) { balls.append(self.box(0.5 + 0.065 * t, self.arcY(t))) }
            if t > 0.90 && t < 1.3 { balls.append(self.rimShapedBall) }
            return balls
        }
        XCTAssertEqual(outcomes.map(\.result), [.miss])
    }

    // MARK: - Rim crossing across a gap

    func test_crossingAcrossAGap_followsTheArc() {
        // Unseen from just after the apex until just under the rim line: a
        // straight line from the apex would put the drop through rim
        // height at ~0.91 s; the ball got there at 0.96 s.
        var tracker = ShotTracker()
        let outcomes = run(duration: 2.0, tracker: &tracker) { t in
            guard t <= 1.2, !(t > 0.55 && t < 1.0) else { return [] }
            return [self.box(0.40 + 0.1 * t, self.arcY(t))]
        }
        XCTAssertEqual(outcomes.map(\.result), [.make])
        XCTAssertEqual(outcomes.first?.rimArrivalTime ?? 0, 0.96, accuracy: 0.02)
    }

    // MARK: - Still in the hands

    func test_shotStartedOnTheLift_isFollowedThroughThePush() {
        // The ball is lifted to the set point (where the start rule already
        // fires), held, pushed and released into the same arc as arcY from
        // t = 0.55: the flight model has to let go of the lift.
        var tracker = ShotTracker()
        let release = 0.55
        func y(_ t: Double) -> Double {
            if t < 0.3 { return 0.30 + 1.3 * t }                    // lift
            if t < 0.45 { return 0.69 }                             // set point
            if t < release {                                        // push
                let k = (t - 0.45) / (release - 0.45)
                return 0.69 + 0.04 * k * k
            }
            return 0.73 + self.arcY(t - release + 0.15) - self.arcY(0.15)
        }
        let outcomes = run(duration: 2.4, tracker: &tracker) { t in
            t <= 1.6 ? [self.box(0.5, y(t))] : []
        }
        XCTAssertEqual(outcomes.map(\.result), [.make])
    }

    // MARK: - Out of the top of the frame

    /// A high arc under gravity at the ball's own scale (g = 41 apparent
    /// diameters/s², the 0.03-wide box being 0.053 high): wholly above the
    /// frame from 0.42 s to 1.37 s, back through rim height at ≈ 1.56 s.
    private let gravity = BallFilter.gravityPerDiameter * 0.03 * 16 / 9
    private func highArcY(_ t: Double) -> Double { 0.40 + 1.957 * t - 0.5 * gravity * t * t }
    private let highArcRimTime = 1.562

    /// The ball's box, cut off by the top of the frame as a detector would
    /// box it; nil while it's wholly out.
    private func framed(_ b: CGRect) -> CGRect? {
        guard b.minY < 1 else { return nil }
        return CGRect(x: b.minX, y: b.minY, width: b.width, height: min(b.maxY, 1) - b.minY)
    }

    func test_ballOutOfTheTopForLongerThanTheLostTimeout_isFollowedBack() {
        var tracker = ShotTracker()
        let outcomes = run(duration: 2.6, tracker: &tracker) { t in
            t <= 1.9 ? [self.box(0.5, self.highArcY(t))].compactMap(self.framed) : []
        }
        XCTAssertEqual(outcomes.map(\.result), [.make])
        XCTAssertEqual(outcomes.first?.rimArrivalTime ?? 0, highArcRimTime, accuracy: 0.03)
    }

    func test_ballSizedBoxAtTheRim_whileTheBallIsAboveTheFrame_isIgnored() {
        // A ball-sized false detection at the rim while the shot is above
        // the frame: the ball can only come back through the top edge.
        var tracker = ShotTracker()
        let fragment = box(0.5, 0.76)
        let outcomes = run(duration: 2.6, tracker: &tracker) { t in
            var balls = [self.box(0.5, self.highArcY(t))].compactMap(self.framed)
            if t > 1.9 { balls = [] }
            if t > 0.9 && t < 1.25 { balls.append(fragment) }
            return balls
        }
        XCTAssertEqual(outcomes.map(\.result), [.make])
        XCTAssertEqual(outcomes.first?.rimArrivalTime ?? 0, highArcRimTime, accuracy: 0.03)
    }

    func test_rimShapedBall_doesNotStopAMakeBeingSeen() {
        var tracker = ShotTracker()
        let outcomes = run(duration: 2.0, tracker: &tracker) { t in
            var balls: [CGRect] = []
            if t <= 1.2 { balls.append(self.box(0.5, self.arcY(t))) }
            if t > 0.85 && t < 1.3 { balls.append(self.rimShapedBall) }
            return balls
        }
        XCTAssertEqual(outcomes.map(\.result), [.make])
    }
}
