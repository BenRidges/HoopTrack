// HoopTrackTests/ShotTrackerSecondBallTests.swift
// Two balls at the rim at once (two people shooting at one hoop): the call
// may be about the other ball, so it's flagged. Same synthetic 60 fps lob
// as ShotTrackerTests; the hoop sits at x 0.45–0.55, y 0.70–0.80.

import XCTest
@testable import HoopTrack
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class ShotTrackerSecondBallTests: XCTestCase {

    private let hoop = CGRect(x: 0.45, y: 0.70, width: 0.10, height: 0.10)
    private let fps = 60.0

    /// Rises from y 0.40, peaks at 1.0 (t = 0.6 s), drops through rim height at t ≈ 0.96 s.
    private func arcY(_ t: Double) -> Double { 0.40 + 2.0 * t - 1.6667 * t * t }

    private func box(_ x: Double, _ y: Double, size: Double = 0.03) -> CGRect {
        CGRect(x: x - size / 2, y: y - size * 16 / 9 / 2, width: size, height: size * 16 / 9)
    }

    private func outcome(balls: (Double) -> [CGRect]) -> ShotTracker.Outcome? {
        var tracker = ShotTracker()
        var frame = 0
        while Double(frame) / fps <= 2.0 {
            let t = Double(frame) / fps
            if case .resolved(let o)? = tracker.update(balls: balls(t), hoop: hoop, time: t) { return o }
            frame += 1
        }
        return nil
    }

    func test_secondBallBesideTheShotAtTheRim_flagsTheCall() {
        // The other ball drops 0.6 rim widths to the side, a few frames
        // behind: no box overlap, same size, right next to it at the rim.
        let o = outcome { t in
            guard t <= 1.2 else { return [] }
            var balls = [self.box(0.5, self.arcY(t))]
            if t >= 0.75 { balls.append(self.box(0.56, self.arcY(t - 0.05))) }
            return balls
        }
        XCTAssertEqual(o?.result, .make)
        XCTAssertTrue(o?.doubts.contains(.secondBall) ?? false)
        XCTAssertLessThan(o?.confidence ?? 1, HoopTrack.CV.lowConfidence)
    }

    func test_sameBallBoxedTwice_isNotASecondBall() {
        // A looser duplicate box round the same ball (overlapping it).
        let o = outcome { t in
            guard t <= 1.2 else { return [] }
            return [self.box(0.5, self.arcY(t)), self.box(0.505, self.arcY(t) + 0.004, size: 0.036)]
        }
        XCTAssertEqual(o?.result, .make)
        XCTAssertEqual(o?.doubts, [])
        XCTAssertEqual(o?.confidence ?? 0, 0.95, accuracy: 1e-9)
    }

    func test_rimTakenForABall_isNotASecondBall() {
        // The detector's rim-shaped "ball" on the rim, 2:1 wide, flickering
        // on while the shot comes down beside it.
        let rimBall = CGRect(x: 0.455, y: 0.765, width: 0.09, height: 0.08)
        let o = outcome { t in
            guard t <= 1.2 else { return [] }
            let shot = self.box(0.5, self.arcY(t))
            return t >= 0.8 && t <= 0.9 ? [shot, rimBall] : [shot]
        }
        XCTAssertEqual(o?.result, .make)
        XCTAssertFalse(o?.doubts.contains(.secondBall) ?? true)
    }

    func test_ballElsewhere_isNotASecondBall() {
        let decoy = box(0.2, 0.08)
        let o = outcome { t in t <= 1.2 ? [decoy, self.box(0.5, self.arcY(t))] : [decoy] }
        XCTAssertEqual(o?.result, .make)
        XCTAssertEqual(o?.confidence ?? 0, 0.95, accuracy: 1e-9)
    }

    func test_fuse_swingingNet_doesNotClearASecondBallFlag() {
        // The net swung, but it can't say which of the two balls went in.
        let fused = ShotEvidence.fuse(result: .make, confidence: 0.55, netSwing: 6, doubts: .secondBall)
        XCTAssertEqual(fused.result, .make)
        XCTAssertLessThan(fused.confidence, HoopTrack.CV.lowConfidence)
    }
}
