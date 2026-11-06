// HoopTrackTests/ShotTrackerTests.swift
// Drives ShotTracker with synthetic 60 fps trajectories. Coordinates are
// Vision-normalised (y up). The hoop sits at x 0.45–0.55, y 0.70–0.80.

import XCTest
@testable import HoopTrack

final class ShotTrackerTests: XCTestCase {

    private let hoop = CGRect(x: 0.45, y: 0.70, width: 0.10, height: 0.10)
    private let fps = 60.0

    /// Ball centre for a lob that rises from y 0.40, peaks at 1.0 (t = 0.6 s)
    /// and drops back through rim height at t ≈ 0.96 s.
    private func arcY(_ t: Double) -> Double { 0.40 + 2.0 * t - 1.6667 * t * t }

    private func box(_ x: Double, _ y: Double, size: Double = 0.03) -> CGRect {
        CGRect(x: x - size / 2, y: y - size * 16 / 9 / 2, width: size, height: size * 16 / 9)
    }

    /// Runs frames from 0 to `duration`, returning every event emitted.
    private func run(duration: Double,
                     tracker: inout ShotTracker,
                     balls: (Double) -> [CGRect]) -> [ShotTracker.Event] {
        var events: [ShotTracker.Event] = []
        var frame = 0
        while Double(frame) / fps <= duration {
            let t = Double(frame) / fps
            if let event = tracker.update(balls: balls(t), hoop: hoop, time: t) {
                events.append(event)
            }
            frame += 1
        }
        return events
    }

    private func outcomes(_ events: [ShotTracker.Event]) -> [ShotTracker.Outcome] {
        events.compactMap { if case .resolved(let o) = $0 { return o } else { return nil } }
    }

    private func starts(_ events: [ShotTracker.Event]) -> Int {
        events.filter { if case .started = $0 { return true } else { return false } }.count
    }

    // MARK: - Makes

