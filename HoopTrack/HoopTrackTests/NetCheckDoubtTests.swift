// HoopTrackTests/NetCheckDoubtTests.swift
// What the net check learns about a net, and how it settles calls the
// tracker had doubts about.

import XCTest
@testable import HoopTrack
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class NetCheckDoubtTests: XCTestCase {

    private let hoop = CGRect(x: 0.45, y: 0.70, width: 0.10, height: 0.10)

    /// Activity trace: quiet at `base`, then `after` from arrival+0.15 for 0.6 s.
    private func meter(base: Double, after: Double, arrival: Double = 2.0) -> NetMotionMeter {
        var meter = NetMotionMeter()
        var t = 0.0
        while t <= arrival + 1.0 {
            let swinging = t >= arrival + 0.15 && t <= arrival + 0.75
            meter.record(swinging ? after : base, at: t)
            t += 1.0 / 30
        }
        return meter
    }

    private var still: NetMotionMeter { meter(base: 0.01, after: 0.01) }
    private var swinging: NetMotionMeter { meter(base: 0.01, after: 0.06) }

    private func outcome(_ result: ShotResult, confidence: Double, hoop: CGRect? = nil,
                         doubts: ShotTracker.Doubts = []) -> ShotTracker.Outcome {
        ShotTracker.Outcome(result: result, confidence: confidence,
                            release: .init(box: hoop ?? self.hoop, time: 1.0, ballDiameter: 0.03),
                            rimArrivalTime: 2.0, hoop: hoop ?? self.hoop, lastSeenTime: 2.0, doubts: doubts)
    }

    /// Two clean makes measured under `hoop` on `net`.
    private func learn(_ check: inout NetCheck<Void>, net: NetMotionMeter, hoop: CGRect? = nil) {
        for _ in 0..<2 {
            _ = check.submit(outcome(.make, confidence: 0.95, hoop: hoop), context: (), now: 2.3, meter: net)
            _ = check.due(now: 2.8, meter: net)
        }
    }

    // MARK: - Learning is per view of the net

    func test_check_forgetsWhatTheNetDoes_whenThePhoneIsMoved() {
        var check = NetCheck<Void>()
        learn(&check, net: still)
        XCTAssertEqual(check.netResponds, false)
        // The hoop is now two rim widths to the left: another view, maybe
        // another net. Nothing is known about it yet.
        let moved = hoop.offsetBy(dx: -0.2, dy: 0)
        _ = check.submit(outcome(.miss, confidence: 0.9, hoop: moved), context: (), now: 5.0, meter: still)
        XCTAssertNil(check.netResponds)
    }

    func test_check_keepsWhatItLearned_throughBoxWobble() {
        var check = NetCheck<Void>()
        learn(&check, net: still)
        let wobble = CGRect(x: 0.46, y: 0.71, width: 0.105, height: 0.095)
        _ = check.submit(outcome(.miss, confidence: 0.9, hoop: wobble), context: (), now: 5.0, meter: still)
        XCTAssertEqual(check.netResponds, false)
    }

    func test_isAnotherView() {
        XCTAssertFalse(NetCheck<Void>.isAnotherView(hoop, hoop.offsetBy(dx: 0.05, dy: -0.05)))
        XCTAssertTrue(NetCheck<Void>.isAnotherView(hoop, hoop.offsetBy(dx: 0.11, dy: 0)))
        XCTAssertTrue(NetCheck<Void>.isAnotherView(hoop, hoop.offsetBy(dx: 0, dy: 0.11)))
        XCTAssertTrue(NetCheck<Void>.isAnotherView(hoop, CGRect(x: 0.45, y: 0.70, width: 0.14, height: 0.10)))
    }
}
