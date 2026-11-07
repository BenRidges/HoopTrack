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
}
