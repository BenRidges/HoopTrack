// HoopTrackTests/ShotTrackerStartTests.swift
// How shots start: which detections ShotTracker accepts between shots and
// which rising runs it takes for a release. Synthetic 30 and 60 fps frames,
// Vision-normalised (y up), with the hoop from ShotTrackerTests: x 0.45–0.55,
// y 0.70–0.80 (a 128 px rim in a 1280×720 frame).

import XCTest
@testable import HoopTrack
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class ShotTrackerStartTests: XCTestCase {

    private let hoop = CGRect(x: 0.45, y: 0.70, width: 0.10, height: 0.10)
    private let aspect = 16.0 / 9.0

    /// A ball box `size` image widths across, square in pixels.
    private func ball(_ x: Double, _ y: Double, size: Double = 0.03) -> CGRect {
        CGRect(x: x - size / 2, y: y - size * aspect / 2, width: size, height: size * aspect)
    }

    /// What the detector returns when it takes the rim for a ball: about as
    /// wide as the rim, half as tall, on top of it (cam2 28.50: 56×31 px on
    /// a 58×35 rim).
    private var rimAsBall: CGRect {
        CGRect(x: 0.455, y: 0.745, width: 0.092, height: 0.092 * aspect / 1.85)
    }

    /// Lob from ShotTrackerTests: rises from y 0.40, peaks at 1.0, drops
    /// through rim height at t ≈ 0.96 s.
    private func arcY(_ t: Double) -> Double { 0.40 + 2.0 * t - 1.6667 * t * t }

    private func run(from start: Double = 0, duration: Double, fps: Double = 60,
                     tracker: inout ShotTracker,
                     balls: (Double) -> [CGRect]) -> [ShotTracker.Event] {
        var events: [ShotTracker.Event] = []
        var frame = 0
        while Double(frame) / fps <= duration {
            let t = start + Double(frame) / fps
            if let event = tracker.update(balls: balls(t), hoop: hoop, time: t) { events.append(event) }
            frame += 1
        }
        return events
    }

    private func starts(_ events: [ShotTracker.Event]) -> [ShotTracker.Release] {
        events.compactMap { if case .started(let r) = $0 { return r } else { return nil } }
    }

    private func outcomes(_ events: [ShotTracker.Event]) -> [ShotTracker.Outcome] {
        events.compactMap { if case .resolved(let o) = $0 { return o } else { return nil } }
    }

    // MARK: - Rim taken for a ball

    func test_isRimShaped_rimBoxOnTheHoop() {
        let tracker = ShotTracker()
        XCTAssertTrue(tracker.isRimShaped(rimAsBall, hoop: hoop))
    }

    func test_isRimShaped_notARoundBallAtTheRim() {
        let tracker = ShotTracker()
        // A ball at the rim's depth: about half the rim's width, square.
        XCTAssertFalse(tracker.isRimShaped(ball(0.5, 0.76, size: 0.05), hoop: hoop))
        // Stretched upwards by motion blur as it drops through.
        let blurred = CGRect(x: 0.475, y: 0.70, width: 0.05, height: 0.05 * aspect * 1.6)
        XCTAssertFalse(tracker.isRimShaped(blurred, hoop: hoop))
    }

    func test_isRimShaped_notAWideBoxAwayFromTheHoop() {
        let tracker = ShotTracker()
        let wide = CGRect(x: 0.20, y: 0.30, width: 0.092, height: 0.092 * aspect / 1.85)
        XCTAssertFalse(tracker.isRimShaped(wide, hoop: hoop))
    }

    func test_rimTakenForABall_doesNotStartAShotFromABallBelow() {
        // cam2 28.43 → 28.50: a bounce pass low in the frame, missed for a
        // frame, then the rim labelled "ball". Linked, that read as a rise
        // of 4 rim widths at 19 rim widths a second.
        var tracker = ShotTracker()
        let events = run(duration: 2.0, fps: 30, tracker: &tracker) { t in
            if t < 0.5 { return [self.ball(0.30 - 0.2 * t, 0.45 - 0.1 * t)] }
            if t < 0.55 { return [] }
            return [self.rimAsBall]
        }
        XCTAssertTrue(starts(events).isEmpty)
    }

    func test_rimTakenForABall_doesNotBlockTheRealShot() {
        // cam2 51.07 / 53.10: the pass comes back, the rim flickers as
        // "ball", and the shot follows 1.1 s later. A phantom started from
        // the rim would hold the tracker (lost timeout + cooldown) through it.
        var tracker = ShotTracker()
        let events = run(duration: 3.0, fps: 30, tracker: &tracker) { t in
            if t < 0.5 { return [self.ball(0.30 - 0.2 * t, 0.45 - 0.1 * t)] }
            if t < 0.55 { return [] }
            if t < 0.75 { return [self.rimAsBall] }
            if t < 1.1 { return [] }
            let s = t - 1.1
            return s <= 1.2 ? [self.ball(0.5, self.arcY(s))] : []
        }
        let started = starts(events)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.time ?? 0, 1.1, accuracy: 0.1)
        XCTAssertEqual(outcomes(events).map(\.result), [.make])
    }

    // MARK: - Association: one ball, physically possible steps

    func test_twoStaticFalsePositives_doNotChainIntoARise() {
        // F7: something ball-like sits low for 3 frames, is missed on the
        // 4th as another box shows up 2.9 rim widths higher near the rim.
        // Linked, that was a rise of 2.9 rim widths in 1/60 s.
        var tracker = ShotTracker()
        let rimLine = 0.80 - 0.15 * 0.10, rimUnit = 0.10 * aspect
        let events = run(duration: 1.5, tracker: &tracker) { t in
            if t < 0.05 { return [self.ball(0.30, rimLine - 3 * rimUnit)] }
            return [self.ball(0.35, rimLine - 0.2 * rimUnit)]
        }
        XCTAssertTrue(starts(events).isEmpty)
    }

    func test_jumpAcrossAGap_isNotARise() {
        // A link a ball could make across a 0.2 s gap (≈ 2 m), but the
        // whole "rise" is that one link: nothing seen actually moved.
        var tracker = ShotTracker()
        let rimLine = 0.80 - 0.15 * 0.10, rimUnit = 0.10 * aspect
        let events = run(duration: 1.0, fps: 30, tracker: &tracker) { t in
            if t < 0.3 { return [self.ball(0.30, rimLine - 1.8 * rimUnit)] }
            if t < 0.5 { return [] }
            return [self.ball(0.33, rimLine - 0.2 * rimUnit)]
        }
        XCTAssertTrue(starts(events).isEmpty)
    }

    func test_shotAt30fps_missedAtRelease_stillStarts() {
        // The shooter's arms hide the ball for 0.2 s at release: one long
        // step, then the ball keeps rising on its own.
        var tracker = ShotTracker()
        let events = run(duration: 1.6, fps: 30, tracker: &tracker) { t in
            if t > 0.05 && t < 0.2 { return [] }
            return t <= 1.2 ? [self.ball(0.5, self.arcY(t))] : []
        }
        XCTAssertEqual(starts(events).count, 1)
        XCTAssertEqual(outcomes(events).map(\.result), [.make])
    }

    // MARK: - A lost shot doesn't block the next one

    func test_shotReleasedAsALostShotTimesOut_stillStarts() {
        // A start whose ball vanishes is called after the 0.9 s lost
        // timeout. The next shot leaves the hands just after; its image
        // rise lasts 0.35 s. The cooldown used to run 0.6 s from the call
        // and covered all of it (cam2 28.50 → 30.50).
        var tracker = ShotTracker()
        let events = run(duration: 2.2, tracker: &tracker) { t in
            if t <= 0.3 { return [self.ball(0.5, self.arcY(t))] }
            let s = t - 1.25
            if s >= 0 && s <= 0.35 { return [self.ball(0.3, 0.40 + 2.0 * s - 1.6667 * s * s)] }
            return []
        }
        let started = starts(events)
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(started.last?.time ?? 0, 1.27, accuracy: 0.1)
    }

    // MARK: - Passes back from under the hoop

    func test_lobBackTowardTheCamera_isDroppedWithoutACall() {
        // F4: the rebounder lobs the ball back over the hoop's height to a
        // shooter beside the phone. It rises fast and near the rim line,
        // so it starts like a shot, then grows as it comes at the lens and
        // used to be logged as a confident MISS 0.90.
        var tracker = ShotTracker()
        let events = run(duration: 1.6, tracker: &tracker) { t in
            t <= 1.2 ? [self.ball(0.52 - 0.18 * t, self.arcY(t), size: 0.055 + 0.05 * t)] : []
        }
        XCTAssertEqual(starts(events).count, 1)
        XCTAssertTrue(outcomes(events).isEmpty)
    }

    func test_shotFromBehind_shrinkingTowardTheRim_isStillCalled() {
        // The shooter's ball leaves the hands nearer the lens than the rim
        // and shrinks toward its size at the rim's depth.
        var tracker = ShotTracker()
        let events = run(duration: 1.6, tracker: &tracker) { t in
            t <= 1.2 ? [self.ball(0.5, self.arcY(t), size: 0.12 - 0.06 * min(t, 1.0))] : []
        }
        XCTAssertEqual(outcomes(events).map(\.result), [.make])
    }

    func test_shotTowardACameraBehindTheHoop_growing_isStillCalled() {
        // Camera behind the board: the shot comes toward the lens and
        // grows, but from smaller than a ball at the rim's depth.
        var tracker = ShotTracker()
        let events = run(duration: 1.6, tracker: &tracker) { t in
            t <= 1.2 ? [self.ball(0.5, self.arcY(t), size: 0.03 + 0.02 * min(t, 1.0))] : []
        }
        XCTAssertEqual(outcomes(events).map(\.result), [.make])
    }

    // MARK: - Phone close behind the shooter

    func test_closeCamera_bigBallMovingAway_startsAShot() {
        // Phone ~1.5 m behind the release: the ball leaves the hands 2.4
        // rim widths wide and shrinks as it flies away. Its image rise
        // lasts only a few tenths of a second; dropping boxes over 1.6 rim
        // widths left too little of it to start (camback1-real: 21%).
        var tracker = ShotTracker()
        let events = run(duration: 0.35, tracker: &tracker) { t in
            [self.ball(0.30 + 0.3 * t, 0.45 + 1.2 * t, size: 0.24 - 0.4 * t)]
        }
        let started = starts(events)
        XCTAssertEqual(started.count, 1)
        XCTAssertLessThan(started.first?.time ?? 1, 0.1, "release is where the big ball leaves the hands")
        XCTAssertGreaterThan(started.first?.box.width ?? 0, 0.16, "the release box is over the in-flight cap")
    }

    func test_closeCamera_liftOrPumpFakeAtConstantDepth_doesNotStart() {
        // The same ball raised fast just as close to the lens (lift to the
        // set point, a pump fake): as much image rise, but it isn't flying
        // away, so it never gets back under the in-flight size.
        var tracker = ShotTracker()
        let events = run(duration: 0.6, tracker: &tracker) { t in
            [self.ball(0.30, 0.40 + min(t, 0.3) * 1.5, size: 0.22)]
        }
        XCTAssertTrue(starts(events).isEmpty)
    }

    func test_release_isAfterTheSetPoint_notInTheLift() {
        // Lift to the set point (fast in the image when the ball is close),
        // hold, then shoot. The release is the push after the hold; a
        // release in the lift seeds the ball filter with the wrong speed.
        var tracker = ShotTracker()
        let events = run(duration: 0.6, tracker: &tracker) { t in
            let y: Double
            if t < 0.15 { y = 0.20 + 1.67 * t }
            else if t < 0.30 { y = 0.45 }
            else { let s = t - 0.30; y = 0.45 + 1.4 * s - 2 * s * s }
            return [self.ball(0.40, y, size: 0.12)]
        }
        let started = starts(events)
        XCTAssertEqual(started.count, 1)
        XCTAssertGreaterThanOrEqual(started.first?.time ?? 0, 0.29)
    }
}
