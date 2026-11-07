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