    func test_cleanMake_throughTheNet() {
        var tracker = ShotTracker()
        let events = run(duration: 1.6, tracker: &tracker) { t in
            t <= 1.2 ? [self.box(0.5, self.arcY(t))] : []
        }
        XCTAssertEqual(starts(events), 1)
        let result = outcomes(events)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.result, .make)
        XCTAssertGreaterThan(result.first?.confidence ?? 0, HoopTrack.CV.lowConfidence)
    }

    func test_make_rimArrivalTime_isWhenBallDropsThroughRimHeight() {
        var tracker = ShotTracker()
        let events = run(duration: 1.6, tracker: &tracker) { t in
            t <= 1.2 ? [self.box(0.5, self.arcY(t))] : []
        }
        let outcome = outcomes(events).first
        XCTAssertEqual(outcome?.rimArrivalTime ?? 0, 0.96, accuracy: 0.03)
        XCTAssertLessThan(outcome?.release.time ?? 1, 0.1, "release should be the fast start of the rise")
    }

    func test_make_hiddenByNet_stillCountsAfterSettling() {
        var tracker = ShotTracker()
        let events = run(duration: 2.0, tracker: &tracker) { t in
            t <= 0.97 ? [self.box(0.5, self.arcY(t))] : []
        }
        let result = outcomes(events)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.result, .make)
    }

    // MARK: - Misses

    func test_missWide_dropsPastTheRim() {
        var tracker = ShotTracker()
        let events = run(duration: 1.6, tracker: &tracker) { t in
            t <= 1.2 ? [self.box(0.5 + 0.13 * t, self.arcY(t))] : []
        }
        let result = outcomes(events)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.result, .miss)
    }

    func test_rimBounceOut_isAMiss() {
        var tracker = ShotTracker()
        let events = run(duration: 2.4, tracker: &tracker) { t in
            if t <= 0.967 { return [self.box(0.5, self.arcY(t))] }
            if t <= 1.3 {
                let k = (t - 0.967) / (1.3 - 0.967)
                return [self.box(0.5 + 0.08 * k, 0.77 + 0.18 * k)]
            }
            if t <= 1.8 {
                let k = (t - 1.3) / 0.5
                return [self.box(0.58 + 0.17 * k, 0.95 - 0.45 * k)]
            }
            return []
        }
        let result = outcomes(events)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.result, .miss)
    }

    // MARK: - Things that aren't shots

    func test_dribbling_neverStartsAShot() {
        var tracker = ShotTracker()
        let events = run(duration: 5, tracker: &tracker) { t in
            [self.box(0.4, 0.15 + 0.12 * abs(sin(2 * .pi * t)))]
        }
        XCTAssertTrue(events.isEmpty)
    }

    func test_noHoop_neverStartsAShot() {
        var tracker = ShotTracker()
        var frame = 0
        while Double(frame) / fps <= 1.6 {
            let t = Double(frame) / fps
            XCTAssertNil(tracker.update(balls: [box(0.5, arcY(t))], hoop: nil, time: t))
            frame += 1
        }
    }

    func test_decoyBallOnFloor_doesNotHijackTheShot() {
        var tracker = ShotTracker()
        let decoy = box(0.2, 0.08, size: 0.05)
        let events = run(duration: 1.6, tracker: &tracker) { t in
            t <= 1.2 ? [decoy, self.box(0.5, self.arcY(t))] : [decoy]
        }
        XCTAssertEqual(outcomes(events).first?.result, .make)
    }

    func test_oversizedBox_isIgnored() {
        var tracker = ShotTracker()
        let events = run(duration: 1.6, tracker: &tracker) { t in
            t <= 1.2 ? [self.box(0.5, self.arcY(t), size: 0.3)] : []
        }
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Ball filter

    func test_jitteryBoxes_stillAMake() {
        var tracker = ShotTracker()
        let events = run(duration: 1.6, tracker: &tracker) { t in
            guard t <= 1.2 else { return [] }
            // ±0.006 of frame on both axes, alternating — a wobbly detector.
            let wobble = (Int((t * self.fps).rounded()) % 2 == 0 ? 1.0 : -1.0) * 0.006
            return [self.box(0.5 + wobble, self.arcY(t) + wobble)]
        }
        XCTAssertEqual(outcomes(events).map(\.result), [.make])
    }

    func test_decoyDuringDetectionGap_isNotFollowed() {
        var tracker = ShotTracker()
        let events = run(duration: 1.6, tracker: &tracker) { t in
            guard t <= 1.2 else { return [] }
            // The shot ball goes undetected for ~5 frames near the apex while a
            // second ball shows up off to the side at a similar height.
            if t > 0.55 && t < 0.64 { return [self.box(0.72, 0.95)] }
            return [self.box(0.5, self.arcY(t))]
        }
        XCTAssertEqual(outcomes(events).map(\.result), [.make])
    }

    func test_crossingBall_doesNotHijackTheShot() {
        var tracker = ShotTracker()
        let events = run(duration: 1.6, tracker: &tracker) { t in
            guard t <= 1.2 else { return [] }
            // Another ball travels right-to-left across the shot's path,
            // passing within 0.1 of it around t = 0.5.
            let other = self.box(0.95 - 0.9 * t, 0.86)
            return [self.box(0.5, self.arcY(t)), other]
        }
        XCTAssertEqual(outcomes(events).map(\.result), [.make])
    }

    // MARK: - Back-to-back shots

    func test_twoShots_bothResolved() {
        var tracker = ShotTracker()
        let events = run(duration: 4.0, tracker: &tracker) { t in
            if t <= 1.2 { return [self.box(0.5, self.arcY(t))] }
            if t >= 2.0 && t <= 3.2 { return [self.box(0.5 + 0.13 * (t - 2.0), self.arcY(t - 2.0))] }
            return []
        }
        XCTAssertEqual(outcomes(events).map(\.result), [.make, .miss])
    }
}
